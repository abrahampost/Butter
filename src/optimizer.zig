//! AST-level optimization passes: constant folding and dead-code
//! elimination, both as a single recursive walk over a parsed
//! `ast.Program` that mutates it in place (see `optimizeProgram`).
//!
//! Runs BEFORE compiler.zig sees the program — there's no separate typed-IR
//! stage; compiler.zig fuses type-checking and codegen into one pass over
//! the AST it's handed. So a statement pruned here as unreachable, or a
//! branch dropped by constant folding, is never type-checked either —
//! whatever compile error it might have raised goes unreported. Exception:
//! declarations (`function_decl`/`method_decl`/`import_stmt`/`struct_decl`/
//! `enum_decl`) are never pruned regardless of reachability — they're
//! registrations, not statements that "run", and an exported function after
//! a top-level `exit 0` must still compile and stay callable by importers.
//!
//! Constant folding never folds an operation that would raise a
//! `RuntimeError` (overflow, division/modulo by zero) — it leaves that
//! subexpression alone so the VM still raises the identical error at the
//! identical point, unoptimized or not. Every fold mirrors its runtime rule
//! exactly (int/float promotion, `+` string concat, byte-lexicographic
//! string ordering, `and`/`or` short-circuiting) — see `vm.zig`'s
//! `add`/`sub`/`mul`/`div`/`mod`/`pow`/`compare` and `value.zig`'s
//! `Value.eql`, mirrored here by `foldArith`/`numericCompare`/
//! `stringCompare`/`literalEql`.

const std = @import("std");
const ast = @import("ast.zig");

/// Runs constant folding and dead-code elimination over `program` in
/// place, returning the (possibly shorter) resulting slice — the caller
/// should assign the result back over whatever held `program`, e.g.
/// `unit.program = try optimizer.optimizeProgram(allocator, unit.program);`.
///
/// `allocator` should be the same arena the AST itself lives in (the
/// module loader's, in the real pipeline — see `module.Loader.allocator`):
/// a handful of folds (string-literal concatenation, wrapping a bare
/// non-block if/while body as a one-statement block) allocate a little
/// fresh AST-shaped memory that needs to live exactly as long as the rest
/// of the tree.
pub fn optimizeProgram(allocator: std.mem.Allocator, program: ast.Program) std.mem.Allocator.Error!ast.Program {
    return optimizeStmts(allocator, program);
}

// ---- Statement-sequence optimization (dead-code elimination) -------------

/// Optimizes every statement in `stmts` in place (folding constant
/// subexpressions and recursing into nested bodies — see `optimizeStmt`),
/// then drops any statement that can provably never run: everything after
/// the first statement that `alwaysTerminates` control flow, except a
/// top-level-only declaration, which always survives (see the module doc
/// comment). Returns a slice over the same backing array, compacted
/// in place — no allocation of its own.
///
/// Safe to call on any Butter statement sequence: a nested block or
/// function/method body (which the grammar guarantees never contains a
/// top-level-only declaration, so the "always survives" carve-out simply
/// never triggers there) or the top-level `ast.Program` itself (which can
/// freely mix declarations with executable code).
fn optimizeStmts(allocator: std.mem.Allocator, stmts: []ast.Stmt) std.mem.Allocator.Error![]ast.Stmt {
    var terminated = false;
    var write: usize = 0;
    for (stmts) |*s| {
        if (terminated) {
            switch (s.kind) {
                .function_decl, .method_decl, .import_stmt, .struct_decl, .enum_decl => try optimizeStmt(allocator, s),
                else => continue, // unreachable executable code — drop it
            }
        } else {
            try optimizeStmt(allocator, s);
            if (alwaysTerminates(s.*)) terminated = true;
        }
        stmts[write] = s.*;
        write += 1;
    }
    return stmts[0..write];
}

/// Whether `stmt` provably never falls through to whatever follows it —
/// Butter has no `break`/`continue` (GRAMMAR.bnf), so the only ways out of
/// a statement's normal flow are `return`/`exit`/`throw` themselves, an
/// `if`/`else` where BOTH branches always terminate, or a block whose own
/// (already-compacted) last statement always terminates. Deliberately
/// conservative beyond that: a `while true { ... }` with no way out is, in
/// fact, never falling through either, but treating it as a terminator
/// risks subtle mistakes for little payoff, so it isn't one here; neither
/// is `try`/`catch`, since "does this always terminate" would have to
/// reason about exactly which statements inside `body` can throw.
fn alwaysTerminates(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .return_stmt, .exit_stmt, .throw_stmt => true,
        .block => |stmts| stmts.len > 0 and alwaysTerminates(stmts[stmts.len - 1]),
        .if_stmt => |i| i.else_branch != null and alwaysTerminates(i.then_branch.*) and alwaysTerminates(i.else_branch.?.*),
        else => false,
    };
}

