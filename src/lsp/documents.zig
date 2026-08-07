//! The stateful open-document store: tracks every file the editor has
//! open, its current buffer text, and its analysis — re-running
//! workspace.zig's `analyze` on every change. Butter's parser has no
//! error recovery (it's fail-fast — see GRAMMAR.bnf/parser.zig), so a
//! buffer with a syntax error mid-edit would otherwise blank out every
//! symbol-based feature; this store keeps the LAST SUCCESSFUL analysis
//! around (`Document.good`) for hover/definition/completion/document-
//! symbols to keep using, while `Document.diagnostics()` always reflects
//! the CURRENT (possibly broken) buffer.

const std = @import("std");
const workspace = @import("workspace.zig");
const uri_mod = @import("uri.zig");

pub const Document = struct {
    /// The URI the editor names this document by — the map key this
    /// struct lives under (`DocumentStore.docs`), duplicated here too
    /// since a caller iterating documents needs it without a second
    /// lookup.
    uri: []const u8,
    /// Canonical filesystem path (see uri.zig) and its directory — the
    /// `key`/`dir` `workspace.analyze` resolves this document's own
    /// `import`s against, mirroring `main.zig`'s entry-file handling.
    path: []const u8,
    dir: []const u8,
    text: []const u8,
    version: i64,
    /// The most recent analysis that actually produced a module graph
    /// (loading succeeded, whether or not it went on to compile
    /// cleanly) — kept even after a LATER edit fails to load, so symbol
    /// features keep working against the last-known-good tree.
    good: ?workspace.Analysis = null,
    /// Set only when the MOST RECENT `workspace.analyze` call couldn't
    /// even produce a module graph (a lex/parse error, or a module-
    /// resolution problem) — `null` whenever the latest attempt at least
    /// loaded, even if it then failed to compile (that failure lives in
    /// `good.?.diagnostic` instead).
    latest_failure: ?workspace.LoadFailure = null,

    fn deinit(self: *Document, gpa: std.mem.Allocator) void {
        gpa.free(self.uri);
        gpa.free(self.path);
        gpa.free(self.dir);
        gpa.free(self.text);
        if (self.good) |*g| g.deinit();
        if (self.latest_failure) |f| f.deinit(gpa);
    }

    /// The single diagnostic this document's latest analysis produced
    /// (a load failure, a compile failure, or neither), and which file
    /// path it belongs to — never the entry document's own path when the
    /// problem is actually inside an imported file (`Diagnostic.path`/
    /// `LoadFailure.path` already name whichever file is really at
    /// fault). `null` when the latest analysis is clean.
    pub const DiagnosticInfo = struct {
        path: []const u8,
        line: ?usize,
        column: ?usize,
        name: []const u8,
        message: []const u8,
    };

    pub fn currentDiagnostic(self: *const Document) ?DiagnosticInfo {
        if (self.latest_failure) |f| {
            return .{ .path = f.path, .line = f.line, .column = null, .name = "", .message = f.message };
        }
        if (self.good) |g| {
            if (g.diagnostic) |d| {
                return .{ .path = d.path, .line = d.line, .column = d.column, .name = d.name, .message = d.message };
            }
        }
        return null;
    }
};

