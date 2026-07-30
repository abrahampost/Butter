//! Runtime value representation for the Butter VM (ISA.bnf, section 2).
//!
//! Every value is either a plain scalar, a string slice borrowed from a
//! Chunk's constant pool, an `array_ref` — a reference to a generic (unsized)
//! array parameter's underlying slots, still living somewhere else on the
//! VM's own value stack (ISA.bnf section 6's generic-array addendum), never
//! on a heap — or, since maps/lists (ISA.bnf section 11), a refcounted
//! `object` pointing at real heap storage. Scalars, borrowed strings, and
//! array references still need no allocator and no destructor; `object` is
//! the one exception, and its lifetime is managed by a plain refcount, not a
//! tracing collector (see `Object.destroy`).

const std = @import("std");

/// Something a program can `read` from or `write` to (GRAMMAR.bnf design
/// notes 3k and 3l): one of the three standard streams, or a file the
/// program opened. Unlike every other kind of runtime value, a stream has
/// no literal syntax that can produce an arbitrary one — the three
/// `standard` ones are named by keyword and a `file` one only ever comes
/// from `open` (ISA.bnf section 10).
///
/// A `file` payload is an index into the VM's own fixed-size table of open
/// files, NOT an OS file descriptor. That indirection is what keeps a
/// stream a plain 8-byte value with nothing to free: the actual `File`,
/// its direction, and its buffer all live in the VM, and closing a file
/// clears its table slot rather than invalidating any value the program
/// might still be holding (using a stream whose slot has been cleared is a
/// clean `RuntimeError.StreamClosed`, never a dangling handle).
pub const Stream = union(enum) {
    standard: Standard,
    file: u32,

    pub const Standard = enum(u32) {
        stdin,
        stdout,
        stderr,

        pub fn name(self: Standard) []const u8 {
            return @tagName(self);
        }
    };

    pub fn ofStandard(standard: Standard) Stream {
        return .{ .standard = standard };
    }
};

/// Which direction (and, for `write`, whether to truncate) `open` opens a
/// file in — `'read' | 'write' | 'append'` in source. Declared here beside
/// `Stream` for the same reason: it's the one part of a file that IS fixed
/// at compile time, so it travels as the OPEN instruction's operand and has
/// to be named by the same type on both the AST and the ISA side.
pub const OpenMode = enum(u32) {
    /// The file must already exist.
    read,
    /// Created if absent, truncated to empty if present.
    write,
    /// Created if absent, kept and written past its current end if present.
    append,

    pub fn readable(self: OpenMode) bool {
        return self == .read;
    }

    pub fn writable(self: OpenMode) bool {
        return self == .write or self == .append;
    }

    pub fn name(self: OpenMode) []const u8 {
        return @tagName(self);
    }
};

/// A generic array parameter's runtime representation: `base` is an
/// absolute index into the VM's `stack` array (not frame-relative — it's
/// computed once, at the point the reference is created, from whichever
/// frame's `bp` the referenced array actually lives in), and `len` is its
/// length. This is the only *stack*-referencing value in the language; it
/// is never null/dangling by construction — see the compiler's escape rule
/// (`compiler.zig`'s generic-array-return handling) for why a reference can
/// never outlive the frame it points into. `Object` (below) is a second,
/// unrelated kind of reference — into the heap, not the stack — with its
/// own, very different, lifetime story (refcounting, not escape analysis).
pub const ArrayRef = struct { base: u32, len: u32 };