/// Optimizes one statement in place: folds constant subexpressions it
/// directly holds and recurses into whatever nested statement bodies it
/// has. `if`/`while`/`for` additionally get a chance to collapse entirely
/// once their condition/bounds are known constants — see
/// `optimizeIf`/`optimizeWhile`/`optimizeFor`.
fn optimizeStmt(allocator: std.mem.Allocator, stmt: *ast.Stmt) std.mem.Allocator.Error!void {
    switch (stmt.kind) {
        .var_decl => |*d| if (d.initializer) |init_expr| try optimizeExpr(allocator, init_expr),
        .block => |stmts| stmt.kind.block = try optimizeStmts(allocator, stmts),
        .if_stmt => |*i| try optimizeIf(allocator, stmt, i),
        .while_stmt => |*w| try optimizeWhile(allocator, stmt, w),
        .for_stmt => |*f| try optimizeFor(allocator, stmt, f),
        .print_stmt, .expr_stmt, .close_stmt, .exit_stmt, .throw_stmt, .return_stmt => |e| try optimizeExpr(allocator, e),
        .function_decl => |*f| f.body = try optimizeStmts(allocator, f.body),
        .method_decl => |*m| m.body = try optimizeStmts(allocator, m.body),
        .try_stmt => |*t| {
            t.body = try optimizeStmts(allocator, t.body);
            t.handler = try optimizeStmts(allocator, t.handler);
        },
        .import_stmt, .struct_decl, .enum_decl => {},
    }
}

/// `if <cond> <then> [else <else>]`. Once `then_branch`/`else_branch` are
/// themselves optimized, a `cond` that folded down to a literal `bool`
/// means only one side can ever run — the whole `if` collapses into a
/// `.block` around just that side (or an empty one, for a false condition
/// with no `else`), the same way a `{ ... }` written directly in source
/// would compile: no separate "eliminated if" AST shape needed.
fn optimizeIf(allocator: std.mem.Allocator, stmt: *ast.Stmt, i: *ast.StmtKind.If) std.mem.Allocator.Error!void {
    try optimizeExpr(allocator, i.condition);
    try optimizeStmt(allocator, i.then_branch);
    if (i.else_branch) |eb| try optimizeStmt(allocator, eb);

    if (i.condition.* == .literal and i.condition.literal == .boolean) {
        const taken: ?*ast.Stmt = if (i.condition.literal.boolean) i.then_branch else i.else_branch;
        stmt.kind = .{ .block = try stmtAsStmtSlice(allocator, taken) };
    }
}

/// `while <cond> <body>`. A `cond` that folds to literal `false` means the
/// body can never run even once (it's a fresh constant, not something a
/// prior iteration could have changed — there is no prior iteration) — the
/// whole loop is dead, replaced with an empty `.block`. A `cond` that folds
/// to literal `true` is left alone: it's a legitimate (and, with no
/// `break`, perpetual short of `return`/`exit`/`throw`/an uncaught error)
/// loop, already as cheap to re-check each pass as a `PUSH_TRUE` gets.
fn optimizeWhile(allocator: std.mem.Allocator, stmt: *ast.Stmt, w: *ast.StmtKind.While) std.mem.Allocator.Error!void {
    try optimizeExpr(allocator, w.condition);
    try optimizeStmt(allocator, w.body);
    if (w.condition.* == .literal and w.condition.literal == .boolean and !w.condition.literal.boolean) {
        stmt.kind = .{ .block = &.{} };
    }
}

/// `for <var> in <start>..<end> <body>` (end exclusive, GRAMMAR.bnf design
/// note 3f). When both bounds fold to `int` literals and the range is
/// empty (`start >= end`), the loop can never run — same dead-loop
/// replacement `optimizeWhile` gives a constant-false condition.
fn optimizeFor(allocator: std.mem.Allocator, stmt: *ast.Stmt, f: *ast.StmtKind.For) std.mem.Allocator.Error!void {
    try optimizeExpr(allocator, f.start);
    try optimizeExpr(allocator, f.end);
    try optimizeStmt(allocator, f.body);
    if (f.start.* == .literal and f.start.literal == .int and f.end.* == .literal and f.end.literal == .int) {
        if (f.start.literal.int >= f.end.literal.int) stmt.kind = .{ .block = &.{} };
    }
}

/// Turns an `if`/`while`-body `?*ast.Stmt` into the `[]ast.Stmt` a `.block`
/// needs: `null` (no `else`) becomes an empty slice, an already-`.block`
/// body's own statement list is reused as-is (no copy), and any other
/// single bare statement (a braceless `if x return 1`, say) is wrapped in a
/// freshly allocated one-element slice.
fn stmtAsStmtSlice(allocator: std.mem.Allocator, maybe_stmt: ?*ast.Stmt) std.mem.Allocator.Error![]ast.Stmt {
    const s = maybe_stmt orelse return &.{};
    if (s.kind == .block) return s.kind.block;
    const single = try allocator.alloc(ast.Stmt, 1);
    single[0] = s.*;
    return single;
}

