//! Resolves locals/parameters within one function or method body — the
//! `<declaration>`-shaped counterpart to symbols.zig's top-level table.
//! Butter functions never nest or close over an enclosing scope ("a
//! function body resolves only its own parameters and locals",
//! GRAMMAR.bnf), so every local anywhere in a body — however deeply
//! nested inside `if`/`while`/`for`/`try` — is resolved against ONE flat
//! per-function list here, keyed by "nearest declaration at or before the
//! use site's line" (no hoisting: a use before its own ':=' never
//! resolves).
//!
//! This deliberately doesn't model a block's own exit the way the real
//! compiler's lexical scoping does (`compiler.zig`'s `popLocalsAbove`) —
//! a name declared inside an `if`/`while`/`for`/`try` body and referenced
//! after that block closes still resolves here, where the real compiler
//! would reject it as `SemanticError.UndefinedVariable`. Accepted for this
//! pass: hover/definition/completion may be slightly too permissive in a
//! shadowing/block-exit edge case, but real diagnostics (which run the
//! actual compiler — see diagnostics.zig) are entirely unaffected by this
//! simplification.

const std = @import("std");
const butter = @import("butter");
const ast = butter.ast;
const tk = @import("tokens.zig");
const Token = tk.Token;
const Position = tk.Position;
const symbols = @import("symbols.zig");

pub const LocalSymbol = struct {
    name: []const u8,
    pos: Position,
    /// Zero-based line this local's declaration starts on.
    decl_line: u32,
    type: ast.ValueType,
    named_type: ?[]const u8 = null,
    func_sig: ?*const ast.FuncSig = null,
    array_size: ?ast.ArraySpec = null,
    is_param: bool = false,
    /// Set only for a method's implicit receiver binding (synthesized
    /// here from `FunctionSymbol.receiver_name`/`receiver_type` — the AST
    /// never represents it as an ordinary `Param`).
    is_receiver: bool = false,
};

pub const FunctionScope = struct {
    locals: []const LocalSymbol,

    /// The nearest declaration of `name` at or before zero-based
    /// `at_line` — see this file's own doc comment for what this
    /// deliberately doesn't model.
    pub fn resolve(self: FunctionScope, name: []const u8, at_line: u32) ?LocalSymbol {
        var best: ?LocalSymbol = null;
        for (self.locals) |l| {
            if (l.decl_line <= at_line and std.mem.eql(u8, l.name, name)) {
                if (best == null or l.decl_line >= best.?.decl_line) best = l;
            }
        }
        return best;
    }
};

fn posOf(tok: ?Token, fallback_line_1based: usize) Position {
    if (tok) |t| return Position.fromToken(t);
    return .{ .line = @intCast(fallback_line_1based - 1), .character = 0 };
}

fn nextIdentifier(tokens: []const Token, idx: usize) ?Token {
    if (idx + 1 >= tokens.len) return null;
    const t = tokens[idx + 1];
    return if (t.type == .identifier) t else null;
}

/// Builds the flat scope for one function/method, seeded with its
/// parameters (and, for a method, its receiver) before walking `body`.
pub fn build(allocator: std.mem.Allocator, tokens: []const Token, func: symbols.FunctionSymbol) !FunctionScope {
    var locals: std.ArrayList(LocalSymbol) = .empty;

    for (func.params) |p| {
        try locals.append(allocator, .{
            .name = p.param.name,
            .pos = p.pos,
            .decl_line = func.line,
            .type = p.param.type,
            .named_type = p.param.named_type,
            .func_sig = p.param.func_sig,
            .array_size = p.param.array_size,
            .is_param = true,
        });
    }
    if (func.isMethod()) {
        try locals.append(allocator, .{
            .name = func.receiver_name.?,
            .pos = func.receiver_name_pos orelse .{ .line = func.line, .character = 0 },
            .decl_line = func.line,
            .type = .named,
            .named_type = func.receiver_type,
            .is_param = true,
            .is_receiver = true,
        });
    }

    try walkStmts(allocator, tokens, func.body, &locals);
    return .{ .locals = try locals.toOwnedSlice(allocator) };
}

