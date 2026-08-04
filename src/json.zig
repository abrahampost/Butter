//! Converts JSON text into Butter's own refcounted `Value` tree (ISA.bnf
//! section 12) via Zig's `std.json` — see GRAMMAR.bnf design note 3n for why
//! this is a VM-native builtin (`json(buffer, count)`) rather than an
//! ordinary `func`: a parsed document's root type (number/bool/null/string/
//! list/map) is only known once the bytes are actually read, and a `func`'s
//! return type has to be fixed and declared (design note 3c).
//!
//! `std.json` does the actual parsing/tokenizing (JSON's escapes, Unicode,
//! and number formats are a solved, uninteresting problem here); this file
//! is entirely about walking the resulting `std.json.Value` tree and
//! building the equivalent Butter heap objects (ISA.bnf section 11).

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Object = value_mod.Object;

pub const JsonError = error{JsonParseFailed} || std.mem.Allocator.Error;

/// Parses `bytes` as a JSON document and returns the equivalent Butter
/// `Value`. Every heap object the result is built from (or contains,
/// transitively) is freshly created via `allocator` with the refcount an
/// owner expects (1) — the caller owns the whole tree outright, exactly as
/// if it had been built by ordinary MAKE_LIST/MAKE_MAP/`mapSet` calls.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) JsonError!Value {
    // The scratch arena std.json builds its own `std.json.Value` tree in is
    // entirely separate from (and freed well before returning) the Butter
    // heap objects `convert` allocates below — the two never share storage.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.JsonParseFailed,
    };
    defer parsed.deinit();
    return convert(allocator, parsed.value);
}

pub const StringifyError = error{Unstringifiable} || std.mem.Allocator.Error;

/// Renders `v` as JSON text and returns it as a fresh heap-owned Butter
/// `string` — the reverse of `parse`. This is a dedicated JSON encoder, NOT
/// `Value.print` (value.zig): `print` renders every value kind (including a
/// stream, as `<stdout>`) for human-readable debug output and never escapes
/// string content, since it exists to be read by a person, not re-parsed.
/// This instead produces only well-formed JSON — proper escaping via
/// `std.json.Stringify.encodeJsonString` (the same "let std.json handle the
/// solved problem" split `parse` already makes), and `error.Unstringifiable`
/// for a stream or array reference, neither of which JSON has a value for.
pub fn stringify(allocator: std.mem.Allocator, v: Value) StringifyError!Value {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    write(v, &out.writer) catch |err| switch (err) {
        // `out.writer` only ever fails via the allocator behind it.
        error.WriteFailed => return error.OutOfMemory,
        error.Unstringifiable => return error.Unstringifiable,
    };
    const owned = try out.toOwnedSlice();
    return .{ .object = try Object.create(allocator, .{ .string = owned }) };
}

fn write(v: Value, writer: *std.Io.Writer) (std.Io.Writer.Error || error{Unstringifiable})!void {
    switch (v) {
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .boolean => |b| try writer.print("{}", .{b}),
        .null_value => try writer.writeAll("null"),
        // Reachable from surfaceable Butter syntax (`print stdout` is legal,
        // so `stringify(stdout)` parses too) but JSON has no value for
        // either — unlike `Value.print`'s `<stdout>`/`<array>` placeholders,
        // a JSON encoder has no business inventing text that isn't valid
        // JSON, so this is an error instead.
        .stream, .array_ref => return error.Unstringifiable,
        // Like a stream/array reference, JSON has no native shape for an
        // enum variant, and unlike a map/list/record there's no reasonable
        // one-way rendering either (a bare string would silently collide
        // with an ordinary string value) — same "no representation, don't
        // invent one" stance (GRAMMAR.bnf design note 3aa).
        .enum_value => return error.Unstringifiable,
        .object => |o| switch (o.payload) {
            .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, writer),
            .list => |list| {
                try writer.writeByte('[');
                for (list.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(',');
                    try write(item, writer);
                }
                try writer.writeByte(']');
            },
            .map => |map| {
                try writer.writeByte('{');
                var it = map.iterator();
                var i: usize = 0;
                while (it.next()) |entry| : (i += 1) {
                    if (i > 0) try writer.writeByte(',');
                    try std.json.Stringify.encodeJsonString(entry.key_ptr.*, .{}, writer);
                    try writer.writeByte(':');
                    try write(entry.value_ptr.*, writer);
                }
                try writer.writeByte('}');
            },
            // Renders like `.map` — a JSON object keyed by each field's
            // declared name, in declared order (GRAMMAR.bnf design note
            // 3z) — a one-way rendering only: `json_parse` can never
            // produce a record back (confirmed in `convert`, below).
            .record => |r| {
                try writer.writeByte('{');
                for (r.field_names, r.fields, 0..) |name, field_v, i| {
                    if (i > 0) try writer.writeByte(',');
                    try std.json.Stringify.encodeJsonString(name, .{}, writer);
                    try writer.writeByte(':');
                    try write(field_v, writer);
                }
                try writer.writeByte('}');
            },
        },
    }
}

