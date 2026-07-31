//! AST node definitions for Butter, matching section 2 (SYNTAX GRAMMAR) of
//! GRAMMAR.bnf. Nodes are produced by `parser.Parser` into memory owned by
//! its arena; they borrow string data (identifiers, string contents)
//! directly from the source text — except a string literal/import path/
//! map key that actually uses a `\n`/`\t`/`\\`/`\"` escape (design note 3s),
//! which is decoded into a fresh arena-owned buffer instead.

const std = @import("std");

/// Re-exported so the AST and the ISA name the same three streams by the
/// same type (see `value.Stream` for why it's declared over there). Only
/// `Standard` appears in the AST — the three keyword-named streams, which
/// are the only streams source code can spell out. A `file` stream has no
/// syntax at all; it only ever comes from evaluating an `open` at runtime,
/// which is exactly why the stream that `read`/`write` act on is a general
/// `*Expr` here rather than a fixed tag (design note 3l).
pub const Stream = @import("value.zig").Stream;

/// `'read' | 'write' | 'append'` in the mode position of an `open`
/// (re-exported from `value` alongside `Stream`, same reasoning). Kept
/// distinct from the `read`/`write` *operations* that share those keywords:
/// the parser only ever looks for a mode where a mode is legal, so there is
/// no ambiguity to resolve.
pub const OpenMode = @import("value.zig").OpenMode;

pub const ValueType = enum {
    int,
    float,
    bool,
    string,
    /// A refcounted heap map (GRAMMAR.bnf design note 3m) — unlike the
    /// other four, this is always exactly one runtime value (a heap
    /// reference), never a run of raw stack slots, so it never takes the
    /// `[N]`/`[]` array suffix `Param`/`VarDecl`/`FunctionDecl` otherwise
    /// allow.
    map,
    /// A refcounted heap list (GRAMMAR.bnf design note 3m) — same story as
    /// `map`, but ordered/indexed by INT instead of by STRING key.
    list,
};

pub const UnaryOp = enum {
    negate, // '-'
    not, // '!'
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
    logic_or,
    logic_and,
};

pub const Literal = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    /// JSON's `null` (ISA.bnf section 12) — named `null_value`, not `null`,
    /// since `null` is a reserved word and can't name a union field
    /// directly (matching `value.Value.null_value`'s own naming).
    null_value,
};

/// A parameter's or a function's return type's optional array-ness: either
/// a fixed compile-time size (passed/returned by VALUE, a copy — see
/// GRAMMAR.bnf design note 3e) or `generic` (no declared size — passed by
/// REFERENCE instead, a single runtime `Value.array_ref` pointing at
/// whatever array the caller actually supplies, of whatever length it
/// happens to have — see design note 3e's generic-array addendum). Local
/// var-declarations don't get this: `ast.Stmt.VarDecl.array_len` stays a
/// plain `?u32`, since a local's own storage is always something concrete
/// this compiler allocated slots for, never a reference to someone else's.
pub const ArraySpec = union(enum) {
    fixed: u32,
    generic,
};

pub const Param = struct {
    type: ValueType,
    name: []const u8,
    /// null for a plain scalar parameter; see `ArraySpec` otherwise.
    array_size: ?ArraySpec = null,
};