pub const DocumentStore = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    docs: std.StringHashMap(*Document),

    pub fn init(gpa: std.mem.Allocator, io: std.Io) DocumentStore {
        return .{ .gpa = gpa, .io = io, .docs = .init(gpa) };
    }

    pub fn deinit(self: *DocumentStore) void {
        var it = self.docs.valueIterator();
        while (it.next()) |doc| {
            doc.*.deinit(self.gpa);
            self.gpa.destroy(doc.*);
        }
        self.docs.deinit();
    }

    pub fn get(self: *const DocumentStore, uri: []const u8) ?*Document {
        return self.docs.get(uri);
    }

    /// Every currently-open document, for re-publishing diagnostics
    /// across all of them after any one changes (an edit to a shared
    /// import can change what a DIFFERENT open file's own diagnostics
    /// should be).
    pub fn iterator(self: *const DocumentStore) std.StringHashMap(*Document).ValueIterator {
        return self.docs.valueIterator();
    }

    /// Opens (or replaces, if somehow already open) `uri` with `text` and
    /// runs its first analysis.
    pub fn open(self: *DocumentStore, uri: []const u8, text: []const u8, version: i64) !void {
        if (self.docs.fetchRemove(uri)) |kv| {
            kv.value.deinit(self.gpa);
            self.gpa.destroy(kv.value);
        }

        const doc = try self.gpa.create(Document);
        errdefer self.gpa.destroy(doc);
        const uri_copy = try self.gpa.dupe(u8, uri);
        errdefer self.gpa.free(uri_copy);
        const path = try pathOf(self.gpa, uri);
        errdefer self.gpa.free(path);
        const dir = try dirOf(self.gpa, path);
        errdefer self.gpa.free(dir);
        const text_copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(text_copy);

        doc.* = .{ .uri = uri_copy, .path = path, .dir = dir, .text = text_copy, .version = version };
        try self.docs.put(doc.uri, doc);
        try self.reanalyze(doc);
    }

    /// Replaces `uri`'s text (full-document sync — see
    /// `protocol.TextDocumentContentChangeEvent`'s doc comment) and
    /// re-analyzes it.
    pub fn change(self: *DocumentStore, uri: []const u8, text: []const u8, version: i64) !void {
        const doc = self.docs.get(uri) orelse return;
        const text_copy = try self.gpa.dupe(u8, text);
        self.gpa.free(doc.text);
        doc.text = text_copy;
        doc.version = version;
        try self.reanalyze(doc);
    }

    /// Re-runs analysis for every open document against its current
    /// buffer text, unchanged — used on `textDocument/didSave`: saving
    /// ANY file can change what a DIFFERENT open document's own
    /// diagnostics/symbols should be, since imports are read from disk
    /// (workspace.zig's `rereadSource`), not from other open buffers.
    pub fn reanalyzeAll(self: *DocumentStore) !void {
        var it = self.docs.valueIterator();
        while (it.next()) |doc| {
            try self.reanalyze(doc.*);
        }
    }

    pub fn close(self: *DocumentStore, uri: []const u8) void {
        if (self.docs.fetchRemove(uri)) |kv| {
            kv.value.deinit(self.gpa);
            self.gpa.destroy(kv.value);
        }
    }

    fn reanalyze(self: *DocumentStore, doc: *Document) !void {
        const result = try workspace.analyze(self.gpa, self.io, doc.text, doc.path, doc.dir);
        switch (result) {
            .ok => |a| {
                if (doc.good) |*old| old.deinit();
                doc.good = a;
                if (doc.latest_failure) |f| f.deinit(self.gpa);
                doc.latest_failure = null;
            },
            .fail => |f| {
                if (doc.latest_failure) |old| old.deinit(self.gpa);
                doc.latest_failure = f;
                // `doc.good` (if any) is deliberately left in place — see
                // this file's own doc comment.
            },
        }
    }
};

fn pathOf(gpa: std.mem.Allocator, uri: []const u8) ![]const u8 {
    return (try uri_mod.pathFromUri(gpa, uri)) orelse try gpa.dupe(u8, uri);
}

fn dirOf(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    const dirname = std.fs.path.dirname(path) orelse ".";
    return gpa.dupe(u8, dirname);
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;

test "open then get round-trips a document's text" {
    var store = DocumentStore.init(testing.allocator, testing.io);
    defer store.deinit();

    try store.open("file:///C:/proj/main.butter", "print 1\n", 1);
    const doc = store.get("file:///C:/proj/main.butter").?;
    try testing.expectEqualStrings("print 1\n", doc.text);
    try testing.expect(doc.good != null);
    try testing.expect(doc.currentDiagnostic() == null);
}

test "change replaces the text and re-analyzes" {
    var store = DocumentStore.init(testing.allocator, testing.io);
    defer store.deinit();

    try store.open("file:///C:/proj/main.butter", "print 1\n", 1);
    try store.change("file:///C:/proj/main.butter", "print undefinedThing\n", 2);

    const doc = store.get("file:///C:/proj/main.butter").?;
    const diag = doc.currentDiagnostic();
    try testing.expect(diag != null);
}

test "a syntax error keeps the previous good analysis but reports the new failure" {
    var store = DocumentStore.init(testing.allocator, testing.io);
    defer store.deinit();

    try store.open("file:///C:/proj/main.butter", "func f() -> int {\n    return 1\n}\n", 1);
    const doc = store.get("file:///C:/proj/main.butter").?;
    try testing.expect(doc.good.?.findModule(doc.path) != null);

    try store.change("file:///C:/proj/main.butter", "func f() -> int {\n    return 1 @\n}\n", 2);
    try testing.expect(doc.good != null); // stale-but-valid tree retained
    try testing.expect(doc.good.?.findModule(doc.path) != null);
    const diag = doc.currentDiagnostic();
    try testing.expect(diag != null);
    try testing.expectEqual(@as(?usize, 2), diag.?.line);
}

test "close removes the document" {
    var store = DocumentStore.init(testing.allocator, testing.io);
    defer store.deinit();

    try store.open("file:///C:/proj/main.butter", "print 1\n", 1);
    store.close("file:///C:/proj/main.butter");
    try testing.expect(store.get("file:///C:/proj/main.butter") == null);
}