fn convert(allocator: std.mem.Allocator, v: std.json.Value) JsonError!Value {
    switch (v) {
        .null => return .null_value,
        .bool => |b| return .{ .boolean = b },
        .integer => |i| return .{ .int = i },
        .float => |f| return .{ .float = f },
        // Only reached for an integer literal that overflows i64, or a
        // float so extreme std.json couldn't represent it as an f64 (e.g.
        // `1e400`) — fall back to a best-effort float parse rather than
        // failing the whole document over one field.
        .number_string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch return error.JsonParseFailed;
            return .{ .float = f };
        },
        .string => |s| return Value.newString(allocator, s),
        .array => |arr| {
            var list: std.ArrayList(Value) = .empty;
            errdefer {
                for (list.items) |item| item.decref(allocator);
                list.deinit(allocator);
            }
            for (arr.items) |item| {
                try list.append(allocator, try convert(allocator, item));
            }
            const obj = try Object.create(allocator, .{ .list = list });
            return .{ .object = obj };
        },
        .object => |o| {
            const obj = try Object.create(allocator, .{ .map = .empty });
            errdefer (Value{ .object = obj }).decref(allocator);
            var it = o.iterator();
            while (it.next()) |entry| {
                const converted = try convert(allocator, entry.value_ptr.*);
                errdefer converted.decref(allocator);
                try obj.mapSet(allocator, entry.key_ptr.*, converted);
            }
            return .{ .object = obj };
        },
    }
}

fn expectParsed(comptime T: type, expected: T, bytes: []const u8, comptime field: []const u8) !void {
    const allocator = std.testing.allocator;
    const v = try parse(allocator, bytes);
    defer v.decref(allocator);
    try std.testing.expectEqual(expected, @field(v, field));
}

test "parse converts each JSON scalar kind" {
    try expectParsed(bool, true, "true", "boolean");
    try expectParsed(i64, 42, "42", "int");
    try expectParsed(f64, 1.5, "1.5", "float");

    const allocator = std.testing.allocator;
    const n = try parse(allocator, "null");
    defer n.decref(allocator);
    try std.testing.expect(n == .null_value);
}

test "parse converts a JSON string into a heap-owned string value" {
    const allocator = std.testing.allocator;
    const v = try parse(allocator, "\"hello\"");
    defer v.decref(allocator);

    try std.testing.expect(v == .object);
    try std.testing.expectEqualStrings("hello", v.asStringBytes().?);
}

test "parse converts a JSON array into a list, preserving order" {
    const allocator = std.testing.allocator;
    const v = try parse(allocator, "[1, 2, 3]");
    defer v.decref(allocator);

    try std.testing.expect(v.object.payload == .list);
    const items = v.object.payload.list.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].int);
    try std.testing.expectEqual(@as(i64, 3), items[2].int);
}

test "parse converts a JSON object into a map, preserving insertion order" {
    const allocator = std.testing.allocator;
    const v = try parse(allocator, "{\"name\": \"Ada\", \"active\": true}");
    defer v.decref(allocator);

    try std.testing.expect(v.object.payload == .map);
    try std.testing.expectEqualStrings("Ada", v.object.mapGet("name").?.asStringBytes().?);
    try std.testing.expectEqual(true, v.object.mapGet("active").?.boolean);

    var it = v.object.payload.map.iterator();
    const first = it.next().?;
    try std.testing.expectEqualStrings("name", first.key_ptr.*);
}

