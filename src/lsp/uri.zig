//! Conversions between an LSP `file://` document URI and a plain
//! filesystem path — needed because every other layer of this server
//! (module.Loader, workspace.zig, symbols.zig) speaks in ordinary paths,
//! not URIs, matching `main.zig`'s own CLI (which never sees a URI at
//! all).

const std = @import("std");

/// Decodes a `file://` URI into a plain filesystem path, percent-decoded,
/// with the extra leading '/' Windows drive-letter URIs carry
/// (`file:///C:/Users/...`) stripped so the result is a normal `C:/...`
/// path. Returns `null` for anything not starting with `file://` (this
/// server only ever opens local files).
pub fn pathFromUri(allocator: std.mem.Allocator, uri: []const u8) !?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var rest = uri[prefix.len..];

    // `file:///C:/...` — the URI's own leading '/' before a Windows drive
    // letter isn't part of the path itself.
    if (rest.len >= 3 and rest[0] == '/' and std.ascii.isAlphabetic(rest[1]) and rest[2] == ':') {
        rest = rest[1..];
    }

    return try percentDecode(allocator, rest);
}

/// The reverse of `pathFromUri` — builds a `file://` URI for an absolute
/// filesystem `path` (as `workspace.Analysis`/`symbols.Module` report
/// them), used to name a Location/Diagnostic in a file OTHER than the one
/// a request was made against (e.g. a definition inside an imported
/// file).
pub fn uriFromPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("file://");

    const is_windows_drive = path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
    if (is_windows_drive) try w.writeByte('/');

    for (path) |c| {
        switch (c) {
            '\\' => try w.writeByte('/'),
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/', ':' => try w.writeByte(c),
            else => try w.print("%{X:0>2}", .{c}),
        }
    }
    return out.toOwnedSlice();
}

fn percentDecode(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |byte| {
                try out.append(allocator, byte);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;

test "pathFromUri strips the extra leading slash before a Windows drive letter" {
    const allocator = testing.allocator;
    const path = (try pathFromUri(allocator, "file:///C:/Users/dev/main.butter")).?;
    defer allocator.free(path);
    try testing.expectEqualStrings("C:/Users/dev/main.butter", path);
}

test "pathFromUri leaves a unix absolute path's own leading slash intact" {
    const allocator = testing.allocator;
    const path = (try pathFromUri(allocator, "file:///home/dev/main.butter")).?;
    defer allocator.free(path);
    try testing.expectEqualStrings("/home/dev/main.butter", path);
}

test "pathFromUri percent-decodes a space in the path" {
    const allocator = testing.allocator;
    const path = (try pathFromUri(allocator, "file:///C:/My%20Project/main.butter")).?;
    defer allocator.free(path);
    try testing.expectEqualStrings("C:/My Project/main.butter", path);
}

test "pathFromUri returns null for a non-file scheme" {
    const allocator = testing.allocator;
    try testing.expect(try pathFromUri(allocator, "untitled:Untitled-1") == null);
}

test "uriFromPath round-trips a Windows drive-letter path" {
    const allocator = testing.allocator;
    const uri = try uriFromPath(allocator, "C:/Users/dev/lib.butter");
    defer allocator.free(uri);
    try testing.expectEqualStrings("file:///C:/Users/dev/lib.butter", uri);

    const back = (try pathFromUri(allocator, uri)).?;
    defer allocator.free(back);
    try testing.expectEqualStrings("C:/Users/dev/lib.butter", back);
}

test "uriFromPath round-trips a unix absolute path" {
    const allocator = testing.allocator;
    const uri = try uriFromPath(allocator, "/home/dev/lib.butter");
    defer allocator.free(uri);
    try testing.expectEqualStrings("file:///home/dev/lib.butter", uri);
}

test "uriFromPath percent-encodes a space" {
    const allocator = testing.allocator;
    const uri = try uriFromPath(allocator, "/home/dev/My Project/lib.butter");
    defer allocator.free(uri);
    try testing.expectEqualStrings("file:///home/dev/My%20Project/lib.butter", uri);
}