fn walkStmts(allocator: std.mem.Allocator, tokens: []const Token, stmts: []const ast.Stmt, locals: *std.ArrayList(LocalSymbol)) std.mem.Allocator.Error!void {
    for (stmts) |*stmt| {
        switch (stmt.kind) {
            .var_decl => |vd| {
                const start_idx = tk.firstTokenOnLine(tokens, stmt.line);
                const name_tok = if (start_idx) |si| tk.singleDeclarationName(tokens, si) else null;
                try locals.append(allocator, .{
                    .name = vd.name,
                    .pos = posOf(name_tok, stmt.line),
                    .decl_line = @intCast(stmt.line - 1),
                    .type = vd.type,
                    .named_type = vd.named_type,
                    .func_sig = vd.func_sig,
                    .array_size = if (vd.array_len) |n| .{ .fixed = n } else null,
                });
            },
            .block => |b| try walkStmts(allocator, tokens, b, locals),
            .if_stmt => |i| {
                try walkBody(allocator, tokens, i.then_branch, locals);
                if (i.else_branch) |eb| try walkBody(allocator, tokens, eb, locals);
            },
            .while_stmt => |w| try walkBody(allocator, tokens, w.body, locals),
            .for_stmt => |f| {
                const kw_idx = tk.findKeywordOnLine(tokens, stmt.line, .kw_for);
                const name_tok = if (kw_idx) |ki| nextIdentifier(tokens, ki) else null;
                try locals.append(allocator, .{
                    .name = f.var_name,
                    .pos = posOf(name_tok, stmt.line),
                    .decl_line = @intCast(stmt.line - 1),
                    .type = .int,
                });
                try walkBody(allocator, tokens, f.body, locals);
            },
            .try_stmt => |t| {
                try walkStmts(allocator, tokens, t.body, locals);

                // `error_var`'s own line isn't `stmt.line` (the 'try'
                // keyword's line) — 'catch IDENTIFIER' may be many lines
                // later. Found by locating the try-block's own closing
                // '}' (skipping any nested try/catch inside it) and
                // searching for 'catch' from there.
                var err_tok: ?Token = null;
                var err_line = stmt.line;
                if (tk.findKeywordOnLine(tokens, stmt.line, .kw_try)) |try_kw| {
                    if (tk.findFrom(tokens, try_kw, .lbrace)) |open| {
                        if (tk.matchingClose(tokens, open)) |close| {
                            if (tk.findFrom(tokens, close, .kw_catch)) |catch_idx| {
                                err_tok = nextIdentifier(tokens, catch_idx);
                                err_line = tokens[catch_idx].line;
                            }
                        }
                    }
                }
                try locals.append(allocator, .{
                    .name = t.error_var,
                    .pos = posOf(err_tok, err_line),
                    .decl_line = @intCast(err_line - 1),
                    .type = .named,
                    .named_type = "Error",
                });
                try walkStmts(allocator, tokens, t.handler, locals);
            },
            else => {},
        }
    }
}

/// `if`/`while`/`for`'s body is a bare `*ast.Stmt` — a `.block` most of
/// the time, but GRAMMAR.bnf allows any single `<declaration>` there with
/// no braces at all (design note 3u). Treated uniformly: a `.block`'s own
/// statement list walks directly; anything else walks as a synthesized
/// one-statement list (the same shape `walkStmts` already expects).
fn walkBody(allocator: std.mem.Allocator, tokens: []const Token, body: *const ast.Stmt, locals: *std.ArrayList(LocalSymbol)) std.mem.Allocator.Error!void {
    switch (body.kind) {
        .block => |b| try walkStmts(allocator, tokens, b, locals),
        else => {
            const single = [1]ast.Stmt{body.*};
            try walkStmts(allocator, tokens, &single, locals);
        },
    }
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;

fn buildScope(arena: std.mem.Allocator, source: []const u8) !FunctionScope {
    const tokens = try tk.tokenize(arena, source);
    var parser = butter.parser.Parser.init(arena, tokens);
    const program = try parser.parseProgram();
    const file_symbols = try symbols.build(arena, program, tokens, source);
    return build(arena, tokens, file_symbols.functions[0]);
}

test "resolve finds a parameter from anywhere in the body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scope = try buildScope(arena_state.allocator(), "func f(int n) -> int {\n    return n\n}\n");

    const found = scope.resolve("n", 1);
    try testing.expect(found != null);
    try testing.expect(found.?.is_param);
}

test "resolve finds a local declared before the use site, not after" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scope = try buildScope(arena_state.allocator(),
        \\func f() -> int {
        \\    int a := 1
        \\    int b := a + 1
        \\    return b
        \\}
        \\
    );

    // "b" is declared on line 2 (0-based); a use strictly before that
    // line must not resolve, but one on its own declaring line (or later)
    // must.
    try testing.expect(scope.resolve("b", 1) == null);
    try testing.expect(scope.resolve("b", 2) != null);
    try testing.expect(scope.resolve("b", 3) != null);
}

test "resolve finds a for-loop variable and a nested if-branch's local" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scope = try buildScope(arena_state.allocator(),
        \\func f() -> int {
        \\    for i in 0..10 {
        \\        if i > 5 {
        \\            int x := i
        \\            return x
        \\        }
        \\    }
        \\    return 0
        \\}
        \\
    );

    const loop_var = scope.resolve("i", 4);
    try testing.expect(loop_var != null);
    try testing.expectEqual(@as(ast.ValueType, .int), loop_var.?.type);

    const nested = scope.resolve("x", 4);
    try testing.expect(nested != null);
}

test "resolve finds a try/catch error variable, typed as the built-in Error struct" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scope = try buildScope(arena_state.allocator(),
        \\func f() -> int {
        \\    try {
        \\        return 1
        \\    }
        \\    catch e {
        \\        return 0
        \\    }
        \\}
        \\
    );

    const err = scope.resolve("e", 5);
    try testing.expect(err != null);
    try testing.expectEqualStrings("Error", err.?.named_type.?);
}

test "resolve finds a method's receiver binding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = "struct Point { int x }\nfunc (Point p) getX() -> int {\n    return p.x\n}\n";
    const tokens = try tk.tokenize(arena_state.allocator(), source);
    var parser = butter.parser.Parser.init(arena_state.allocator(), tokens);
    const program = try parser.parseProgram();
    const file_symbols = try symbols.build(arena_state.allocator(), program, tokens, source);
    const scope = try build(arena_state.allocator(), tokens, file_symbols.functions[0]);

    const recv = scope.resolve("p", 2);
    try testing.expect(recv != null);
    try testing.expect(recv.?.is_receiver);
    try testing.expectEqualStrings("Point", recv.?.named_type.?);
}
