//! Runtime value representation for the Butter VM (ISA.bnf, section 2).
//!
//! Every value is either a plain scalar or a string slice borrowed from a
//! Chunk's constant pool. Butter has no string concatenation and no
//! arrays/collections (GRAMMAR.bnf section 3f), so no `Value` a running
//! program can produce is ever heap-allocated at run time: there is
//! nothing here for a garbage collector to do.

const std = @import("std");

pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .int => "int",
            .float => "float",
            .boolean => "bool",
            .string => "string",
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
        };
    }

    pub fn print(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .boolean => |v| try writer.print("{}", .{v}),
            .string => |v| try writer.writeAll(v),
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