// ---- Expression optimization (constant folding) ---------------------------

/// Recursively folds constant subexpressions of `expr` in place, bottom-up
/// (children first, so e.g. `(1 + 2) * 3` folds its grouping's `1 + 2`
/// before the outer `*` ever gets a chance at it). Every expression shape
/// is visited purely to reach the `Expr`s it holds — only `.unary`,
/// `.binary`, and `.grouping` ever rewrite themselves; everything else is
/// left structurally alone (no cross-call inlining, no folding through a
/// variable's last-known value — this pass reasons about literals only).
fn optimizeExpr(allocator: std.mem.Allocator, expr: *ast.Expr) std.mem.Allocator.Error!void {
    switch (expr.*) {
        .literal, .variable, .stream_literal, .args_literal, .time_now, .random_float => {},
        .unary => |*u| {
            try optimizeExpr(allocator, u.right);
            if (foldUnary(u.op, u.right.*)) |lit| expr.* = .{ .literal = lit };
        },
        .binary => |*b| try optimizeBinary(allocator, expr, b),
        .grouping => |inner| {
            try optimizeExpr(allocator, inner);
            // Parentheses are purely a parse-time grouping device — nothing
            // beyond here (compileExpr included) treats `.grouping`
            // differently from its inner expression, so collapsing it away
            // is free and lets a fold "see through" it either direction.
            expr.* = inner.*;
        },
        .assign => |a| try optimizeExpr(allocator, a.value),
        .call => |c| for (c.args) |arg| try optimizeExpr(allocator, arg),
        .method_call => |mc| {
            try optimizeExpr(allocator, mc.base);
            for (mc.args) |arg| try optimizeExpr(allocator, arg);
        },
        .array_literal => |elems| for (elems) |elem| try optimizeExpr(allocator, elem),
        .index => |ix| {
            try optimizeExpr(allocator, ix.base);
            try optimizeExpr(allocator, ix.index);
        },
        .index_assign => |ia| {
            try optimizeExpr(allocator, ia.base);
            try optimizeExpr(allocator, ia.index);
            try optimizeExpr(allocator, ia.value);
        },
        .struct_literal => |sl| for (sl.fields) |f| try optimizeExpr(allocator, f.value),
        .field_access => |fa| try optimizeExpr(allocator, fa.base),
        .field_assign => |fa| {
            try optimizeExpr(allocator, fa.base);
            try optimizeExpr(allocator, fa.value);
        },
        .slice => |sl| {
            try optimizeExpr(allocator, sl.base);
            try optimizeExpr(allocator, sl.start);
            try optimizeExpr(allocator, sl.end);
        },
        .len_of => |e| try optimizeExpr(allocator, e),
        .read_bytes => |r| try optimizeExpr(allocator, r.stream),
        .write_value => |w| {
            try optimizeExpr(allocator, w.stream);
            try optimizeExpr(allocator, w.value);
        },
        .write_bytes => |w| {
            try optimizeExpr(allocator, w.stream);
            try optimizeExpr(allocator, w.count);
        },
        .open_file => |o| try optimizeExpr(allocator, o.path),
        .map_literal => |entries| for (entries) |entry| try optimizeExpr(allocator, entry.value),
        .list_push => |p| {
            try optimizeExpr(allocator, p.list);
            try optimizeExpr(allocator, p.value);
        },
        .map_has => |h| {
            try optimizeExpr(allocator, h.map);
            try optimizeExpr(allocator, h.key);
        },
        .map_delete => |d| {
            try optimizeExpr(allocator, d.map);
            try optimizeExpr(allocator, d.key);
        },
        .map_keys => |m| try optimizeExpr(allocator, m),
        .json_parse => |j| try optimizeExpr(allocator, j.count),
        .json_stringify => |e| try optimizeExpr(allocator, e),
        .int_parse => |e| try optimizeExpr(allocator, e),
        .float_parse => |e| try optimizeExpr(allocator, e),
        .env_get => |e| try optimizeExpr(allocator, e),
        .env_has => |e| try optimizeExpr(allocator, e),
        .path_exists => |e| try optimizeExpr(allocator, e),
        .list_dir => |e| try optimizeExpr(allocator, e),
        .path_remove => |e| try optimizeExpr(allocator, e),
        .path_rename => |r| {
            try optimizeExpr(allocator, r.from);
            try optimizeExpr(allocator, r.to);
        },
        .path_mkdir => |e| try optimizeExpr(allocator, e),
        .exec => |x| {
            try optimizeExpr(allocator, x.command);
            try optimizeExpr(allocator, x.args);
        },
        .random_range => |r| {
            try optimizeExpr(allocator, r.start);
            try optimizeExpr(allocator, r.end);
        },
        .char_ord => |e| try optimizeExpr(allocator, e),
        .char_chr => |e| try optimizeExpr(allocator, e),
        .list_join => |j| {
            try optimizeExpr(allocator, j.list);
            try optimizeExpr(allocator, j.sep);
        },
        .string_interp => |parts| for (parts) |*part| switch (part.*) {
            .literal => {},
            .expr => |e| try optimizeExpr(allocator, e),
        },
    }
}

