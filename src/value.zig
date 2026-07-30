//! Runtime value representation for the Butter VM (ISA.bnf, section 2).
//!
//! Every value is either a plain scalar, a string slice borrowed from a
//! Chunk's constant pool, or an `array_ref` — a reference to a generic
//! (unsized) array parameter's underlying slots, still living somewhere
//! else on the VM's own value stack (ISA.bnf section 6's generic-array
//! addendum), never on a heap. Butter has no string concatenation and no
//! growable/heap-allocated collections, so no `Value` a running program
//! can produce is ever heap-allocated at run time: there is nothing here
//! for a garbage collector to do.

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
/// frame's `bp` the referenced array actually lives in) where the
/// referenced array's first element lives, and `len` is its length. This
/// is the only reference-like value in the language; it is never
/// null/dangling by construction — see the compiler's escape rule
/// (`compiler.zig`'s generic-array-return handling) for why a reference
/// can never outlive the frame it points into.
pub const ArrayRef = struct { base: u32, len: u32 };

pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    array_ref: ArrayRef,
    stream: Stream,

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .int => "int",
            .float => "float",
            .boolean => "bool",
            .string => "string",
            .array_ref => "array",
            .stream => "stream",
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

    /// Structural equality, defined for every pair of value types: numeric
    /// values compare across int/float by value, and any other mismatched
    /// pair of types simply compares unequal rather than erroring (as
    /// `==` behaves in most dynamically-checked languages).
    pub fn eql(a: Value, b: Value) bool {
        if (a.isNumeric() and b.isNumeric()) {
            if (a == .int and b == .int) return a.int == b.int;
            return a.asFloat() == b.asFloat();
        }
        return switch (a) {
            .int, .float => false, // one operand numeric, the other not
            .boolean => |av| b == .boolean and av == b.boolean,
            .string => |av| b == .string and std.mem.eql(u8, av, b.string),
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
        };
    }

    pub fn print(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .boolean => |v| try writer.print("{}", .{v}),
            .string => |v| try writer.writeAll(v),
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
