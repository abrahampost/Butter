//! Turns every open document's latest analysis (documents.zig) into LSP
//! `Diagnostic`s ready for `textDocument/publishDiagnostics`, one entry
//! per distinct FILE (not per open document — see `collect`'s doc
//! comment). A compiler diagnostic only ever carries a line
//! (`compiler.Diagnostic` has no column — see `workspace.Diag`'s doc
//! comment); its column is recovered here by searching that file's own
//! token cache (already built by workspace.zig) for a token matching the
//! diagnostic's `name` on that line. A load failure (lex/parse error) has
//! no token cache to search at all (loading itself is what failed), so it
//! falls back to column 1 — a full-line squiggle rather than a precise
//! one, an accepted simplification for this rarer case.

const std = @import("std");
const documents = @import("documents.zig");
const protocol = @import("protocol.zig");
const tk = @import("tokens.zig");

pub const FileDiagnostics = struct {
    /// A plain filesystem path (see uri.zig for the `file://` URI it
    /// becomes when published).
    path: []const u8,
    diagnostics: []const protocol.Diagnostic,
};

/// The full set of diagnostics every currently-open document's latest
/// analysis produced, one entry per distinct file path that has a
/// problem right now — deliberately not one entry per open document: two
/// open files importing the same broken dependency both surface a
/// diagnostic on THAT shared file's path, merged into a single entry here
/// (last one wins; they're reporting the same underlying problem).
///
/// Caller-owned: free the returned slice and each entry's `diagnostics`
/// slice with `allocator`. Every string inside (`path`, `message`, ...)
/// is borrowed from the `DocumentStore`'s own documents, not copied — do
/// not use the result past the next mutation of `store`.
pub fn collect(allocator: std.mem.Allocator, store: *const documents.DocumentStore) ![]const FileDiagnostics {
    var by_path: std.StringHashMap(protocol.Diagnostic) = .init(allocator);
    defer by_path.deinit();

    var it = store.iterator();
    while (it.next()) |doc_ptr| {
        const doc: *const documents.Document = doc_ptr.*;
        const info = doc.currentDiagnostic() orelse continue;
        try by_path.put(info.path, .{
            .range = rangeFor(doc, info),
            .severity = protocol.DiagnosticSeverity.err,
            .message = info.message,
        });
    }

    var out: std.ArrayList(FileDiagnostics) = .empty;
    var vit = by_path.iterator();
    while (vit.next()) |entry| {
        const one = try allocator.alloc(protocol.Diagnostic, 1);
        one[0] = entry.value_ptr.*;
        try out.append(allocator, .{ .path = entry.key_ptr.*, .diagnostics = one });
    }
    return out.toOwnedSlice(allocator);
}

fn rangeFor(doc: *const documents.Document, info: documents.Document.DiagnosticInfo) protocol.Range {
    const line = info.line orelse 1;
    const zero_line: u32 = @intCast(line -| 1);
    var column: usize = 1;
    var width: usize = 1;
    // The problem may be in an IMPORTED file, not `doc` itself (see this
    // file's own doc comment) — default to `doc.text` (right whenever
    // `info.path == doc.path`, the common case) and swap in the actual
    // target module's own text below once/if we find it.
    var text: []const u8 = doc.text;

    if (info.name.len > 0) {
        if (doc.good) |good| {
            if (good.findModule(info.path)) |mod_analysis| {
                if (findColumnByName(mod_analysis.tokens, line, info.name)) |found| {
                    column = found.column;
                    width = found.lexeme.len;
                    text = mod_analysis.text;
                }
            }
        }
    }

    const byte_start = protocol.Position{ .line = zero_line, .character = @intCast(column -| 1) };
    const byte_end = protocol.Position{ .line = zero_line, .character = @intCast(column -| 1 + width) };
    return .{ .start = tk.Position.toUtf16(text, byte_start), .end = tk.Position.toUtf16(text, byte_end) };
}

fn findColumnByName(tokens: []const tk.Token, line: usize, name: []const u8) ?tk.Token {
    for (tokens) |t| {
        if (t.line == line and std.mem.eql(u8, t.lexeme, name)) return t;
        if (t.line > line) break;
    }
    return null;
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;

test "collect surfaces a syntax error with a full-line fallback range" {
    var store = documents.DocumentStore.init(testing.allocator, testing.io);
    defer store.deinit();
    try store.open("file:///main.butter", "int x @ 1\n", 1);

    const result = try collect(testing.allocator, &store);
    defer {
        for (result) |fd| testing.allocator.free(fd.diagnostics);
        testing.allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(usize, 1), result[0].diagnostics.len);
    try testing.expectEqual(@as(u32, 0), result[0].diagnostics[0].range.start.line);
}

test "collect recovers a semantic error's exact column from the token cache" {
    var store = documents.DocumentStore.init(testing.allocator, testing.io);
    defer store.deinit();
    try store.open("file:///main.butter", "print undefinedThing\n", 1);

    const result = try collect(testing.allocator, &store);
    defer {
        for (result) |fd| testing.allocator.free(fd.diagnostics);
        testing.allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 1), result.len);
    const range = result[0].diagnostics[0].range;
    // "undefinedThing" starts at 0-based column 6 on line 0.
    try testing.expectEqual(@as(u32, 6), range.start.character);
    try testing.expectEqual(@as(u32, 6 + "undefinedThing".len), range.end.character);
}

test "collect clears once the document is fixed" {
    var store = documents.DocumentStore.init(testing.allocator, testing.io);
    defer store.deinit();
    try store.open("file:///main.butter", "print undefinedThing\n", 1);

    {
        const result = try collect(testing.allocator, &store);
        defer {
            for (result) |fd| testing.allocator.free(fd.diagnostics);
            testing.allocator.free(result);
        }
        try testing.expectEqual(@as(usize, 1), result.len);
    }

    try store.change("file:///main.butter", "print 1\n", 2);
    const result = try collect(testing.allocator, &store);
    defer {
        for (result) |fd| testing.allocator.free(fd.diagnostics);
        testing.allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 0), result.len);
}
