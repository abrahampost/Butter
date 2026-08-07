//! `textDocument/hover` — renders a resolved symbol's DECLARED signature/
//! type as Markdown (see resolve.zig for how it's found). Not full
//! expression-level type inference (e.g. hovering `a + b` to see the
//! result type) — that needs the compiler's `inferType`, which has no
//! standalone entry point today; see the top-level design plan.

const std = @import("std");
const butter = @import("butter");
const ast = butter.ast;
const symbols = @import("symbols.zig");
const workspace = @import("workspace.zig");
const protocol = @import("protocol.zig");
const resolve = @import("resolve.zig");
const tk = @import("tokens.zig");

pub fn hover(allocator: std.mem.Allocator, analysis: *const workspace.Analysis, mod_analysis: workspace.ModuleAnalysis, pos: protocol.Position) !?protocol.Hover {
    const r = resolve.resolveAt(allocator, analysis, mod_analysis, pos) orelse return null;
    const text = try render(allocator, r);
    const p = resolve.targetPosition(r.target);
    const len: u32 = @intCast(resolve.targetNameLen(r.target));
    const start = tk.Position.toUtf16(r.module.text, p);
    const end = tk.Position.toUtf16(r.module.text, .{ .line = p.line, .character = p.character + len });
    return .{
        .contents = .{ .value = text },
        .range = .{ .start = start, .end = end },
    };
}

fn render(allocator: std.mem.Allocator, r: resolve.Resolved) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    switch (r.target) {
        .local => |l| {
            const t = try typeText(allocator, l.type, l.named_type, l.func_sig, l.array_size);
            const prefix: []const u8 = if (l.is_receiver) "(receiver) " else if (l.is_param) "(param) " else "(local) ";
            try w.print("```butter\n{s}{s} {s}\n```", .{ prefix, t, l.name });
        },
        .function => |f| try renderFunctionSig(w, allocator, f, false),
        .method => |m| try renderFunctionSig(w, allocator, m, true),
        .@"struct" => |s| try renderStruct(w, allocator, s),
        .@"enum" => |e| try renderEnum(w, e),
        .field => |fr| {
            const t = try typeText(allocator, fr.field.field.type, fr.field.field.named_type, null, null);
            try w.print("```butter\n{s} {s}.{s}\n```", .{ t, fr.owner.name, fr.field.field.name });
        },
        .variant => |vr| try w.print("```butter\n{s}.{s}\n```", .{ vr.owner.name, vr.variant.name }),
        .import => |i| try w.print("```butter\nimport \"{s}\"\n```", .{i.path}),
    }
    return out.toOwnedSlice();
}

fn renderFunctionSig(w: *std.Io.Writer, allocator: std.mem.Allocator, f: symbols.FunctionSymbol, is_method: bool) !void {
    try w.writeAll("```butter\n");
    if (f.exported) try w.writeAll("export ");
    if (is_method) {
        try w.print("func ({s} {s}) {s}(", .{ f.receiver_type.?, f.receiver_name.?, f.name });
    } else {
        try w.print("func {s}(", .{f.name});
    }
    for (f.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        const t = try typeText(allocator, p.param.type, p.param.named_type, p.param.func_sig, p.param.array_size);
        try w.print("{s} {s}", .{ t, p.param.name });
    }
    const ret_t = try typeText(allocator, f.return_type, f.return_named_type, null, f.return_array_size);
    try w.print(") -> {s}\n```", .{ret_t});
}

fn renderStruct(w: *std.Io.Writer, allocator: std.mem.Allocator, s: symbols.StructSymbol) !void {
    try w.writeAll("```butter\n");
    if (s.exported) try w.writeAll("export ");
    try w.print("struct {s} {{\n", .{s.name});
    for (s.fields) |f| {
        const t = try typeText(allocator, f.field.type, f.field.named_type, null, null);
        try w.print("    {s} {s}\n", .{ t, f.field.name });
    }
    try w.writeAll("}\n```");
}

fn renderEnum(w: *std.Io.Writer, e: symbols.EnumSymbol) !void {
    try w.writeAll("```butter\n");
    if (e.exported) try w.writeAll("export ");
    try w.print("enum {s} {{ ", .{e.name});
    for (e.variants, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(v.name);
    }
    try w.writeAll(" }\n```");
}

/// Renders a declared type (a `Param`/`FieldDecl`/`VarDecl`/return type's
/// worth of information) back into Butter-like source text for display —
/// e.g. `int[5]`, `Point`, `func(int,int)bool`.
fn typeText(allocator: std.mem.Allocator, t: ast.ValueType, named_type: ?[]const u8, func_sig: ?*const ast.FuncSig, array_size: ?ast.ArraySpec) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try writeType(w, t, named_type, func_sig);
    if (array_size) |spec| {
        switch (spec) {
            .fixed => |n| try w.print("[{d}]", .{n}),
            .generic => try w.writeAll("[]"),
        }
    }
    return out.toOwnedSlice();
}

fn writeType(w: *std.Io.Writer, t: ast.ValueType, named_type: ?[]const u8, func_sig: ?*const ast.FuncSig) !void {
    switch (t) {
        .int => try w.writeAll("int"),
        .float => try w.writeAll("float"),
        .bool => try w.writeAll("bool"),
        .string => try w.writeAll("string"),
        .map => try w.writeAll("map"),
        .list => try w.writeAll("list"),
        .named => try w.writeAll(named_type orelse "?"),
        .func => {
            try w.writeAll("func(");
            if (func_sig) |sig| {
                for (sig.param_types, 0..) |pt, i| {
                    if (i > 0) try w.writeAll(",");
                    try writeType(w, pt, null, null);
                }
                try w.print(") {s}", .{@tagName(sig.return_type)});
            } else {
                try w.writeAll(")");
            }
        },
    }
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;

fn analyzeOk(gpa: std.mem.Allocator, source: []const u8) !workspace.Analysis {
    const result = try workspace.analyze(gpa, testing.io, source, "<test>", ".");
    return switch (result) {
        .ok => |a| a,
        .fail => error.TestUnexpectedResult,
    };
}

test "hover renders a function's signature" {
    const gpa = testing.allocator;
    var a = try analyzeOk(gpa, "func add(int a, int b) -> int {\n    return a + b\n}\nprint add(1, 2)\n");
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const h = (try hover(arena_state.allocator(), &a, mod, .{ .line = 3, .character = 7 })).?;
    try testing.expect(std.mem.indexOf(u8, h.contents.value, "func add(int a, int b) -> int") != null);
}

test "hover renders a struct field's declared type" {
    const gpa = testing.allocator;
    var a = try analyzeOk(gpa,
        \\struct Point { int x, int y }
        \\func sumX(Point p) -> int {
        \\    return p.x
        \\}
        \\
    );
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // "    return p.x" — 'x' is at 0-based character 13 on line 2.
    const h = (try hover(arena_state.allocator(), &a, mod, .{ .line = 2, .character = 13 })).?;
    try testing.expect(std.mem.indexOf(u8, h.contents.value, "int Point.x") != null);
}

test "hover returns null when nothing resolves" {
    const gpa = testing.allocator;
    var a = try analyzeOk(gpa, "print 1\n");
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const h = try hover(arena_state.allocator(), &a, mod, .{ .line = 0, .character = 0 });
    try testing.expect(h == null);
}
