//! Runtime value representation for the Butter VM (ISA.bnf, section 2).
//!
//! Every value is either a plain scalar, an `array_ref` — a reference to a
//! generic (unsized) array parameter's underlying slots, still living
//! somewhere else on the VM's own value stack (ISA.bnf section 6's
//! generic-array addendum), never on a heap — or a refcounted `object`
//! pointing at real heap storage: strings, maps, and lists (ISA.bnf section
//! 11) all live there. Scalars and array references still need no allocator
//! and no destructor; `object` is the one exception, and its lifetime is
//! managed by a plain refcount, not a tracing collector (see
//! `Object.destroy`).

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
/// 11) — the VM's first and only heap-managed runtime object. Every
/// string, map, and list value lives here — never in a borrowed slice or a
/// stack slot. `refcount` starts at 1 (the reference returned by whatever
/// created it) and is adjusted by `Value.incref`/`Value.decref`; reaching 0
/// frees this object and recursively decrefs everything it holds
/// (`destroy`, below) — a plain recursive free, not a tracing collector. A
/// self-referential structure (`m["self"] := m`) never reaches refcount 0
/// and leaks for the life of the `Vm.run` call it was created in; this is a
/// known, accepted limitation (GRAMMAR.bnf design note 3m), not a bug to fix
/// here.
pub const Object = struct {
    refcount: usize = 1,
    payload: Payload,

    pub const Payload = union(enum) {
        /// Heap-owned bytes — the runtime representation of every string
        /// value, compile-time literal or dynamically produced alike
        /// (`Value.newString`). `Value.asStringBytes` is the seam other code
        /// uses to read a string's bytes without caring how it was made.
        string: []const u8,
        list: std.ArrayList(Value),
        /// Order-preserving (not a plain hash map) so `keys()`, `print`, and
        /// a re-serialized JSON document all see deterministic,
        /// insertion-order output rather than hash-bucket order.
        map: std.StringArrayHashMapUnmanaged(Value),
        /// A struct instance (GRAMMAR.bnf design note 3z, ISA.bnf section
        /// 19) — an ORDERED, compile-time-fixed set of fields, unlike
        /// `map`'s runtime string-keyed hash lookup: `fields[i]` is always
        /// the value of the struct type's i-th declared field, an index the
        /// compiler resolves once from the field's NAME and bakes directly
        /// into `FIELD_GET`/`FIELD_SET`'s operand — no runtime name lookup,
        /// no `RuntimeError.KeyNotFound` (a wrong field name is a compile
        /// error, `SemanticError.UnknownField`). `type_name` and
        /// `field_names` are shared, program-owned slices (borrowed from
        /// the compiler's registered struct-type table, `chunk.Program
        /// .struct_types` — same lifetime as `Function.name`), so every
        /// instance of the same struct type points at the same two slices;
        /// only `fields` itself is unique per instance.
        record: Record,
    };

    pub const Record = struct {
        type_name: []const u8,
        field_names: []const []const u8,
        fields: []Value,
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
            .record => |*record| {
                // type_name/field_names are borrowed from the program's own
                // struct-type table (chunk.Program.struct_types) — never
                // owned by any one instance, so never freed here; only
                // `fields` (this instance's own values and their backing
                // slice) belongs to this object.
                for (record.fields) |v| v.decref(allocator);
                allocator.free(record.fields);
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

/// A single enum variant reference (GRAMMAR.bnf design note 3aa, ISA.bnf
/// section 20) — a plain scalar `Value`, NOT heap/refcounted: copying it is
/// as free as copying an `int`. `type_index`/`variant` are what `eql`
/// actually compares (a small integer pair, one per declared enum type/
/// variant, assigned by the compiler in declaration order); `type_name`/
/// `variant_name` are carried alongside purely so `typeName`/`printAt` can
/// render this value on their own, with no table to consult — every
/// occurrence of this same variant in a compiled program is a value-equal
/// (not just index-equal) `EnumTag`, so there is nothing to deduplicate or
/// own here, unlike `Object`.
pub const EnumTag = struct {
    type_index: u32,
    variant: u32,
    type_name: []const u8,
    variant_name: []const u8,
};

/// A reference to a top-level, named function (GRAMMAR.bnf design note
/// 3ad) — a plain scalar `Value`, exactly like `EnumTag`: no heap, no
/// refcount, copying it is as free as copying an `int`. `index` is the same
/// `Program.functions` index CALL's own operand already uses to name a
/// callee; `name` is carried alongside purely for `print`/`typeName`, never
/// looked up through it — same rationale as `EnumTag.type_name`.
pub const FunctionRef = struct {
    index: u32,
    name: []const u8,
};

pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    array_ref: ArrayRef,
    stream: Stream,
    /// JSON's `null` (ISA.bnf section 12). Carries no payload — there is
    /// exactly one null value, and copying/discarding it is as free as any
    /// other scalar.
    null_value,
    /// A named enum variant (GRAMMAR.bnf design note 3aa) — see `EnumTag`.
    enum_value: EnumTag,
    /// A reference to a top-level named function (GRAMMAR.bnf design note
    /// 3ad) — see `FunctionRef`.
    function: FunctionRef,
    object: *Object,

    /// Allocates a new heap string value: dupes `bytes` into an
    /// owner-tracked buffer and wraps it in a fresh, refcount-1 `Object`.
    /// The single choke point every Butter string value — literal or
    /// dynamic — is created through, so no code elsewhere hand-rolls the
    /// dupe+create+wrap sequence.
    pub fn newString(allocator: std.mem.Allocator, bytes: []const u8) !Value {
        const owned = try allocator.dupe(u8, bytes);
        const obj = try Object.create(allocator, .{ .string = owned });
        return .{ .object = obj };
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .int => "int",
            .float => "float",
            .boolean => "bool",
            .array_ref => "array",
            .stream => "stream",
            .null_value => "null",
            // Unlike every other case here, this isn't a fixed string — it's
            // the declared name of whichever enum type this value actually
            // is (e.g. "Color"), carried directly in the tag (see
            // `EnumTag`'s doc comment) rather than looked up anywhere.
            .enum_value => |e| e.type_name,
            .function => "function",
            .object => |o| switch (o.payload) {
                .string => "string",
                .list => "list",
                .map => "map",
                .record => |r| r.type_name,
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

    /// Returns this value's bytes if it's string-shaped — a heap
    /// `object{.string}` (ISA.bnf section 11) — or `null` otherwise.
    pub fn asStringBytes(self: Value) ?[]const u8 {
        return switch (self) {
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
            // Same type-and-variant only — comparing against a mismatched
            // enum type, or against any non-enum value, is simply `false`,
            // never a type error (GRAMMAR.bnf design note 3t: `==`/`!=` are
            // deliberately never type-checked, and enums get no special
            // carve-out from that rule).
            .enum_value => |ae| b == .enum_value and ae.type_index == b.enum_value.type_index and ae.variant == b.enum_value.variant,
            // Same function only — identified by its `Program.functions`
            // index, same as two enum values compare by type_index+variant
            // rather than by name.
            .function => |af| b == .function and af.index == b.function.index,
            .object => |ao| switch (ao.payload) {
                .string => unreachable, // asStringBytes above already handled this
                .list, .map, .record => b == .object and ao == b.object,
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
            // Bare, unquoted variant name (like `boolean` prints `true`, not
            // `"true"`) — regardless of `quoted`, since an enum value has no
            // separate "as a list/map element" rendering to distinguish
            // (GRAMMAR.bnf design note 3aa).
            .enum_value => |e| try writer.writeAll(e.variant_name),
            .function => |f| try writer.print("<func {s}>", .{f.name}),
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
                // Renders like `map` — a JSON-object shape keyed by each
                // field's declared name, in declared order (GRAMMAR.bnf
                // design note 3z) — but the keys come from the struct
                // type's own `field_names`, not per-instance storage.
                .record => |r| {
                    if (depth >= max_print_depth) return writer.writeAll("...");
                    try writer.writeAll("{");
                    for (r.field_names, r.fields, 0..) |name, v, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.print("\"{s}\": ", .{name});
                        try v.printAt(writer, depth + 1, true);
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

    const allocator = std.testing.allocator;
    const hi = try Value.newString(allocator, "hi");
    defer hi.decref(allocator);
    try expectPrint(hi, "hi");

    try expectPrint(.null_value, "null");
}

test "eql compares numerics across int/float" {
    try std.testing.expect(Value.eql(.{ .int = 1 }, .{ .float = 1.0 }));
    try std.testing.expect(!Value.eql(.{ .int = 1 }, .{ .float = 1.5 }));
}

test "eql compares same-type non-numeric values structurally" {
    const allocator = std.testing.allocator;
    const hi1 = try Value.newString(allocator, "hi");
    defer hi1.decref(allocator);
    const hi2 = try Value.newString(allocator, "hi");
    defer hi2.decref(allocator);
    const bye = try Value.newString(allocator, "bye");
    defer bye.decref(allocator);

    try std.testing.expect(Value.eql(hi1, hi2));
    try std.testing.expect(!Value.eql(hi1, bye));
    try std.testing.expect(Value.eql(.{ .boolean = true }, .{ .boolean = true }));
}

test "eql returns false (not an error) across incompatible types" {
    try std.testing.expect(!Value.eql(.{ .boolean = true }, .{ .int = 1 }));

    const allocator = std.testing.allocator;
    const one = try Value.newString(allocator, "1");
    defer one.decref(allocator);
    try std.testing.expect(!Value.eql(one, .{ .int = 1 }));
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

test "asStringBytes reads a heap string's bytes; eql compares heap strings by content" {
    const allocator = std.testing.allocator;
    const a = try Value.newString(allocator, "hi");
    defer a.decref(allocator);
    const b = try Value.newString(allocator, "hi");
    defer b.decref(allocator);

    try std.testing.expect(Value.eql(a, b));
    try std.testing.expectEqualStrings("hi", a.asStringBytes().?);
}

test "print renders a list with quoted string elements and a map as key: value pairs" {
    const allocator = std.testing.allocator;
    const list_obj = try Object.create(allocator, .{ .list = .empty });
    defer (Value{ .object = list_obj }).decref(allocator);
    try list_obj.payload.list.append(allocator, .{ .int = 1 });
    try list_obj.payload.list.append(allocator, try Value.newString(allocator, "a"));

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

test "destroying a record recursively decrefs its fields and frees the fields slice" {
    const allocator = std.testing.allocator;
    const inner = try Object.create(allocator, .{ .list = .empty });

    const field_names = [_][]const u8{ "x", "y" };
    const fields = try allocator.alloc(Value, 2);
    fields[0] = .{ .int = 1 };
    fields[1] = .{ .object = inner }; // adopts inner's +1

    const record_obj = try Object.create(allocator, .{ .record = .{
        .type_name = "Point",
        .field_names = &field_names,
        .fields = fields,
    } });
    (Value{ .object = record_obj }).decref(allocator); // frees record_obj, decrefs inner to 0, frees inner
}

test "print renders a record like a map, keyed by its declared field names" {
    const allocator = std.testing.allocator;
    const field_names = [_][]const u8{ "x", "y" };
    const fields = try allocator.alloc(Value, 2);
    fields[0] = .{ .int = 1 };
    fields[1] = try Value.newString(allocator, "a");

    const record_obj = try Object.create(allocator, .{ .record = .{
        .type_name = "Point",
        .field_names = &field_names,
        .fields = fields,
    } });
    defer (Value{ .object = record_obj }).decref(allocator);

    try expectPrint(.{ .object = record_obj }, "{\"x\": 1, \"y\": \"a\"}");
    try std.testing.expectEqualStrings("Point", (Value{ .object = record_obj }).typeName());
}

test "eql compares records by pointer identity, never deep" {
    const allocator = std.testing.allocator;
    const field_names = [_][]const u8{"x"};
    const fields_a = try allocator.alloc(Value, 1);
    fields_a[0] = .{ .int = 1 };
    const fields_b = try allocator.alloc(Value, 1);
    fields_b[0] = .{ .int = 1 };

    const a = try Object.create(allocator, .{ .record = .{ .type_name = "Point", .field_names = &field_names, .fields = fields_a } });
    defer (Value{ .object = a }).decref(allocator);
    const b = try Object.create(allocator, .{ .record = .{ .type_name = "Point", .field_names = &field_names, .fields = fields_b } });
    defer (Value{ .object = b }).decref(allocator);

    try std.testing.expect(Value.eql(.{ .object = a }, .{ .object = a }));
    try std.testing.expect(!Value.eql(.{ .object = a }, .{ .object = b }));
}

test "enum_value eql compares by type_index+variant; typeName/print use the carried names" {
    const red: Value = .{ .enum_value = .{ .type_index = 0, .variant = 0, .type_name = "Color", .variant_name = "Red" } };
    const red_again: Value = .{ .enum_value = .{ .type_index = 0, .variant = 0, .type_name = "Color", .variant_name = "Red" } };
    const green: Value = .{ .enum_value = .{ .type_index = 0, .variant = 1, .type_name = "Color", .variant_name = "Green" } };
    const other_type_zero: Value = .{ .enum_value = .{ .type_index = 1, .variant = 0, .type_name = "Size", .variant_name = "Small" } };

    try std.testing.expect(Value.eql(red, red_again));
    try std.testing.expect(!Value.eql(red, green));
    // Different enum TYPE, same numeric variant tag — still not equal, and
    // not a compile-time-relevant distinction here since eql never errors
    // across types (GRAMMAR.bnf design note 3t).
    try std.testing.expect(!Value.eql(red, other_type_zero));
    // Never equal to a bare int either, even one matching its own variant
    // tag — this is exactly the type-safety alternative B was chosen for.
    try std.testing.expect(!Value.eql(red, .{ .int = 0 }));

    try std.testing.expectEqualStrings("Color", red.typeName());
    try expectPrint(red, "Red");
}

test "function eql compares by index only; typeName/print use the carried name" {
    const square: Value = .{ .function = .{ .index = 0, .name = "square" } };
    const square_again: Value = .{ .function = .{ .index = 0, .name = "square" } };
    const double: Value = .{ .function = .{ .index = 1, .name = "double" } };

    try std.testing.expect(Value.eql(square, square_again));
    try std.testing.expect(!Value.eql(square, double));
    try std.testing.expect(!Value.eql(square, .{ .int = 0 }));

    try std.testing.expectEqualStrings("function", square.typeName());
    try expectPrint(square, "<func square>");
}
