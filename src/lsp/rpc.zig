//! JSON-RPC 2.0 transport for the language server: `Content-Length`-framed
//! messages over stdio (the LSP spec's "base protocol"), using `std.json`
//! directly — `src/json.zig` is Butter's own `json()` builtin, tied to the
//! VM's runtime `Value` type, not a general-purpose JSON layer, so it
//! doesn't fit here.

const std = @import("std");

pub const ReadError = error{
    InvalidHeader,
    MissingContentLength,
} || std.Io.Reader.DelimiterError || std.Io.Reader.Error || std.mem.Allocator.Error;

/// Reads one `Content-Length`-framed message from `reader` and returns its
/// JSON body as a slice freshly allocated from `allocator` (caller owns
/// it — in practice, always a per-request arena, see server.zig). Returns
/// `null` at a clean end-of-stream between messages (the client closed
/// stdin), which is how a well-behaved LSP client signals it's done
/// after `exit`.
pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) ReadError!?[]u8 {
    var content_length: ?usize = null;
    while (true) {
        // `takeDelimiterInclusive`, not `takeDelimiterExclusive`: the
        // exclusive variant leaves the delimiter byte itself unconsumed in
        // the stream (it only advances past the returned content), so a
        // second call would immediately see that same '\n' again and
        // return an empty line — trimming it off here instead advances
        // past it correctly.
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return if (content_length == null) null else err,
            else => return err,
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break; // blank line ends the header block
        const sep = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidHeader;
        const name = std.mem.trim(u8, trimmed[0..sep], " \t");
        const value = std.mem.trim(u8, trimmed[sep + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidHeader;
        }
        // Any other header (e.g. Content-Type) is read and simply ignored.
    }
    const len = content_length orelse return error.MissingContentLength;
    return try reader.readAlloc(allocator, len);
}

/// Writes `body` (already-encoded JSON text) as one `Content-Length`-framed
/// message to `writer` and flushes it — a message isn't visible to the
/// client until this returns.
pub fn writeMessage(writer: *std.Io.Writer, body: []const u8) std.Io.Writer.Error!void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

/// Encodes `value` (any type `std.json.Stringify.value` accepts — see
/// protocol.zig's structs) as a JSON-RPC response/notification envelope
/// and sends it, framed via `writeMessage`. `id` is `null` for a
/// notification; otherwise the exact `std.json.Value` the request carried,
/// echoed back verbatim (LSP ids round-trip as either a JSON number or
/// string, so this is simpler and more correct than re-typing it).
pub fn send(allocator: std.mem.Allocator, writer: *std.Io.Writer, comptime shape: enum { notification, response, err }, args: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    switch (shape) {
        .notification => {
            try s.objectField("method");
            try s.write(args.method);
            try s.objectField("params");
            try s.write(args.params);
        },
        .response => {
            try s.objectField("id");
            try s.write(args.id);
            try s.objectField("result");
            try s.write(args.result);
        },
        .err => {
            try s.objectField("id");
            try s.write(args.id);
            try s.objectField("error");
            try s.beginObject();
            try s.objectField("code");
            try s.write(args.code);
            try s.objectField("message");
            try s.write(args.message);
            try s.endObject();
        },
    }
    try s.endObject();

    try writeMessage(writer, out.written());
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;

test "readMessage decodes one Content-Length-framed message" {
    const allocator = testing.allocator;
    const raw = "Content-Length: 12\r\n\r\n{\"a\":\"hi!\"}\n";
    var reader = std.Io.Reader.fixed(raw);
    const body = try readMessage(allocator, &reader);
    defer allocator.free(body.?);
    try testing.expectEqualStrings("{\"a\":\"hi!\"}\n", body.?);
}

test "readMessage ignores unrelated headers" {
    const allocator = testing.allocator;
    const raw = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: 2\r\n\r\n{}";
    var reader = std.Io.Reader.fixed(raw);
    const body = try readMessage(allocator, &reader);
    defer allocator.free(body.?);
    try testing.expectEqualStrings("{}", body.?);
}

test "readMessage returns null at a clean end of stream between messages" {
    const allocator = testing.allocator;
    var reader = std.Io.Reader.fixed("");
    const body = try readMessage(allocator, &reader);
    try testing.expect(body == null);
}

test "readMessage reports a missing Content-Length header" {
    const allocator = testing.allocator;
    var reader = std.Io.Reader.fixed("\r\n{}");
    try testing.expectError(error.MissingContentLength, readMessage(allocator, &reader));
}

test "send frames a notification with the correct Content-Length" {
    const allocator = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try send(allocator, &out.writer, .notification, .{
        .method = "textDocument/publishDiagnostics",
        .params = .{ .uri = "file:///a.butter", .diagnostics = &[_]u8{} },
    });

    const written = out.written();
    const header_end = std.mem.indexOf(u8, written, "\r\n\r\n").?;
    const header = written[0..header_end];
    const body = written[header_end + 4 ..];

    try testing.expect(std.mem.indexOf(u8, header, "Content-Length:") != null);
    try testing.expectEqual(body.len, blk: {
        const cl_prefix = "Content-Length: ";
        const start = std.mem.indexOf(u8, header, cl_prefix).? + cl_prefix.len;
        break :blk try std.fmt.parseInt(usize, header[start..], 10);
    });
    try testing.expect(std.mem.indexOf(u8, body, "\"method\":\"textDocument/publishDiagnostics\"") != null);
}

test "send round-trips a response's id and result" {
    const allocator = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try send(allocator, &out.writer, .response, .{
        .id = std.json.Value{ .integer = 7 },
        .result = .{ .ok = true },
    });

    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "\"id\":7") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"ok\":true") != null);
}