/// `and`/`or` fold around their short-circuit rule specifically (see
/// `compileLogicAnd`/`compileLogicOr` in compiler.zig, which this mirrors):
/// once `left` is a known constant bool, the VM would already skip
/// evaluating `right` entirely for one outcome (`false and right`, `true or
/// right`) — folding straight to that literal, `right` and all, changes
/// nothing observable, even if `right` has side effects, because it was
/// never going to run anyway. For the other outcome (`true and right`,
/// `false or right`) `right` DOES still run — but its value alone is now
/// the whole expression's, so the wrapping `and`/`or` itself is redundant
/// and folds away, leaving just (optimized) `right`. Every other binary
/// operator only folds when BOTH operands are already literals (see
/// `foldBinary`) — there's no partial-constant shortcut for arithmetic the
/// way short-circuiting gives `and`/`or`.
fn optimizeBinary(allocator: std.mem.Allocator, expr: *ast.Expr, b: *ast.Expr.Binary) std.mem.Allocator.Error!void {
    if (b.op == .logic_and or b.op == .logic_or) {
        try optimizeExpr(allocator, b.left);
        if (b.left.* == .literal and b.left.literal == .boolean) {
            const l = b.left.literal.boolean;
            const decided = (b.op == .logic_and and !l) or (b.op == .logic_or and l);
            if (decided) {
                expr.* = .{ .literal = .{ .boolean = l } };
                return;
            }
            try optimizeExpr(allocator, b.right);
            expr.* = b.right.*;
            return;
        }
        try optimizeExpr(allocator, b.right);
        return;
    }

    try optimizeExpr(allocator, b.left);
    try optimizeExpr(allocator, b.right);
    if (b.left.* == .literal and b.right.* == .literal) {
        if (try foldBinary(allocator, b.op, b.left.literal, b.right.literal)) |lit| expr.* = .{ .literal = lit };
    }
}

/// `-x`/`!x` on a literal operand. Numeric negation is skipped (leaving the
/// original `.unary` node in place) on the one input where it would
/// overflow `i64` (negating `minInt(i64)`) — matching `vm.zig`'s own `.neg`
/// handler, which has no overflow check of its own for this either; not
/// folding just means that operand reaches the VM exactly as before,
/// behaving exactly as it always has.
fn foldUnary(op: ast.UnaryOp, operand: ast.Expr) ?ast.Literal {
    if (operand != .literal) return null;
    return switch (op) {
        .negate => switch (operand.literal) {
            .int => |v| blk: {
                const negated, const overflow = @subWithOverflow(@as(i64, 0), v);
                break :blk if (overflow != 0) null else .{ .int = negated };
            },
            .float => |v| .{ .float = -v },
            .string, .boolean, .null_value => null,
        },
        .not => switch (operand.literal) {
            .boolean => |v| .{ .boolean = !v },
            .int, .float, .string, .null_value => null,
        },
    };
}

fn isNumericLiteral(l: ast.Literal) bool {
    return l == .int or l == .float;
}

/// Asserts `isNumericLiteral(l)`.
fn literalAsFloat(l: ast.Literal) f64 {
    return switch (l) {
        .int => |v| @floatFromInt(v),
        .float => |v| v,
        else => unreachable,
    };
}

/// Folds one binary operator over two ALREADY-literal operands, or returns
/// `null` when it can't (either the operand types don't support `op` at
/// all — folding leaves that to compiler.zig's own `inferBinaryType` to
/// diagnose exactly as it would have unfolded — or they do, but this
/// specific pair of values would raise a `RuntimeError` at runtime, which
/// folding must not silently swallow). `.logic_and`/`.logic_or` never reach
/// here — `optimizeBinary` handles both itself, before either operand is
/// necessarily literal.
fn foldBinary(allocator: std.mem.Allocator, op: ast.BinaryOp, a: ast.Literal, b: ast.Literal) std.mem.Allocator.Error!?ast.Literal {
    return switch (op) {
        .eq => .{ .boolean = literalEql(a, b) },
        .neq => .{ .boolean = !literalEql(a, b) },
        .add => if (isNumericLiteral(a) and isNumericLiteral(b))
            foldArith(.add, a, b)
        else if (a == .string and b == .string)
            .{ .string = try std.mem.concat(allocator, u8, &.{ a.string, b.string }) }
        else
            null,
        .sub, .mul, .div, .mod, .pow => if (isNumericLiteral(a) and isNumericLiteral(b)) foldArith(op, a, b) else null,
        .lt, .lte, .gt, .gte => if (isNumericLiteral(a) and isNumericLiteral(b))
            .{ .boolean = numericCompare(op, a, b) }
        else if (a == .string and b == .string)
            .{ .boolean = stringCompare(op, a.string, b.string) }
        else
            null,
        .logic_and, .logic_or => unreachable, // handled by optimizeBinary before this is ever called
    };
}