pub const Expr = union(enum) {
    literal: Literal,
    variable: []const u8,
    unary: Unary,
    binary: Binary,
    grouping: *Expr,
    assign: Assign,
    call: Call,
    array_literal: []*Expr,
    index: Index,
    index_assign: IndexAssign,
    /// `<base>[start..end]` (GRAMMAR.bnf's Strings design notes) — a
    /// read-only substring, end exclusive, same convention as the
    /// for-loop's own range. Never produced as an assignment target: unlike
    /// `.index`, there is no `.slice_assign` counterpart — `assignment`
    /// only ever turns a `.variable` or `.index` shape into an lvalue, so
    /// `s[a..b] := v` falls through to its "invalid assignment target"
    /// error same as any other non-lvalue expression would.
    slice: Slice,
    /// `len(<expression>)`. Relaxed from a bare array name to an arbitrary
    /// expression (GRAMMAR.bnf design note 3m) now that a map/list is a
    /// genuine first-class runtime value — the compiler still special-cases
    /// a bare `.variable` naming a fixed/generic array to fold to a
    /// compile-time constant or `LOAD_REF_LEN` exactly as before (arrays
    /// still aren't first-class, design note 3e); anything else compiles as
    /// an ordinary expression followed by `LEN_VALUE`.
    len_of: *Expr,
    /// One of the three keyword-named streams, as a value.
    stream_literal: Stream.Standard,
    /// The bare `args` keyword (GRAMMAR.bnf design note 3p) — evaluates to a
    /// fresh `list` of the program's own command-line arguments, as
    /// strings. Unlike `stream_literal`, this isn't a compile-time constant:
    /// the argument count and text vary per run, so it compiles to a
    /// dedicated opcode (PUSH_ARGS, ISA.bnf) that builds the list from the
    /// VM's `Host.args` at run time.
    args_literal,
    read_bytes: ReadBytes,
    write_value: WriteValue,
    write_bytes: WriteBytes,
    open_file: OpenFile,
    /// `{ "k1": v1, "k2": v2, ... }` (GRAMMAR.bnf design note 3m). Keys are
    /// static STRING tokens, not arbitrary expressions — a dynamic key is
    /// still fully expressible via `m[expr] := v` once the map exists.
    map_literal: []MapEntry,
    /// `push(list, value)` — grows a list by one element, evaluating to its
    /// new length (mirroring `write`'s "evaluates to a count" convention).
    list_push: ListPush,
    /// `has(map, key)` — whether `key` is present, without the
    /// `RuntimeError.KeyNotFound` a bracket-read raises for a missing one.
    map_has: MapHas,
    /// `delete(map, key)` — removes `key` if present, evaluating to whether
    /// it was.
    map_delete: MapDelete,
    /// `keys(map)` — a fresh `list` of the map's own keys, in insertion
    /// order. How map/list iteration works (`for i in 0..len(ks) { ... }`)
    /// instead of a dedicated foreach form (GRAMMAR.bnf design note 3g).
    map_keys: *Expr,
    /// `json(buffer, count)` (GRAMMAR.bnf design note 3n) — parses the first
    /// `count` bytes of an `int` buffer as JSON, evaluating to whatever the
    /// document's root turns out to be. `buffer` is a bare array name, the
    /// same restriction `ReadBytes`'s destination has and for the same
    /// reason: arrays still aren't first-class (design note 3e).
    json_parse: JsonParse,
    /// `stringify(value)` (GRAMMAR.bnf design note 3o) — the reverse of
    /// `json_parse`: renders an arbitrary value as JSON text, evaluating to
    /// a fresh heap `string`. `value` is a general expression (unlike
    /// `json_parse`'s buffer, this has no array-identifier restriction to
    /// inherit — it reads a value, it doesn't name a buffer to fill).
    json_stringify: *Expr,
    /// `int(value)` (GRAMMAR.bnf design note 3r) — parses a `string` as a
    /// base-10 integer, evaluating to an `int`. Reuses the `int` TYPE
    /// keyword as call syntax, like `json`/`stringify` above; never
    /// ambiguous with a `<type>` use since that position is only ever
    /// consulted at the start of a var-declaration/param/return-type, never
    /// while parsing an expression.
    int_parse: *Expr,
    /// `float(value)` — the `float` counterpart to `int_parse`, parsing a
    /// `string` as a floating-point literal.
    float_parse: *Expr,

    pub const Unary = struct {
        op: UnaryOp,
        right: *Expr,
    };

    pub const Binary = struct {
        left: *Expr,
        op: BinaryOp,
        right: *Expr,
    };

    pub const Assign = struct {
        name: []const u8,
        value: *Expr,
    };

    pub const Call = struct {
        name: []const u8,
        args: []*Expr,
    };

    /// `<base>[index]`. `base` is a general expression, not just a bare
    /// name — this is what lets bracket-indexing CHAIN for map/list values
    /// (`doc["a"]["b"]`, GRAMMAR.bnf design note 3m), unlike an array
    /// (design note 3e), which still only ever resolves through a bare
    /// `.variable` base: the compiler rejects (or, for a non-identifier
    /// base, the VM rejects at run time) any other shape for a fixed/
    /// generic array target, since an array element is always scalar and
    /// therefore never itself indexable.
    pub const Index = struct {
        base: *Expr,
        index: *Expr,
    };

    pub const IndexAssign = struct {
        base: *Expr,
        index: *Expr,
        value: *Expr,
    };

    pub const Slice = struct {
        base: *Expr,
        start: *Expr,
        end: *Expr,
    };

    pub const MapEntry = struct {
        key: []const u8,
        value: *Expr,
    };

    pub const ListPush = struct {
        list: *Expr,
        value: *Expr,
    };

    pub const MapHas = struct {
        map: *Expr,
        key: *Expr,
    };

    pub const MapDelete = struct {
        map: *Expr,
        key: *Expr,
    };

    pub const JsonParse = struct {
        buffer: []const u8,
        count: *Expr,
    };

    /// `read(stream, buffer)` — fills `buffer`'s elements with raw bytes
    /// (one byte per element, 0-255) and evaluates to how many were read,
    /// 0 at end of input (GRAMMAR.bnf design note 3k). `stream` is an
    /// arbitrary expression so an opened file works everywhere `stdin`
    /// does, but `buffer` is still a bare array name for the same reason
    /// `Index`'s and `len_of`'s targets are: arrays aren't first-class
    /// values there'd be an expression to compute one from.
    pub const ReadBytes = struct {
        stream: *Expr,
        buffer: []const u8,
    };

    /// `write(stream, expr)` — writes `expr`'s value in exactly the
    /// rendering `print` uses but WITHOUT a trailing newline, and evaluates
    /// to how many bytes that took.
    pub const WriteValue = struct {
        stream: *Expr,
        value: *Expr,
    };

    /// `write(stream, buffer, count)` — writes the first `count` elements
    /// of `buffer` as raw bytes, the inverse of `ReadBytes`. Distinguished
    /// from `WriteValue` purely by argument count (see parser.zig's
    /// `writeExpr`), so `write(f, x)` and `write(f, buf, n)` never need
    /// different keywords.
    pub const WriteBytes = struct {
        stream: *Expr,
        buffer: []const u8,
        count: *Expr,
    };

    /// `open(path, mode)` — evaluates to a new stream naming that file
    /// (design note 3l). `path` is an arbitrary expression that must be a
    /// string at runtime; `mode` is a bare keyword, so which direction the
    /// file is opened in is always known at compile time.
    pub const OpenFile = struct {
        path: *Expr,
        mode: OpenMode,
    };
};

