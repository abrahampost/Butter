//! Request dispatch and lifecycle for `butter-lsp`: reads Content-Length-
//! framed JSON-RPC messages from stdin (rpc.zig) in a loop, maintains the
//! open-document store (documents.zig), and answers each request/
//! notification by delegating to diagnostics.zig/hover.zig/definition.zig/
//! document_symbol.zig/completion.zig.

const std = @import("std");
const rpc = @import("rpc.zig");
const protocol = @import("protocol.zig");
const documents = @import("documents.zig");
const workspace = @import("workspace.zig");
const diagnostics = @import("diagnostics.zig");
const hover_mod = @import("hover.zig");
const definition_mod = @import("definition.zig");
const document_symbol_mod = @import("document_symbol.zig");
const completion_mod = @import("completion.zig");
const uri_mod = @import("uri.zig");

/// Runs the server until `exit` is received or stdin closes. Every
/// request/notification is handled inside its own throwaway arena, freed
/// at the end of that one message — nothing about a single message's
/// handling is meant to outlive it, including whatever `hover`/
/// `definition`/`completion` allocate while answering it.
pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);

    var store = documents.DocumentStore.init(gpa, io);
    defer store.deinit();

    // Paths (gpa-owned, outliving any one request's arena) currently
    // shown to the client as having a non-empty diagnostics list — see
    // `publishAll`'s doc comment for why this needs to persist across
    // messages.
    var published: std.StringHashMap(void) = .init(gpa);
    defer {
        var it = published.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        published.deinit();
    }

    var running = true;
    while (running) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const body = rpc.readMessage(arena, &stdin_reader.interface) catch |err| {
            stderr_writer.interface.print("butter-lsp: transport error: {t}\n", .{err}) catch {};
            stderr_writer.interface.flush() catch {};
            return;
        } orelse return; // clean EOF: the client closed stdin.

        handleMessage(gpa, arena, &store, &published, &stdout_writer.interface, body, &running) catch |err| {
            stderr_writer.interface.print("butter-lsp: error handling message: {t}\n", .{err}) catch {};
            stderr_writer.interface.flush() catch {};
        };
    }
}

fn handleMessage(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    store: *documents.DocumentStore,
    published: *std.StringHashMap(void),
    writer: *std.Io.Writer,
    body: []const u8,
    running: *bool,
) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return;
    const obj = switch (root) {
        .object => |o| o,
        else => return,
    };
    const method = switch (obj.get("method") orelse return) {
        .string => |s| s,
        else => return,
    };
    const id: ?std.json.Value = obj.get("id");
    const params_value: std.json.Value = obj.get("params") orelse .null;

    if (std.mem.eql(u8, method, "initialize")) {
        if (id) |the_id| try rpc.send(arena, writer, .response, .{ .id = the_id, .result = protocol.InitializeResult{} });
    } else if (std.mem.eql(u8, method, "initialized")) {
        // Nothing to do — no client capability this server relies on
        // needs a follow-up here.
    } else if (std.mem.eql(u8, method, "shutdown")) {
        if (id) |the_id| try rpc.send(arena, writer, .response, .{ .id = the_id, .result = @as(?u8, null) });
    } else if (std.mem.eql(u8, method, "exit")) {
        running.* = false;
    } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        if (parseParams(protocol.DidOpenTextDocumentParams, arena, params_value)) |p| {
            try store.open(p.textDocument.uri, p.textDocument.text, p.textDocument.version);
            try publishAll(arena, gpa, store, published, writer);
        }
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        if (parseParams(protocol.DidChangeTextDocumentParams, arena, params_value)) |p| {
            if (p.contentChanges.len > 0) {
                try store.change(p.textDocument.uri, p.contentChanges[p.contentChanges.len - 1].text, p.textDocument.version);
                try publishAll(arena, gpa, store, published, writer);
            }
        }
    } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
        if (parseParams(protocol.DidCloseTextDocumentParams, arena, params_value)) |p| {
            store.close(p.textDocument.uri);
            try publishAll(arena, gpa, store, published, writer);
        }
    } else if (std.mem.eql(u8, method, "textDocument/didSave")) {
        // A save changes what ON-DISK imports resolve to for every OTHER
        // open document too (workspace.zig reads imports from disk, not
        // from other open buffers) — re-check all of them, not just the
        // saved one.
        try store.reanalyzeAll();
        try publishAll(arena, gpa, store, published, writer);
    } else if (std.mem.eql(u8, method, "textDocument/hover")) {
        try handleHover(arena, store, id, params_value, writer);
    } else if (std.mem.eql(u8, method, "textDocument/definition")) {
        try handleDefinition(arena, store, id, params_value, writer);
    } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        try handleDocumentSymbol(arena, store, id, params_value, writer);
    } else if (std.mem.eql(u8, method, "textDocument/completion")) {
        try handleCompletion(arena, store, id, params_value, writer);
    } else if (id) |the_id| {
        // An unrecognized REQUEST must still get a response (never leave
        // the client hanging on a pending id) — an unrecognized
        // NOTIFICATION (no id) is simply ignored, per the spec.
        try rpc.send(arena, writer, .err, .{ .id = the_id, .code = @as(i32, -32601), .message = "method not found" });
    }
}