fn checkedAddI64(x: i64, y: i64) ?i64 {
    const r, const overflow = @addWithOverflow(x, y);
    return if (overflow != 0) null else r;
}

fn checkedSubI64(x: i64, y: i64) ?i64 {
    const r, const overflow = @subWithOverflow(x, y);
    return if (overflow != 0) null else r;
}

fn checkedMulI64(x: i64, y: i64) ?i64 {
    const r, const overflow = @mulWithOverflow(x, y);
    return if (overflow != 0) null else r;
}

/// `+`/`-`/`*`/`/`/`%`/`**` on two already-numeric literals — mirrors
/// `vm.zig`'s `add`/`sub`/`mul`/`div`/`mod`/`pow` exactly: int/int stays
/// int (overflow-checked, `null` on overflow so the caller leaves it
/// unfolded), any other pairing promotes both to `float` first, and
/// int/int division or modulo by a literal zero is left unfolded rather
/// than folded into a value that pretends `RuntimeError.DivisionByZero`
/// never would have fired.
fn foldArith(op: ast.BinaryOp, a: ast.Literal, b: ast.Literal) ?ast.Literal {
    if (a == .int and b == .int) {
        const x = a.int;
        const y = b.int;
        switch (op) {
            .add => return if (checkedAddI64(x, y)) |r| .{ .int = r } else null,
            .sub => return if (checkedSubI64(x, y)) |r| .{ .int = r } else null,
            .mul => return if (checkedMulI64(x, y)) |r| .{ .int = r } else null,
            .div => {
                if (y == 0) return null;
                if (x == std.math.minInt(i64) and y == -1) return null;
                return .{ .int = @divTrunc(x, y) };
            },
            .mod => {
                if (y == 0) return null;
                return .{ .int = @rem(x, y) };
            },
            .pow => {
                if (y >= 0) {
                    const r = std.math.powi(i64, x, y) catch return null;
                    return .{ .int = r };
                }
                return .{ .float = std.math.pow(f64, @floatFromInt(x), @floatFromInt(y)) };
            },
            else => unreachable,
        }
    }
    const x = literalAsFloat(a);
    const y = literalAsFloat(b);
    return switch (op) {
        .add => .{ .float = x + y },
        .sub => .{ .float = x - y },
        .mul => .{ .float = x * y },
        .div => .{ .float = x / y },
        .mod => .{ .float = @mod(x, y) },
        .pow => .{ .float = std.math.pow(f64, x, y) },
        else => unreachable,
    };
}

/// `<`/`<=`/`>`/`>=` on two already-numeric literals — mirrors `vm.zig`'s
/// `compare`.
fn numericCompare(op: ast.BinaryOp, a: ast.Literal, b: ast.Literal) bool {
    if (a == .int and b == .int) {
        return switch (op) {
            .lt => a.int < b.int,
            .lte => a.int <= b.int,
            .gt => a.int > b.int,
            .gte => a.int >= b.int,
            else => unreachable,
        };
    }
    const x = literalAsFloat(a);
    const y = literalAsFloat(b);
    return switch (op) {
        .lt => x < y,
        .lte => x <= y,
        .gt => x > y,
        .gte => x >= y,
        else => unreachable,
    };
}

/// `<`/`<=`/`>`/`>=` on two already-string literals — byte-lexicographic,
/// mirroring `vm.zig`'s `compare`'s own `std.mem.order` string branch.
fn stringCompare(op: ast.BinaryOp, a: []const u8, b: []const u8) bool {
    const ord = std.mem.order(u8, a, b);
    return switch (op) {
        .lt => ord == .lt,
        .lte => ord != .gt,
        .gt => ord == .gt,
        .gte => ord != .lt,
        else => unreachable,
    };
}

/// `==`/`!=` on two already-literal operands of ANY kind — mirrors
/// `value.zig`'s `Value.eql`: numeric compares across int/float by value,
/// string compares by content, and any other mismatched pair (including
/// one numeric one not) is simply unequal rather than an error, so unlike
/// every other operator this one always folds.
fn literalEql(a: ast.Literal, b: ast.Literal) bool {
    if (isNumericLiteral(a) and isNumericLiteral(b)) {
        if (a == .int and b == .int) return a.int == b.int;
        return literalAsFloat(a) == literalAsFloat(b);
    }
    if (a == .string and b == .string) return std.mem.eql(u8, a.string, b.string);
    return switch (a) {
        .int, .float, .string => false, // the b == same-kind case already returned above
        .boolean => |av| b == .boolean and av == b.boolean,
        .null_value => b == .null_value,
    };
}

