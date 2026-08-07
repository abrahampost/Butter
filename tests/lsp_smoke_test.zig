//! Drives the actual built `butter-lsp` binary over real stdio JSON-RPC —
//! the one layer none of src/lsp/*.zig's own in-process unit tests
//! exercise (rpc.zig's framing end to end, server.zig's request dispatch,
//! and the process actually starting up and shutting down cleanly). Its
//! own protocol-framing helpers are a thin, deliberately independent
//! reimplementation (not `@import`ing src/lsp/rpc.zig) so this test
//! doesn't validate the server against itself.

const std = @import("std");
const build_options = @import("build_options");

const io = std.testing.io;

fn writeFramed(writer: *std.Io.Writer, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

fn readFramed(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = try reader.takeDelimiterInclusive('\n');
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        const sep = std.mem.indexOfScalar(u8, trimmed, ':').?;
        const name = std.mem.trim(u8, trimmed[0..sep], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, trimmed[sep + 1 ..], " \t"), 10);
        }
    }
    return try reader.readAlloc(allocator, content_length.?);
}

fn sendMessage(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer);
    try writeFramed(writer, out.written());
}

const Client = struct {
    child: std.process.Child,
    stdin_writer: std.Io.File.Writer,
    stdout_reader: std.Io.File.Reader,
    stdin_buf: [4096]u8 = undefined,
    stdout_buf: [8192]u8 = undefined,
    next_id: i64 = 1,

    fn start(allocator: std.mem.Allocator) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);

        const child = try std.process.spawn(io, .{
            .argv = &.{build_options.lsp_exe_path},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });

        self.* = .{
            .child = child,
            .stdin_writer = .init(child.stdin.?, io, &self.stdin_buf),
            .stdout_reader = .init(child.stdout.?, io, &self.stdout_buf),
        };
        return self;
    }

    /// `kill` (unlike `wait`) is documented idempotent — a no-op if
    /// `wait` was already called (the happy path below always calls it
    /// itself, to check the exit code) — so this is safe as a `defer`
    /// regardless of whether the test reached that point.
    fn stop(self: *Client, allocator: std.mem.Allocator) void {
        self.child.kill(io);
        allocator.destroy(self);
    }

    fn request(self: *Client, allocator: std.mem.Allocator, method: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
        const id = self.next_id;
        self.next_id += 1;
        try sendMessage(allocator, &self.stdin_writer.interface, .{
            .jsonrpc = "2.0",
            .id = id,
            .method = method,
            .params = params,
        });
        const body = try readFramed(allocator, &self.stdout_reader.interface);
        defer allocator.free(body);
        return std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    }

    fn notify(self: *Client, allocator: std.mem.Allocator, method: []const u8, params: anytype) !void {
        try sendMessage(allocator, &self.stdin_writer.interface, .{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
        });
    }
};

const sample_source =
    \\func add(int a, int b) -> int {
    \\    return a + b
    \\}
    \\print add(1, 2)
    \\
;

test "butter-lsp answers initialize, hover, definition, and documentSymbol over real stdio" {
    const allocator = std.testing.allocator;
    const client = try Client.start(allocator);
    defer client.stop(allocator);

    {
        var resp = try client.request(allocator, "initialize", .{ .processId = null, .rootUri = null, .capabilities = .{} });
        defer resp.deinit();
        const result = resp.value.object.get("result").?;
        try std.testing.expect(result.object.get("capabilities") != null);
    }

    try client.notify(allocator, "initialized", .{});

    try client.notify(allocator, "textDocument/didOpen", .{
        .textDocument = .{
            .uri = "file:///smoke.butter",
            .languageId = "butter",
            .version = 1,
            .text = sample_source,
        },
    });

    {
        // "add" on line 3 (0-based), right after "print ".
        var resp = try client.request(allocator, "textDocument/hover", .{
            .textDocument = .{ .uri = "file:///smoke.butter" },
            .position = .{ .line = 3, .character = 7 },
        });
        defer resp.deinit();
        const result = resp.value.object.get("result").?;
        try std.testing.expect(result != .null);
        const contents = result.object.get("contents").?.object.get("value").?.string;
        try std.testing.expect(std.mem.indexOf(u8, contents, "func add(int a, int b) -> int") != null);
    }

    {
        var resp = try client.request(allocator, "textDocument/definition", .{
            .textDocument = .{ .uri = "file:///smoke.butter" },
            .position = .{ .line = 3, .character = 7 },
        });
        defer resp.deinit();
        const result = resp.value.object.get("result").?;
        try std.testing.expect(result != .null);
        try std.testing.expectEqual(@as(i64, 0), result.object.get("range").?.object.get("start").?.object.get("line").?.integer);
    }

    {
        var resp = try client.request(allocator, "textDocument/documentSymbol", .{
            .textDocument = .{ .uri = "file:///smoke.butter" },
        });
        defer resp.deinit();
        const result = resp.value.object.get("result").?;
        try std.testing.expect(result.array.items.len >= 1);
    }

    try client.notify(allocator, "textDocument/didClose", .{
        .textDocument = .{ .uri = "file:///smoke.butter" },
    });

    {
        var resp = try client.request(allocator, "shutdown", .{});
        defer resp.deinit();
    }
    try client.notify(allocator, "exit", .{});

    const term = try client.child.wait(io);
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}
