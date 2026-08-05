//! Bundled standard-library modules — Butter source embedded straight into
//! the compiled `butter` binary at build time, so `import "math.std.butter"`
//! resolves without a copy of that file existing anywhere on the caller's
//! filesystem (module.zig's `Loader.loadModule` checks `lookup` before ever
//! touching disk). The `.std.butter` suffix is a reserved naming convention
//! for these bundled modules, not a language-level namespace: `lookup` only
//! ever does an exact string match against `entries`, so an import path has
//! to spell one of those names exactly to hit this table instead of the
//! filesystem.

const std = @import("std");

const Entry = struct { name: []const u8, source: []const u8 };

const entries = [_]Entry{
    .{ .name = "math.std.butter", .source = @embedFile("std/math.std.butter") },
    .{ .name = "collections.std.butter", .source = @embedFile("std/collections.std.butter") },
    .{ .name = "string.std.butter", .source = @embedFile("std/string.std.butter") },
};

/// Returns the embedded source for `name` if it names a bundled standard
/// library module, or `null` if `name` should be resolved against the
/// filesystem as an ordinary `import` path instead.
pub fn lookup(name: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.source;
    }
    return null;
}