// ---- Tests -----------------------------------------------------------------

const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const compiler_mod = @import("compiler.zig");
const chunk_mod = @import("chunk.zig");
const vm_mod = @import("vm.zig");

/// Lexes, parses, optimizes, compiles, and runs `source` end to end,
/// returning whatever it printed and the compiled program (so a test can
/// also inspect its disassembly) — the optimizer-pipeline counterpart to
/// compiler.zig's own `runProgram` test helper.
fn runOptimized(allocator: std.mem.Allocator, source: []const u8, buf: []u8) !struct { output: []const u8, compiled: chunk_mod.Program } {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try optimizeProgram(allocator, try parser.parseProgram());

    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileProgram(program);

    var vm = vm_mod.Vm.init(allocator);
    var writer = std.Io.Writer.fixed(buf);
    try vm.run(&compiled, .{ .out = &writer });
    return .{ .output = writer.buffered(), .compiled = compiled };
}

fn disassembleToBuf(compiled: *chunk_mod.Program, buf: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try compiled.disassemble(&writer);
    return writer.buffered();
}

test "folds int arithmetic" {
    const allocator = std.testing.allocator;
    var one = ast.Expr{ .literal = .{ .int = 1 } };
    var two = ast.Expr{ .literal = .{ .int = 2 } };
    var sum = ast.Expr{ .binary = .{ .left = &one, .op = .add, .right = &two } };
    try optimizeExpr(allocator, &sum);
    try std.testing.expect(sum == .literal);
    try std.testing.expectEqual(@as(i64, 3), sum.literal.int);
}

test "folds nested arithmetic through a grouping" {
    const allocator = std.testing.allocator;
    var one = ast.Expr{ .literal = .{ .int = 1 } };
    var two = ast.Expr{ .literal = .{ .int = 2 } };
    var sum = ast.Expr{ .binary = .{ .left = &one, .op = .add, .right = &two } };
    var group = ast.Expr{ .grouping = &sum };
    var three = ast.Expr{ .literal = .{ .int = 3 } };
    var product = ast.Expr{ .binary = .{ .left = &group, .op = .mul, .right = &three } };

    try optimizeExpr(allocator, &product);
    try std.testing.expect(product == .literal);
    try std.testing.expectEqual(@as(i64, 9), product.literal.int);
}

test "folds mixed int/float arithmetic by promoting to float" {
    const allocator = std.testing.allocator;
    var one = ast.Expr{ .literal = .{ .int = 1 } };
    var half = ast.Expr{ .literal = .{ .float = 0.5 } };
    var sum = ast.Expr{ .binary = .{ .left = &one, .op = .add, .right = &half } };
    try optimizeExpr(allocator, &sum);
    try std.testing.expect(sum == .literal);
    try std.testing.expectEqual(@as(f64, 1.5), sum.literal.float);
}

test "does not fold integer division by a literal zero" {
    const allocator = std.testing.allocator;
    var one = ast.Expr{ .literal = .{ .int = 1 } };
    var zero = ast.Expr{ .literal = .{ .int = 0 } };
    var div = ast.Expr{ .binary = .{ .left = &one, .op = .div, .right = &zero } };
    try optimizeExpr(allocator, &div);
    try std.testing.expect(div == .binary); // left unfolded — the VM still raises DivisionByZero
}

test "does not fold an int addition that would overflow" {
    const allocator = std.testing.allocator;
    var max = ast.Expr{ .literal = .{ .int = std.math.maxInt(i64) } };
    var one = ast.Expr{ .literal = .{ .int = 1 } };
    var sum = ast.Expr{ .binary = .{ .left = &max, .op = .add, .right = &one } };
    try optimizeExpr(allocator, &sum);
    try std.testing.expect(sum == .binary);
}

test "folds string concatenation" {
    const allocator = std.testing.allocator;
    var a = ast.Expr{ .literal = .{ .string = "foo" } };
    var b = ast.Expr{ .literal = .{ .string = "bar" } };
    var concat = ast.Expr{ .binary = .{ .left = &a, .op = .add, .right = &b } };
    try optimizeExpr(allocator, &concat);
    defer allocator.free(concat.literal.string);
    try std.testing.expect(concat == .literal);
    try std.testing.expectEqualStrings("foobar", concat.literal.string);
}

test "does not fold a numeric plus string addition, leaving the type error for the compiler" {
    const allocator = std.testing.allocator;
    var one = ast.Expr{ .literal = .{ .int = 1 } };
    var s = ast.Expr{ .literal = .{ .string = "x" } };
    var sum = ast.Expr{ .binary = .{ .left = &one, .op = .add, .right = &s } };
    try optimizeExpr(allocator, &sum);
    try std.testing.expect(sum == .binary);
}