/// A refcounted heap allocation (GRAMMAR.bnf design note 3m; ISA.bnf section
/// 11) — the VM's first and only heap-managed runtime object. `map`/`list`
/// values, and any STRING a program produces that didn't already exist as a
/// compile-time literal (namely, one read out of parsed JSON — ISA.bnf
/// section 12), all live here instead of in a borrowed slice or a stack
/// slot. `refcount` starts at 1 (the reference returned by whatever created
/// it) and is adjusted by `Value.incref`/`Value.decref`; reaching 0 frees
/// this object and recursively decrefs everything it holds (`destroy`,
/// below) — a plain recursive free, not a tracing collector. A
/// self-referential structure (`m["self"] := m`) never reaches refcount 0
/// and leaks for the life of the `Vm.run` call it was created in; this is a
/// known, accepted limitation (GRAMMAR.bnf design note 3m), not a bug to fix
/// here.
pub const Object = struct {
    refcount: usize = 1,
    payload: Payload,

    pub const Payload = union(enum) {
        /// Heap-owned bytes — e.g. a JSON string leaf. Distinct from
        /// `Value.string`, which is always a borrowed compile-time slice;
        /// `Value.asStringBytes` is what lets code elsewhere treat the two
        /// interchangeably by content.
        string: []const u8,
        list: std.ArrayList(Value),
        /// Order-preserving (not a plain hash map) so `keys()`, `print`, and
        /// a re-serialized JSON document all see deterministic,
        /// insertion-order output rather than hash-bucket order.
        map: std.StringArrayHashMapUnmanaged(Value),
    };

    pub fn create(allocator: std.mem.Allocator, payload: Payload) !*Object {
        const self = try allocator.create(Object);
        self.* = .{ .payload = payload };
        return self;
    }

    /// Recursively decrefs every child value this object holds, frees its
    /// own backing storage, and frees the object itself. Only ever called
    /// by `Value.decref` when a refcount reaches 0.
    fn destroy(self: *Object, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .string => |s| allocator.free(s),
            .list => |*list| {
                for (list.items) |v| v.decref(allocator);
                list.deinit(allocator);
            },
            .map => |*map| {
                var it = map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.decref(allocator);
                }
                map.deinit(allocator);
            },
        }
        allocator.destroy(self);
    }

    /// Inserts or updates `key` -> `value`. `key`'s bytes are always
    /// duplicated into a fresh, map-owned allocation on first insertion
    /// (never a borrowed slice into whatever expression produced the key)
    /// so that `mapKeys`/removal/destruction all have a single, uniform
    /// ownership story regardless of where the key value originally came
    /// from. Asserts `self.payload == .map`.
    pub fn mapSet(self: *Object, allocator: std.mem.Allocator, key: []const u8, value: Value) !void {
        const map = &self.payload.map;
        const gop = try map.getOrPut(allocator, key);
        if (gop.found_existing) {
            gop.value_ptr.decref(allocator);
        } else {
            gop.key_ptr.* = try allocator.dupe(u8, key);
        }
        gop.value_ptr.* = value;
    }

    /// Asserts `self.payload == .map`.
    pub fn mapGet(self: *const Object, key: []const u8) ?Value {
        return self.payload.map.get(key);
    }

    /// Removes `key` if present, freeing its owned key copy and decreffing
    /// its value; returns whether it was present. Asserts `self.payload ==
    /// .map`. Uses `fetchOrderedRemove` (not the swap-remove variant) so
    /// removal preserves the insertion order every other map operation
    /// promises.
    pub fn mapDelete(self: *Object, allocator: std.mem.Allocator, key: []const u8) bool {
        const kv = self.payload.map.fetchOrderedRemove(key) orelse return false;
        allocator.free(kv.key);
        kv.value.decref(allocator);
        return true;
    }
};

pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    array_ref: ArrayRef,
    stream: Stream,
    /// JSON's `null` (ISA.bnf section 12). Carries no payload — there is
    /// exactly one null value, and copying/discarding it is as free as any
    /// other scalar.
    null_value,
    object: *Object,

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .int => "int",
            .float => "float",
            .boolean => "bool",
            .string => "string",
            .array_ref => "array",
            .stream => "stream",
            .null_value => "null",
            .object => |o| switch (o.payload) {
                .string => "string",
                .list => "list",
                .map => "map",
            },
        };
    }

    pub fn isNumeric(self: Value) bool {
        return self == .int or self == .float;
    }

    /// Asserts `isNumeric(self)`.
    pub fn asFloat(self: Value) f64 {
        return switch (self) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
            else => unreachable,
        };
    }

    /// Returns this value's bytes if it's string-shaped — either the
    /// borrowed compile-time `.string` variant or a heap `object{.string}`
    /// (ISA.bnf section 11) — or `null` otherwise. This is what lets a
    /// runtime-constructed heap string (e.g. from parsed JSON) compare
    /// equal to, and be used anywhere as, an ordinary borrowed STRING.
    pub fn asStringBytes(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            .object => |o| if (o.payload == .string) o.payload.string else null,
            else => null,
        };
    }

    /// Bumps this value's heap object's refcount, if it has one. Called
    /// whenever a `Value` is duplicated into a second live location while
    /// the first stays live (e.g. LOAD_LOCAL, INDEX_GET's result) — a no-op
    /// for every non-`object` value.
    pub fn incref(self: Value) void {
        switch (self) {
            .object => |o| o.refcount += 1,
            else => {},
        }
    }

    /// Drops this value's heap object's refcount, if it has one, freeing it
    /// (recursively) once it reaches 0. Called whenever a live `Value` slot
    /// is permanently destroyed or overwritten without moving (POP, an
    /// overwritten local/index slot, a departing frame's locals) — a no-op
    /// for every non-`object` value.
    pub fn decref(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .object => |o| {
                o.refcount -= 1;
                if (o.refcount == 0) o.destroy(allocator);
            },
            else => {},
        }
    }

    /// Structural equality, defined for every pair of value types: numeric
    /// values compare across int/float by value, string-shaped values
    /// (borrowed or heap, `asStringBytes` above) compare by content, and any
    /// other mismatched pair of types simply compares unequal rather than
    /// erroring (as `==` behaves in most dynamically-checked languages).
    /// list/map values compare by POINTER IDENTITY ONLY, never deep: no
    /// other `Value` variant does deep comparison either (`ArrayRef`/
    /// `Stream` compare cheap tuples), and a deep comparison could hang on
    /// an accepted self-referential cycle (GRAMMAR.bnf design note 3m).
    pub fn eql(a: Value, b: Value) bool {
        if (a.isNumeric() and b.isNumeric()) {
            if (a == .int and b == .int) return a.int == b.int;
            return a.asFloat() == b.asFloat();
        }
        if (a.asStringBytes()) |av| {
            return if (b.asStringBytes()) |bv| std.mem.eql(u8, av, bv) else false;
        }
        return switch (a) {
            .int, .float => false, // one operand numeric, the other not
            .boolean => |av| b == .boolean and av == b.boolean,
            .string => unreachable, // asStringBytes above already handled this
            // Never reachable from surfaceable Butter syntax (a generic
            // array reference can only ever be indexed, measured with
            // `len`, or forwarded — never compared) but Value must still
            // define eql for every pair to keep this switch exhaustive.
            .array_ref => |av| b == .array_ref and av.base == b.array_ref.base and av.len == b.array_ref.len,
            // Two streams are equal when they name the same thing, so a
            // program can check `f == stdout`. Note a file slot is
            // reusable: after `close`, a later `open` may hand back an
            // equal stream value naming an entirely different file.
            .stream => |av| b == .stream and std.meta.eql(av, b.stream),
            .null_value => b == .null_value,
            .object => |ao| switch (ao.payload) {
                .string => unreachable, // asStringBytes above already handled this
                .list, .map => b == .object and ao == b.object,
            },
        };
    }

    /// Cheap insurance against a self-referential list/map (GRAMMAR.parse
    /// design note 3m's accepted cycle-leak tradeoff) turning `print` into
    /// an infinite recursion/stack overflow instead of just a leak.
    const max_print_depth = 64;

    pub fn print(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.printAt(writer, 0, false);
    }

    /// `quoted` distinguishes top-level string rendering (unquoted — a bare
    /// `print "hi"` writes `hi`, unchanged from before lists/maps existed)
    /// from rendering a string as a LIST/MAP ELEMENT (quoted, JSON-ish —
    /// `print [1, "a"]` writes `[1, "a"]`, not `[1, a]`).
    fn printAt(self: Value, writer: *std.Io.Writer, depth: usize, quoted: bool) std.Io.Writer.Error!void {
        switch (self) {
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .boolean => |v| try writer.print("{}", .{v}),
            .string => |v| if (quoted) try writer.print("\"{s}\"", .{v}) else try writer.writeAll(v),
            // Not reachable from surfaceable Butter syntax either (see the
            // `eql` note above) — kept only so this switch stays exhaustive.
            .array_ref => try writer.writeAll("<array>"),
            // A stream IS reachable here (`print stdout` is legal), so
            // unlike an array reference this rendering is a real one a
            // program can produce, not just switch-exhaustiveness padding.
            .stream => |s| switch (s) {
                .standard => |std_stream| try writer.print("<{s}>", .{std_stream.name()}),
                .file => |slot| try writer.print("<file {d}>", .{slot}),
            },
            .null_value => try writer.writeAll("null"),
            .object => |o| switch (o.payload) {
                .string => |v| if (quoted) try writer.print("\"{s}\"", .{v}) else try writer.writeAll(v),
                .list => |list| {
                    if (depth >= max_print_depth) return writer.writeAll("...");
                    try writer.writeAll("[");
                    for (list.items, 0..) |item, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try item.printAt(writer, depth + 1, true);
                    }
                    try writer.writeAll("]");
                },
                .map => |map| {
                    if (depth >= max_print_depth) return writer.writeAll("...");
                    try writer.writeAll("{");
                    var it = map.iterator();
                    var i: usize = 0;
                    while (it.next()) |entry| : (i += 1) {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.print("\"{s}\": ", .{entry.key_ptr.*});
                        try entry.value_ptr.printAt(writer, depth + 1, true);
                    }
                    try writer.writeAll("}");
                },
            },
        }
    }
};