fn parseParams(comptime T: type, arena: std.mem.Allocator, params_value: std.json.Value) ?T {
    return std.json.parseFromValueLeaky(T, arena, params_value, .{ .ignore_unknown_fields = true }) catch null;
}

const Looked = struct {
    doc: *documents.Document,
    analysis: *const workspace.Analysis,
    mod: workspace.ModuleAnalysis,
};

fn lookupModule(store: *const documents.DocumentStore, uri: []const u8) ?Looked {
    const doc = store.get(uri) orelse return null;
    const analysis: *const workspace.Analysis = if (doc.good) |*a| a else return null;
    const mod = analysis.findModule(doc.path) orelse return null;
    return .{ .doc = doc, .analysis = analysis, .mod = mod };
}

fn handleHover(arena: std.mem.Allocator, store: *const documents.DocumentStore, id: ?std.json.Value, params_value: std.json.Value, writer: *std.Io.Writer) !void {
    const the_id = id orelse return;
    var result: ?protocol.Hover = null;
    if (parseParams(protocol.HoverParams, arena, params_value)) |p| {
        if (lookupModule(store, p.textDocument.uri)) |looked| {
            result = try hover_mod.hover(arena, looked.analysis, looked.mod, p.position);
        }
    }
    try rpc.send(arena, writer, .response, .{ .id = the_id, .result = result });
}

fn handleDefinition(arena: std.mem.Allocator, store: *const documents.DocumentStore, id: ?std.json.Value, params_value: std.json.Value, writer: *std.Io.Writer) !void {
    const the_id = id orelse return;
    var result: ?protocol.Location = null;
    if (parseParams(protocol.DefinitionParams, arena, params_value)) |p| {
        if (lookupModule(store, p.textDocument.uri)) |looked| {
            result = try definition_mod.definition(arena, looked.analysis, looked.mod, p.position);
        }
    }
    try rpc.send(arena, writer, .response, .{ .id = the_id, .result = result });
}

fn handleDocumentSymbol(arena: std.mem.Allocator, store: *const documents.DocumentStore, id: ?std.json.Value, params_value: std.json.Value, writer: *std.Io.Writer) !void {
    const the_id = id orelse return;
    var result: []const protocol.DocumentSymbol = &.{};
    if (parseParams(protocol.DocumentSymbolParams, arena, params_value)) |p| {
        if (lookupModule(store, p.textDocument.uri)) |looked| {
            result = try document_symbol_mod.build(arena, looked.mod.symbols, looked.mod.text);
        }
    }
    try rpc.send(arena, writer, .response, .{ .id = the_id, .result = result });
}

fn handleCompletion(arena: std.mem.Allocator, store: *const documents.DocumentStore, id: ?std.json.Value, params_value: std.json.Value, writer: *std.Io.Writer) !void {
    const the_id = id orelse return;
    var result: []const protocol.CompletionItem = &.{};
    if (parseParams(protocol.CompletionParams, arena, params_value)) |p| {
        if (lookupModule(store, p.textDocument.uri)) |looked| {
            result = try completion_mod.complete(arena, looked.analysis, looked.mod, looked.doc.text, p.position);
        }
    }
    try rpc.send(arena, writer, .response, .{ .id = the_id, .result = result });
}

/// Publishes `textDocument/publishDiagnostics` for every file with a
/// current problem, and CLEARS (publishes an empty list for) every file
/// that had one before but no longer does — `published` is the server's
/// only memory of what it last told the client, since the client itself
/// never reports this back.
fn publishAll(arena: std.mem.Allocator, gpa: std.mem.Allocator, store: *const documents.DocumentStore, published: *std.StringHashMap(void), writer: *std.Io.Writer) !void {
    const results = try diagnostics.collect(arena, store);

    var seen: std.StringHashMap(void) = .init(arena);
    for (results) |fd| {
        try seen.put(fd.path, {});
        const target_uri = try uri_mod.uriFromPath(arena, fd.path);
        try rpc.send(arena, writer, .notification, .{
            .method = "textDocument/publishDiagnostics",
            .params = protocol.PublishDiagnosticsParams{ .uri = target_uri, .diagnostics = fd.diagnostics },
        });
    }

    var stale: std.ArrayList([]const u8) = .empty;
    var pit = published.keyIterator();
    while (pit.next()) |k| {
        if (!seen.contains(k.*)) try stale.append(arena, k.*);
    }
    for (stale.items) |path| {
        const target_uri = try uri_mod.uriFromPath(arena, path);
        try rpc.send(arena, writer, .notification, .{
            .method = "textDocument/publishDiagnostics",
            .params = protocol.PublishDiagnosticsParams{ .uri = target_uri, .diagnostics = &.{} },
        });
        _ = published.remove(path);
        gpa.free(path);
    }

    var sit = seen.keyIterator();
    while (sit.next()) |k| {
        if (!published.contains(k.*)) {
            const owned = try gpa.dupe(u8, k.*);
            try published.put(owned, {});
        }
    }
}