test "folds equality across mismatched literal kinds to false" {
    const allocator = std.testing.allocator;
    var one = ast.Expr{ .literal = .{ .int = 1 } };
    var s = ast.Expr{ .literal = .{ .string = "1" } };
    var eq = ast.Expr{ .binary = .{ .left = &one, .op = .eq, .right = &s } };
    try optimizeExpr(allocator, &eq);
    try std.testing.expect(eq == .literal);
    try std.testing.expectEqual(false, eq.literal.boolean);
}

test "folds unary negate and not" {
    const allocator = std.testing.allocator;
    var five = ast.Expr{ .literal = .{ .int = 5 } };
    var neg = ast.Expr{ .unary = .{ .op = .negate, .right = &five } };
    try optimizeExpr(allocator, &neg);
    try std.testing.expectEqual(@as(i64, -5), neg.literal.int);

    var t = ast.Expr{ .literal = .{ .boolean = true } };
    var not_t = ast.Expr{ .unary = .{ .op = .not, .right = &t } };
    try optimizeExpr(allocator, &not_t);
    try std.testing.expectEqual(false, not_t.literal.boolean);
}

test "logic_and with a false constant left side folds to false without touching the right side" {
    const allocator = std.testing.allocator;
    var f = ast.Expr{ .literal = .{ .boolean = false } };
    // A right side that would fail to fold (mismatched types) if it were
    // ever visited as part of folding a *result*, proving it's genuinely
    // skipped rather than evaluated-then-discarded.
    var one = ast.Expr{ .literal = .{ .int = 1 } };
    var s = ast.Expr{ .literal = .{ .string = "x" } };
    var right = ast.Expr{ .binary = .{ .left = &one, .op = .add, .right = &s } };
    var and_expr = ast.Expr{ .binary = .{ .left = &f, .op = .logic_and, .right = &right } };

    try optimizeExpr(allocator, &and_expr);
    try std.testing.expect(and_expr == .literal);
    try std.testing.expectEqual(false, and_expr.literal.boolean);
}

test "logic_and with a true constant left side folds away to just the right side" {
    const allocator = std.testing.allocator;
    var t = ast.Expr{ .literal = .{ .boolean = true } };
    var one = ast.Expr{ .literal = .{ .int = 1 } };
    var two = ast.Expr{ .literal = .{ .int = 2 } };
    var right = ast.Expr{ .binary = .{ .left = &one, .op = .add, .right = &two } };
    var and_expr = ast.Expr{ .binary = .{ .left = &t, .op = .logic_and, .right = &right } };

    try optimizeExpr(allocator, &and_expr);
    try std.testing.expect(and_expr == .literal);
    try std.testing.expectEqual(@as(i64, 3), and_expr.literal.int);
}

test "if with a constant true condition collapses to just the then-branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stmts = [_]ast.Stmt{
        .{ .kind = .{ .if_stmt = .{
            .condition = try makeLiteral(allocator, .{ .boolean = true }),
            .then_branch = try makePrintStmt(allocator, .{ .int = 1 }),
            .else_branch = try makePrintStmt(allocator, .{ .int = 2 }),
        } }, .line = 1 },
    };
    const result = try optimizeStmts(allocator, &stmts);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].kind == .block);
    try std.testing.expectEqual(@as(usize, 1), result[0].kind.block.len);
    try std.testing.expectEqual(@as(i64, 1), result[0].kind.block[0].kind.print_stmt.literal.int);
}

test "if with a constant false condition and no else becomes an empty block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stmts = [_]ast.Stmt{
        .{ .kind = .{ .if_stmt = .{
            .condition = try makeLiteral(allocator, .{ .boolean = false }),
            .then_branch = try makePrintStmt(allocator, .{ .int = 1 }),
            .else_branch = null,
        } }, .line = 1 },
    };
    const result = try optimizeStmts(allocator, &stmts);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].kind == .block);
    try std.testing.expectEqual(@as(usize, 0), result[0].kind.block.len);
}

test "while with a constant false condition becomes an empty block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stmts = [_]ast.Stmt{
        .{ .kind = .{ .while_stmt = .{
            .condition = try makeLiteral(allocator, .{ .boolean = false }),
            .body = try makePrintStmt(allocator, .{ .int = 1 }),
        } }, .line = 1 },
    };
    const result = try optimizeStmts(allocator, &stmts);
    try std.testing.expect(result[0].kind == .block);
    try std.testing.expectEqual(@as(usize, 0), result[0].kind.block.len);
}

test "for over an empty constant range becomes an empty block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stmts = [_]ast.Stmt{
        .{ .kind = .{ .for_stmt = .{
            .var_name = "i",
            .start = try makeLiteral(allocator, .{ .int = 5 }),
            .end = try makeLiteral(allocator, .{ .int = 5 }),
            .body = try makePrintStmt(allocator, .{ .int = 1 }),
        } }, .line = 1 },
    };
    const result = try optimizeStmts(allocator, &stmts);
    try std.testing.expect(result[0].kind == .block);
    try std.testing.expectEqual(@as(usize, 0), result[0].kind.block.len);
}