fn expectPrint(value: Value, expected: []const u8) !void {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try value.print(&writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "print renders each value kind" {
    try expectPrint(.{ .int = 42 }, "42");
    try expectPrint(.{ .float = 3.5 }, "3.5");
    try expectPrint(.{ .boolean = true }, "true");
    try expectPrint(.{ .string = "hi" }, "hi");
    try expectPrint(.null_value, "null");
}

test "eql compares numerics across int/float" {
    try std.testing.expect(Value.eql(.{ .int = 1 }, .{ .float = 1.0 }));
    try std.testing.expect(!Value.eql(.{ .int = 1 }, .{ .float = 1.5 }));
}

test "eql compares same-type non-numeric values structurally" {
    try std.testing.expect(Value.eql(.{ .string = "hi" }, .{ .string = "hi" }));
    try std.testing.expect(!Value.eql(.{ .string = "hi" }, .{ .string = "bye" }));
    try std.testing.expect(Value.eql(.{ .boolean = true }, .{ .boolean = true }));
}

test "eql returns false (not an error) across incompatible types" {
    try std.testing.expect(!Value.eql(.{ .boolean = true }, .{ .int = 1 }));
    try std.testing.expect(!Value.eql(.{ .string = "1" }, .{ .int = 1 }));
}

test "eql treats null_value as equal only to itself" {
    try std.testing.expect(Value.eql(.null_value, .null_value));
    try std.testing.expect(!Value.eql(.null_value, .{ .boolean = false }));
    try std.testing.expect(!Value.eql(.null_value, .{ .int = 0 }));
}

test "Object.create/incref/decref manage a refcount and free at zero" {
    const allocator = std.testing.allocator;
    const obj = try Object.create(allocator, .{ .list = .empty });
    const v: Value = .{ .object = obj };

    try std.testing.expectEqual(@as(usize, 1), obj.refcount);
    v.incref();
    try std.testing.expectEqual(@as(usize, 2), obj.refcount);
    v.decref(allocator);
    try std.testing.expectEqual(@as(usize, 1), obj.refcount);
    v.decref(allocator); // drops to 0 and frees; std.testing.allocator catches
    //                       a leak or double-free if this is wrong.
}

test "decref on a freshly created list/map object frees it (no leak)" {
    const allocator = std.testing.allocator;
    const list_obj = try Object.create(allocator, .{ .list = .empty });
    (Value{ .object = list_obj }).decref(allocator);

    const map_obj = try Object.create(allocator, .{ .map = .empty });
    (Value{ .object = map_obj }).decref(allocator);
}

test "destroying a list recursively decrefs its elements" {
    const allocator = std.testing.allocator;
    const inner = try Object.create(allocator, .{ .list = .empty });

    var outer_payload: std.ArrayList(Value) = .empty;
    try outer_payload.append(allocator, .{ .int = 1 });
    try outer_payload.append(allocator, .{ .object = inner }); // adopts inner's +1
    const outer = try Object.create(allocator, .{ .list = outer_payload });

    (Value{ .object = outer }).decref(allocator); // frees outer, decrefs inner to 0, frees inner
}

test "mapSet/mapGet/mapDelete own their own key copies" {
    const allocator = std.testing.allocator;
    const obj = try Object.create(allocator, .{ .map = .empty });
    defer (Value{ .object = obj }).decref(allocator);

    var key_buf = [_]u8{ 'a', 'g', 'e' };
    try obj.mapSet(allocator, &key_buf, .{ .int = 30 });
    key_buf[0] = 'X'; // mutate the caller's buffer; the map must have its own copy

    try std.testing.expectEqual(@as(i64, 30), obj.mapGet("age").?.int);
    try std.testing.expect(obj.mapGet("Xge") == null);

    try obj.mapSet(allocator, "age", .{ .int = 31 }); // update, not a second entry
    try std.testing.expectEqual(@as(usize, 1), obj.payload.map.count());
    try std.testing.expectEqual(@as(i64, 31), obj.mapGet("age").?.int);

    try std.testing.expect(obj.mapDelete(allocator, "age"));
    try std.testing.expect(!obj.mapDelete(allocator, "age")); // already gone
    try std.testing.expectEqual(@as(usize, 0), obj.payload.map.count());
}

test "eql compares list/map objects by pointer identity, never deep" {
    const allocator = std.testing.allocator;
    const a = try Object.create(allocator, .{ .list = .empty });
    defer (Value{ .object = a }).decref(allocator);
    const b = try Object.create(allocator, .{ .list = .empty });
    defer (Value{ .object = b }).decref(allocator);

    try std.testing.expect(Value.eql(.{ .object = a }, .{ .object = a }));
    try std.testing.expect(!Value.eql(.{ .object = a }, .{ .object = b }));
}

test "asStringBytes unifies borrowed and heap strings for content equality" {
    const allocator = std.testing.allocator;
    const heap_bytes = try allocator.dupe(u8, "hi");
    const obj = try Object.create(allocator, .{ .string = heap_bytes });
    defer (Value{ .object = obj }).decref(allocator);

    try std.testing.expect(Value.eql(.{ .string = "hi" }, .{ .object = obj }));
    try std.testing.expectEqualStrings("hi", (Value{ .object = obj }).asStringBytes().?);
}

test "print renders a list with quoted string elements and a map as key: value pairs" {
    const allocator = std.testing.allocator;
    const list_obj = try Object.create(allocator, .{ .list = .empty });
    defer (Value{ .object = list_obj }).decref(allocator);
    try list_obj.payload.list.append(allocator, .{ .int = 1 });
    try list_obj.payload.list.append(allocator, .{ .string = "a" });

    try expectPrint(.{ .object = list_obj }, "[1, \"a\"]");

    const map_obj = try Object.create(allocator, .{ .map = .empty });
    defer (Value{ .object = map_obj }).decref(allocator);
    try map_obj.mapSet(allocator, "a", .{ .int = 1 });
    try map_obj.mapSet(allocator, "b", .null_value);

    try expectPrint(.{ .object = map_obj }, "{\"a\": 1, \"b\": null}");
}

test "print caps recursion depth on a self-referential list" {
    const allocator = std.testing.allocator;
    const obj = try Object.create(allocator, .{ .list = .empty });
    // Deliberately create a cycle: the list holds a reference to itself.
    // This is the accepted-leak case (GRAMMAR.bnf design note 3m) — free it
    // by hand afterward (bypassing decref, which would recurse forever
    // attempting to walk the cycle down to zero) rather than relying on
    // std.testing.allocator's leak check, since the whole point of this
    // test is that a cycle doesn't get collected on its own.
    defer {
        obj.payload.list.deinit(allocator);
        allocator.destroy(obj);
    }
    try obj.payload.list.append(allocator, .{ .object = obj });

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try (Value{ .object = obj }).print(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "...") != null);
}
