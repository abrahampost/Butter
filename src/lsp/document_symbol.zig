//! `textDocument/documentSymbol` — flattens (well, nests) symbols.zig's
//! per-file tables into `protocol.DocumentSymbol`s for the outline view: a
//! struct's fields and its own methods (matched by receiver type) nest
//! under it, an enum's variants nest under it, and every plain (non-
//! method) function and `import` appear at the top level.

const std = @import("std");
const symbols = @import("symbols.zig");
const protocol = @import("protocol.zig");
const tk = @import("tokens.zig");

pub fn build(allocator: std.mem.Allocator, file_symbols: symbols.FileSymbols, text: []const u8) ![]const protocol.DocumentSymbol {
    var out: std.ArrayList(protocol.DocumentSymbol) = .empty;

    for (file_symbols.functions) |f| {
        if (f.isMethod()) continue; // attached under its struct below
        try out.append(allocator, functionSymbol(text, f, .function));
    }

    for (file_symbols.structs) |s| {
        var children: std.ArrayList(protocol.DocumentSymbol) = .empty;
        for (s.fields) |fld| {
            try children.append(allocator, .{
                .name = fld.field.name,
                .kind = protocol.SymbolKind.field,
                .range = pointRange(text, fld.pos, fld.field.name.len),
                .selectionRange = pointRange(text, fld.pos, fld.field.name.len),
            });
        }
        for (file_symbols.functions) |f| {
            if (f.isMethod() and std.mem.eql(u8, f.receiver_type.?, s.name)) {
                try children.append(allocator, functionSymbol(text, f, .method));
            }
        }
        try out.append(allocator, .{
            .name = s.name,
            .kind = protocol.SymbolKind.@"struct",
            .range = spanRange(s.line, s.end_line),
            .selectionRange = pointRange(text, s.name_pos, s.name.len),
            .children = try children.toOwnedSlice(allocator),
        });
    }

    for (file_symbols.enums) |e| {
        var children: std.ArrayList(protocol.DocumentSymbol) = .empty;
        for (e.variants) |v| {
            try children.append(allocator, .{
                .name = v.name,
                .kind = protocol.SymbolKind.enum_member,
                .range = pointRange(text, v.pos, v.name.len),
                .selectionRange = pointRange(text, v.pos, v.name.len),
            });
        }
        try out.append(allocator, .{
            .name = e.name,
            .kind = protocol.SymbolKind.@"enum",
            .range = spanRange(e.line, e.end_line),
            .selectionRange = pointRange(text, e.name_pos, e.name.len),
            .children = try children.toOwnedSlice(allocator),
        });
    }

    for (file_symbols.imports) |imp| {
        try out.append(allocator, .{
            .name = imp.path,
            .kind = protocol.SymbolKind.module,
            .range = pointRange(text, imp.path_pos, imp.path.len),
            .selectionRange = pointRange(text, imp.path_pos, imp.path.len),
        });
    }

    return out.toOwnedSlice(allocator);
}

fn functionSymbol(text: []const u8, f: symbols.FunctionSymbol, comptime kind: enum { function, method }) protocol.DocumentSymbol {
    return .{
        .name = f.name,
        .kind = if (kind == .function) protocol.SymbolKind.function else protocol.SymbolKind.method,
        .range = spanRange(f.line, f.end_line),
        .selectionRange = pointRange(text, f.name_pos, f.name.len),
    };
}

// Not position data recovered from a real token — a synthetic bounding
// box (0 and 1 are the same in either encoding) — so this one doesn't
// need `toUtf16`.
fn spanRange(start_line: u32, end_line: u32) protocol.Range {
    const end = if (end_line >= start_line) end_line else start_line;
    return .{ .start = .{ .line = start_line, .character = 0 }, .end = .{ .line = end, .character = 1 } };
}

fn pointRange(text: []const u8, pos: protocol.Position, len: usize) protocol.Range {
    const start = tk.Position.toUtf16(text, pos);
    const end = tk.Position.toUtf16(text, .{ .line = pos.line, .character = pos.character + @as(u32, @intCast(len)) });
    return .{ .start = start, .end = end };
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;
const butter = @import("butter");

fn buildFor(arena: std.mem.Allocator, source: []const u8) ![]const protocol.DocumentSymbol {
    const tokens = try tk.tokenize(arena, source);
    var parser = butter.parser.Parser.init(arena, tokens);
    const program = try parser.parseProgram();
    const file_symbols = try symbols.build(arena, program, tokens);
    return build(arena, file_symbols, source);
}

test "build nests a struct's fields and methods, and lists a plain function at the top level" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const syms = try buildFor(arena_state.allocator(),
        \\struct Point { int x, int y }
        \\func (Point p) sum() -> int {
        \\    return p.x + p.y
        \\}
        \\func helper() -> int {
        \\    return 0
        \\}
        \\
    );

    var found_struct = false;
    var found_helper = false;
    for (syms) |sym| {
        if (std.mem.eql(u8, sym.name, "Point")) {
            found_struct = true;
            try testing.expectEqual(protocol.SymbolKind.@"struct", sym.kind);
            try testing.expectEqual(@as(usize, 3), sym.children.?.len); // 2 fields + 1 method
        }
        if (std.mem.eql(u8, sym.name, "helper")) {
            found_helper = true;
            try testing.expectEqual(protocol.SymbolKind.function, sym.kind);
        }
        // A method must never ALSO appear at the top level.
        try testing.expect(!std.mem.eql(u8, sym.name, "sum"));
    }
    try testing.expect(found_struct);
    try testing.expect(found_helper);
}

test "build nests an enum's variants" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const syms = try buildFor(arena_state.allocator(), "enum Color { Red, Green, Blue }\n");

    try testing.expectEqual(@as(usize, 1), syms.len);
    try testing.expectEqual(protocol.SymbolKind.@"enum", syms[0].kind);
    try testing.expectEqual(@as(usize, 3), syms[0].children.?.len);
    try testing.expectEqual(protocol.SymbolKind.enum_member, syms[0].children.?[0].kind);
}