test "statements after a return/exit/throw are dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stmts = [_]ast.Stmt{
        .{ .kind = .{ .return_stmt = try makeLiteral(allocator, .{ .int = 1 }) }, .line = 1 },
        .{ .kind = .{ .print_stmt = try makeLiteral(allocator, .{ .int = 2 }) }, .line = 2 },
        .{ .kind = .{ .print_stmt = try makeLiteral(allocator, .{ .int = 3 }) }, .line = 3 },
    };
    const result = try optimizeStmts(allocator, &stmts);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].kind == .return_stmt);
}

test "a top-level declaration after a terminator still survives, only executable code is dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var f_body = [_]ast.Stmt{
        .{ .kind = .{ .return_stmt = try makeLiteral(allocator, .{ .int = 1 }) }, .line = 4 },
    };
    var stmts = [_]ast.Stmt{
        .{ .kind = .{ .exit_stmt = try makeLiteral(allocator, .{ .int = 0 }) }, .line = 1 },
        .{ .kind = .{ .print_stmt = try makeLiteral(allocator, .{ .int = 1 }) }, .line = 2 }, // dropped
        .{ .kind = .{ .function_decl = .{ .name = "f", .params = &.{}, .return_type = .int, .body = &f_body, .exported = true } }, .line = 3 }, // kept — a registration, not "executed" here
    };
    const result = try optimizeStmts(allocator, &stmts);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expect(result[0].kind == .exit_stmt);
    try std.testing.expect(result[1].kind == .function_decl);
}

fn makeLiteral(allocator: std.mem.Allocator, lit: ast.Literal) !*ast.Expr {
    const e = try allocator.create(ast.Expr);
    e.* = .{ .literal = lit };
    return e;
}

fn makePrintStmt(allocator: std.mem.Allocator, lit: ast.Literal) !*ast.Stmt {
    const s = try allocator.create(ast.Stmt);
    s.* = .{ .kind = .{ .print_stmt = try makeLiteral(allocator, lit) }, .line = 1 };
    return s;
}

test "end to end: constant folding shrinks the emitted bytecode" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var disasm_buf: [1024]u8 = undefined;

    var result = try runOptimized(allocator, "print 1 + 2 * 3\n", &buf);
    defer result.compiled.deinit(allocator);
    try std.testing.expectEqualStrings("7\n", result.output);

    const disasm = try disassembleToBuf(&result.compiled, &disasm_buf);
    try std.testing.expect(std.mem.indexOf(u8, disasm, " add") == null);
    try std.testing.expect(std.mem.indexOf(u8, disasm, " mul") == null);
}

test "end to end: a false-guarded call is never compiled in at all" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;

    var result = try runOptimized(allocator,
        \\func sideEffect() -> bool {
        \\  print "ran"
        \\  return true
        \\}
        \\print false and sideEffect()
        \\
    , &buf);
    defer result.compiled.deinit(allocator);
    try std.testing.expectEqualStrings("false\n", result.output);

    // The call to sideEffect from main's own chunk is gone (its function is
    // still compiled — it could, in principle, be called some other way —
    // but nothing in main's own bytecode reaches it any more).
    var main_only_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&main_only_buf);
    try result.compiled.main.disassemble(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "call") == null);
}

test "end to end: dead code after exit never runs and does not change observable output" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var result = try runOptimized(allocator, "print 1\nexit 0\nprint 2\n", &buf);
    defer result.compiled.deinit(allocator);
    try std.testing.expectEqualStrings("1\n", result.output);
}

test "end to end: an if/while/for battery matches the same output with and without optimization" {
    const allocator = std.testing.allocator;
    const source =
        \\int total := 0
        \\for i in 0..5 {
        \\  if i % 2 == 0 {
        \\    total := total + i
        \\  } else {
        \\    total := total - 1
        \\  }
        \\}
        \\print total
        \\while false {
        \\  print 99
        \\}
        \\print "done"
        \\
    ;

    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var unopt_parser = parser_mod.Parser.init(allocator, tokens);
    defer unopt_parser.deinit();
    const unopt_program = try unopt_parser.parseProgram();
    var unopt_compiled = try compiler_mod.compile(allocator, unopt_program);
    defer unopt_compiled.deinit(allocator);
    var unopt_buf: [256]u8 = undefined;
    var unopt_writer = std.Io.Writer.fixed(&unopt_buf);
    var unopt_vm = vm_mod.Vm.init(allocator);
    try unopt_vm.run(&unopt_compiled, .{ .out = &unopt_writer });

    var buf: [256]u8 = undefined;
    var result = try runOptimized(allocator, source, &buf);
    defer result.compiled.deinit(allocator);

    try std.testing.expectEqualStrings(unopt_writer.buffered(), result.output);
}