test "parse handles nested objects/arrays and frees them without leaking" {
    const allocator = std.testing.allocator;
    const v = try parse(allocator,
        \\{"tags": ["a", "b"], "meta": {"count": 2}}
    );
    defer v.decref(allocator);

    const tags = v.object.mapGet("tags").?;
    try std.testing.expectEqual(@as(usize, 2), tags.object.payload.list.items.len);

    const meta = v.object.mapGet("meta").?;
    try std.testing.expectEqual(@as(i64, 2), meta.object.mapGet("count").?.int);
}

test "parse reports malformed input as JsonParseFailed rather than crashing" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.JsonParseFailed, parse(allocator, "{not valid json"));
    try std.testing.expectError(error.JsonParseFailed, parse(allocator, ""));
}

fn expectStringified(v: Value, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, v);
    defer result.decref(allocator);
    try std.testing.expectEqualStrings(expected, result.asStringBytes().?);
}

test "stringify renders each scalar kind" {
    const allocator = std.testing.allocator;
    try expectStringified(.{ .int = 42 }, "42");
    try expectStringified(.{ .float = 1.5 }, "1.5");
    try expectStringified(.{ .boolean = true }, "true");
    try expectStringified(.null_value, "null");
    const hi = try Value.newString(allocator, "hi");
    defer hi.decref(allocator);
    try expectStringified(hi, "\"hi\"");
}

test "stringify escapes special characters, unlike Value.print's bare quoting" {
    const allocator = std.testing.allocator;
    const s = try Value.newString(allocator, "a\"b\\c\nd\te");
    defer s.decref(allocator);
    try expectStringified(s, "\"a\\\"b\\\\c\\nd\\te\"");
}

test "stringify renders a list and a map with proper JSON punctuation" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(Value) = .empty;
    try list.append(allocator, .{ .int = 1 });
    try list.append(allocator, try Value.newString(allocator, "a"));
    const list_obj = try Object.create(allocator, .{ .list = list });
    try expectStringified(.{ .object = list_obj }, "[1,\"a\"]");
    (Value{ .object = list_obj }).decref(allocator);

    const map_obj = try Object.create(allocator, .{ .map = .empty });
    try map_obj.mapSet(allocator, "a", .{ .int = 1 });
    try map_obj.mapSet(allocator, "b", .null_value);
    try expectStringified(.{ .object = map_obj }, "{\"a\":1,\"b\":null}");
    (Value{ .object = map_obj }).decref(allocator);
}

test "stringify round-trips through parse" {
    const allocator = std.testing.allocator;
    const original = try parse(allocator,
        \\{"name": "Ada", "tags": ["a", "b"], "active": true, "meta": null}
    );
    defer original.decref(allocator);

    const text = try stringify(allocator, original);
    defer text.decref(allocator);

    const reparsed = try parse(allocator, text.asStringBytes().?);
    defer reparsed.decref(allocator);

    try std.testing.expectEqualStrings("Ada", reparsed.object.mapGet("name").?.asStringBytes().?);
    try std.testing.expectEqual(true, reparsed.object.mapGet("active").?.boolean);
    try std.testing.expect(reparsed.object.mapGet("meta").? == .null_value);
    try std.testing.expectEqual(@as(usize, 2), reparsed.object.mapGet("tags").?.object.payload.list.items.len);
}

test "stringify reports a stream or array reference as Unstringifiable" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.Unstringifiable, stringify(allocator, .{ .stream = value_mod.Stream.ofStandard(.stdout) }));
    try std.testing.expectError(error.Unstringifiable, stringify(allocator, .{ .array_ref = .{ .base = 0, .len = 0 } }));
}

test "stringify renders a record like a map, keyed by its declared field names" {
    const allocator = std.testing.allocator;
    const field_names = [_][]const u8{ "x", "y" };
    const fields = try allocator.alloc(Value, 2);
    fields[0] = .{ .int = 1 };
    fields[1] = try Value.newString(allocator, "a");
    const record_obj = try Object.create(allocator, .{ .record = .{ .type_name = "Point", .field_names = &field_names, .fields = fields } });
    try expectStringified(.{ .object = record_obj }, "{\"x\":1,\"y\":\"a\"}");
    (Value{ .object = record_obj }).decref(allocator);
}

test "stringify reports an enum value as Unstringifiable" {
    const allocator = std.testing.allocator;
    const red: Value = .{ .enum_value = .{ .type_index = 0, .variant = 0, .type_name = "Color", .variant_name = "Red" } };
    try std.testing.expectError(error.Unstringifiable, stringify(allocator, red));
}