pub const Stmt = union(enum) {
    var_decl: VarDecl,
    block: []Stmt,
    if_stmt: If,
    while_stmt: While,
    print_stmt: *Expr,
    expr_stmt: *Expr,
    function_decl: FunctionDecl,
    return_stmt: *Expr,
    for_stmt: For,
    import_stmt: Import,
    /// `close <expression>` — a statement rather than an expression because,
    /// unlike `open`/`read`/`write`, it produces no value; `print` is the
    /// same shape for the same reason (design note 3l).
    close_stmt: *Expr,
    /// `exit <expression>` (design note 3q) — halts the whole program
    /// immediately, from anywhere (including deep inside nested calls, mid-
    /// loop, mid-expression-statement), propagating `expression`'s value as
    /// the process's own exit code. A statement, not an expression, for the
    /// same reason `close`/`print` are: it produces no value to a caller
    /// that, by definition, never gets to run.
    exit_stmt: *Expr,

    pub const VarDecl = struct {
        type: ValueType,
        name: []const u8,
        /// null for a plain scalar declaration; `Some(n)` means this
        /// declares a fixed-size array of `n` elements of `type` instead
        /// (see GRAMMAR.bnf design note 3e).
        array_len: ?u32 = null,
        initializer: ?*Expr,
    };

    pub const If = struct {
        condition: *Expr,
        then_branch: *Stmt,
        else_branch: ?*Stmt,
    };

    pub const While = struct {
        condition: *Expr,
        body: *Stmt,
    };

    /// Only ever produced at the top level (see parser.zig's
    /// `topLevelDeclaration`) — Butter has no nested functions or closures,
    /// so a `.function_decl` can never legally appear as the body of a
    /// block/if/while, even though the type itself doesn't forbid it.
    pub const FunctionDecl = struct {
        name: []const u8,
        params: []Param,
        return_type: ValueType,
        /// null for a plain scalar return type; see `ArraySpec` otherwise.
        return_array_size: ?ArraySpec = null,
        body: []Stmt,
        /// Whether this function is callable from a file that imports this
        /// one (see GRAMMAR.bnf design note h). Irrelevant for calls from
        /// within the same file, which are always allowed regardless.
        exported: bool = false,
    };

    /// `for var_name in start..end body` — always ascending, always step 1,
    /// end exclusive (see GRAMMAR.bnf design note 3f). `var_name` is a
    /// fresh int local scoped to the loop, per iteration re-usable but not
    /// visible outside it.
    pub const For = struct {
        var_name: []const u8,
        start: *Expr,
        end: *Expr,
        body: *Stmt,
    };

    /// `import "path/to/file.butter"` — only ever produced at the top level
    /// (see parser.zig's `topLevelDeclaration`), matching `function_decl`.
    /// `path` is exactly the string literal's contents, unresolved — the
    /// module loader (module.zig) is what turns it into an actual file to
    /// read, relative to the importing file's own directory.
    pub const Import = struct {
        path: []const u8,
    };
};

