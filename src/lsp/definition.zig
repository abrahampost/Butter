//! `textDocument/definition` — same resolution as hover.zig (resolve.zig),
//! but returns the target's own Location instead of rendered text.

const std = @import("std");
const workspace = @import("workspace.zig");
const protocol = @import("protocol.zig");
const resolve = @import("resolve.zig");
const uri_mod = @import("uri.zig");
const tk = @import("tokens.zig");

pub fn definition(allocator: std.mem.Allocator, analysis: *const workspace.Analysis, mod_analysis: workspace.ModuleAnalysis, pos: protocol.Position) !?protocol.Location {
    const r = resolve.resolveAt(allocator, analysis, mod_analysis, pos) orelse return null;
    const target_uri = try uri_mod.uriFromPath(allocator, r.module.mod.path);

    // An `import "..."` itself has no "declared name" inside the target
    // file to point at — going to its definition means jumping into that
    // file at all, so the start of it is the natural landing spot, not
    // wherever `targetPosition` would report (the import STATEMENT's own
    // position in the CURRENT file).
    if (r.target == .import) {
        return .{ .uri = target_uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } };
    }

    // A builtin keyword-form op (`ord`, `len`, ...) has no declaration site
    // in Butter source at all — see builtins.zig — so there's nowhere for
    // "go to definition" to jump.
    if (r.target == .builtin) return null;

    const p = resolve.targetPosition(r.target);
    const len: u32 = @intCast(resolve.targetNameLen(r.target));
    const start = tk.Position.toUtf16(r.module.text, p);
    const end = tk.Position.toUtf16(r.module.text, .{ .line = p.line, .character = p.character + len });
    return .{ .uri = target_uri, .range = .{ .start = start, .end = end } };
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

test "definition finds a same-file function's declaration site" {
    const gpa = testing.allocator;
    var a = try analyzeOk(gpa, "func add(int a, int b) -> int {\n    return a + b\n}\nprint add(1, 2)\n");
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // "add" on line 3 (0-based), right after "print ".
    const loc = (try definition(arena_state.allocator(), &a, mod, .{ .line = 3, .character = 7 })).?;
    try testing.expectEqual(@as(u32, 0), loc.range.start.line);
    try testing.expectEqual(@as(u32, 5), loc.range.start.character);
}

test "definition jumps into an imported stdlib module" {
    const gpa = testing.allocator;
    var a = try analyzeOk(gpa, "import \"math.std.butter\"\nprint abs(-1)\n");
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // "abs" on line 1 (0-based), right after "print ".
    const loc = (try definition(arena_state.allocator(), &a, mod, .{ .line = 1, .character = 7 })).?;
    try testing.expect(std.mem.endsWith(u8, loc.uri, "math.std.butter"));
}

test "definition on an import statement jumps to the start of that file" {
    const gpa = testing.allocator;
    var a = try analyzeOk(gpa, "import \"math.std.butter\"\nprint abs(-1)\n");
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const loc = (try definition(arena_state.allocator(), &a, mod, .{ .line = 0, .character = 10 })).?;
    try testing.expect(std.mem.endsWith(u8, loc.uri, "math.std.butter"));
    try testing.expectEqual(@as(u32, 0), loc.range.start.line);
    try testing.expectEqual(@as(u32, 0), loc.range.start.character);
}

test "definition returns null for a builtin keyword-form op like ord" {
    const gpa = testing.allocator;
    var a = try analyzeOk(gpa, "print ord(\"x\")\n");
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // "ord" on line 0, right after "print ".
    const loc = try definition(arena_state.allocator(), &a, mod, .{ .line = 0, .character = 7 });
    try testing.expect(loc == null);
}

test "definition returns null when nothing resolves" {
    const gpa = testing.allocator;
    var a = try analyzeOk(gpa, "print 1\n");
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const loc = try definition(arena_state.allocator(), &a, mod, .{ .line = 0, .character = 0 });
    try testing.expect(loc == null);
}
