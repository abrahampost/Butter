//! AST node definitions for Butter, matching section 2 (SYNTAX GRAMMAR) of
//! GRAMMAR.bnf. Nodes are produced by `parser.Parser` into memory owned by
//! its arena; they borrow string data (identifiers, string contents)
//! directly from the source text.

const std = @import("std");

pub const ValueType = enum {
    int,
    float,
    bool,
    string,
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
};

pub const Param = struct {
    type: ValueType,
    name: []const u8,
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

    /// `arr[index]` — only ever a bare IDENTIFIER followed by '[', no
    /// chained/nested indexing (Butter has no arrays-of-arrays).
    pub const Index = struct {
        name: []const u8,
        index: *Expr,
    };

    pub const IndexAssign = struct {
        name: []const u8,
        index: *Expr,
        value: *Expr,
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
            try writer.print("(index {s} ", .{i.name});
            try printExpr(writer, i.index);
            try writer.writeAll(")");
        },
        .index_assign => |ia| {
            try writer.print("(:= (index {s} ", .{ia.name});
            try printExpr(writer, ia.index);
            try writer.writeAll(") ");
            try printExpr(writer, ia.value);
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

fn valueTypeName(t: ValueType) []const u8 {
    return switch (t) {
        .int => "int",
        .float => "float",
        .bool => "bool",
        .string => "string",
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
            try writer.print("({s}func {s} ({s})\n", .{ prefix, f.name, valueTypeName(f.return_type) });
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