/// A parsed program: the top-level list of declarations.
pub const Program = []Stmt;

/// Writes an S-expression rendering of `expr`, primarily for debugging and
/// for making test assertions readable at a glance.
pub fn printExpr(writer: *std.Io.Writer, expr: *const Expr) std.Io.Writer.Error!void {
    switch (expr.*) {
        .literal => |lit| switch (lit) {
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .string => |v| try writer.print("\"{s}\"", .{v}),
            .boolean => |v| try writer.print("{}", .{v}),
            .null_value => try writer.writeAll("null"),
        },
        .variable => |name| try writer.writeAll(name),
        .unary => |u| {
            try writer.print("({s} ", .{switch (u.op) {
                .negate => "-",
                .not => "!",
            }});
            try printExpr(writer, u.right);
            try writer.writeAll(")");
        },
        .binary => |b| {
            try writer.print("({s} ", .{binaryOpLexeme(b.op)});
            try printExpr(writer, b.left);
            try writer.writeAll(" ");
            try printExpr(writer, b.right);
            try writer.writeAll(")");
        },
        .grouping => |inner| {
            try writer.writeAll("(group ");
            try printExpr(writer, inner);
            try writer.writeAll(")");
        },
        .assign => |a| {
            try writer.print("(:= {s} ", .{a.name});
            try printExpr(writer, a.value);
            try writer.writeAll(")");
        },
        .call => |c| {
            try writer.print("(call {s}", .{c.name});
            for (c.args) |arg| {
                try writer.writeAll(" ");
                try printExpr(writer, arg);
            }
            try writer.writeAll(")");
        },
        .array_literal => |elems| {
            try writer.writeAll("(array");
            for (elems) |elem| {
                try writer.writeAll(" ");
                try printExpr(writer, elem);
            }
            try writer.writeAll(")");
        },
        .index => |i| {
            try writer.writeAll("(index ");
            try printExpr(writer, i.base);
            try writer.writeAll(" ");
            try printExpr(writer, i.index);
            try writer.writeAll(")");
        },
        .index_assign => |ia| {
            try writer.writeAll("(:= (index ");
            try printExpr(writer, ia.base);
            try writer.writeAll(" ");
            try printExpr(writer, ia.index);
            try writer.writeAll(") ");
            try printExpr(writer, ia.value);
            try writer.writeAll(")");
        },
        .slice => |s| {
            try writer.writeAll("(slice ");
            try printExpr(writer, s.base);
            try writer.writeAll(" ");
            try printExpr(writer, s.start);
            try writer.writeAll(" ");
            try printExpr(writer, s.end);
            try writer.writeAll(")");
        },
        .len_of => |e| {
            try writer.writeAll("(len ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .stream_literal => |s| try writer.writeAll(s.name()),
        .args_literal => try writer.writeAll("args"),
        .read_bytes => |r| {
            try writer.writeAll("(read ");
            try printExpr(writer, r.stream);
            try writer.print(" {s})", .{r.buffer});
        },
        .write_value => |w| {
            try writer.writeAll("(write ");
            try printExpr(writer, w.stream);
            try writer.writeAll(" ");
            try printExpr(writer, w.value);
            try writer.writeAll(")");
        },
        .write_bytes => |w| {
            try writer.writeAll("(write ");
            try printExpr(writer, w.stream);
            try writer.print(" {s} ", .{w.buffer});
            try printExpr(writer, w.count);
            try writer.writeAll(")");
        },
        .open_file => |o| {
            try writer.writeAll("(open ");
            try printExpr(writer, o.path);
            try writer.print(" {s})", .{o.mode.name()});
        },
        .map_literal => |entries| {
            try writer.writeAll("(map");
            for (entries) |entry| {
                try writer.print(" (\"{s}\" ", .{entry.key});
                try printExpr(writer, entry.value);
                try writer.writeAll(")");
            }
            try writer.writeAll(")");
        },
        .list_push => |p| {
            try writer.writeAll("(push ");
            try printExpr(writer, p.list);
            try writer.writeAll(" ");
            try printExpr(writer, p.value);
            try writer.writeAll(")");
        },
        .map_has => |h| {
            try writer.writeAll("(has ");
            try printExpr(writer, h.map);
            try writer.writeAll(" ");
            try printExpr(writer, h.key);
            try writer.writeAll(")");
        },
        .map_delete => |d| {
            try writer.writeAll("(delete ");
            try printExpr(writer, d.map);
            try writer.writeAll(" ");
            try printExpr(writer, d.key);
            try writer.writeAll(")");
        },
        .map_keys => |m| {
            try writer.writeAll("(keys ");
            try printExpr(writer, m);
            try writer.writeAll(")");
        },
        .json_parse => |j| {
            try writer.print("(json {s} ", .{j.buffer});
            try printExpr(writer, j.count);
            try writer.writeAll(")");
        },
        .json_stringify => |e| {
            try writer.writeAll("(stringify ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .int_parse => |e| {
            try writer.writeAll("(int ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .float_parse => |e| {
            try writer.writeAll("(float ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
    }
}

fn binaryOpLexeme(op: BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .pow => "**",
        .eq => "==",
        .neq => "!=",
        .lt => "<",
        .lte => "<=",
        .gt => ">",
        .gte => ">=",
        .logic_or => "or",
        .logic_and => "and",
    };
}

fn printArraySpecSuffix(writer: *std.Io.Writer, spec: ArraySpec) std.Io.Writer.Error!void {
    switch (spec) {
        .fixed => |n| try writer.print("[{d}]", .{n}),
        .generic => try writer.writeAll("[]"),
    }
}

fn valueTypeName(t: ValueType) []const u8 {
    return switch (t) {
        .int => "int",
        .float => "float",
        .bool => "bool",
        .string => "string",
        .map => "map",
        .list => "list",
    };
}

/// Writes an S-expression rendering of `stmt`, indented by `depth` levels.
pub fn printStmt(writer: *std.Io.Writer, stmt: *const Stmt, depth: usize) std.Io.Writer.Error!void {
    try writer.splatByteAll(' ', depth * 2);
    switch (stmt.*) {
        .var_decl => |d| {
            if (d.array_len) |n| {
                try writer.print("({s}[{d}] {s}", .{ valueTypeName(d.type), n, d.name });
            } else {
                try writer.print("({s} {s}", .{ valueTypeName(d.type), d.name });
            }
            if (d.initializer) |init_expr| {
                try writer.writeAll(" ");
                try printExpr(writer, init_expr);
            }
            try writer.writeAll(")");
        },
        .block => |stmts| {
            try writer.writeAll("(block\n");
            for (stmts) |*s| {
                try printStmt(writer, s, depth + 1);
                try writer.writeAll("\n");
            }
            try writer.splatByteAll(' ', depth * 2);
            try writer.writeAll(")");
        },
        .if_stmt => |i| {
            try writer.writeAll("(if ");
            try printExpr(writer, i.condition);
            try writer.writeAll("\n");
            try printStmt(writer, i.then_branch, depth + 1);
            if (i.else_branch) |eb| {
                try writer.writeAll("\n");
                try printStmt(writer, eb, depth + 1);
            }
            try writer.writeAll(")");
        },
        .while_stmt => |w| {
            try writer.writeAll("(while ");
            try printExpr(writer, w.condition);
            try writer.writeAll("\n");
            try printStmt(writer, w.body, depth + 1);
            try writer.writeAll(")");
        },
        .print_stmt => |e| {
            try writer.writeAll("(print ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .expr_stmt => |e| try printExpr(writer, e),
        .function_decl => |f| {
            const prefix = if (f.exported) "export " else "";
            try writer.print("({s}func {s} (", .{ prefix, f.name });
            for (f.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(" ");
                try writer.writeAll(valueTypeName(p.type));
                if (p.array_size) |spec| try printArraySpecSuffix(writer, spec);
            }
            try writer.print(") {s}", .{valueTypeName(f.return_type)});
            if (f.return_array_size) |spec| try printArraySpecSuffix(writer, spec);
            try writer.writeAll(")\n");
            for (f.body) |*s| {
                try printStmt(writer, s, depth + 1);
                try writer.writeAll("\n");
            }
            try writer.splatByteAll(' ', depth * 2);
            try writer.writeAll(")");
        },
        .return_stmt => |e| {
            try writer.writeAll("(return ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .for_stmt => |f| {
            try writer.print("(for {s} ", .{f.var_name});
            try printExpr(writer, f.start);
            try writer.writeAll(" ");
            try printExpr(writer, f.end);
            try writer.writeAll("\n");
            try printStmt(writer, f.body, depth + 1);
            try writer.writeAll(")");
        },
        .import_stmt => |i| try writer.print("(import \"{s}\")", .{i.path}),
        .close_stmt => |e| {
            try writer.writeAll("(close ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .exit_stmt => |e| {
            try writer.writeAll("(exit ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
    }
}

/// Writes an S-expression rendering of an entire parsed program, one
/// top-level declaration per line.
pub fn printProgram(writer: *std.Io.Writer, program: Program) std.Io.Writer.Error!void {
    for (program) |*stmt| {
        try printStmt(writer, stmt, 0);
        try writer.writeAll("\n");
    }
}

test "printExpr renders a nested expression as an s-expression" {
    var one = Expr{ .literal = .{ .int = 1 } };
    var two = Expr{ .literal = .{ .int = 2 } };
    var sum = Expr{ .binary = .{ .left = &one, .op = .add, .right = &two } };
    var grouped = Expr{ .grouping = &sum };
    var neg = Expr{ .unary = .{ .op = .negate, .right = &grouped } };

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printExpr(&writer, &neg);
    try std.testing.expectEqualStrings("(- (group (+ 1 2)))", writer.buffered());
}

test "printStmt renders an if/else with indented branches" {
    var cond = Expr{ .variable = "x" };
    var one = Expr{ .literal = .{ .int = 1 } };
    var two = Expr{ .literal = .{ .int = 2 } };
    var then_branch = Stmt{ .print_stmt = &one };
    var else_branch = Stmt{ .print_stmt = &two };
    var if_stmt = Stmt{ .if_stmt = .{ .condition = &cond, .then_branch = &then_branch, .else_branch = &else_branch } };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printStmt(&writer, &if_stmt, 0);
    try std.testing.expectEqualStrings("(if x\n  (print 1)\n  (print 2))", writer.buffered());
}
