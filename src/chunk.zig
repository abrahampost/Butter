//! Bytecode container for the Butter VM: the fixed-width instruction
//! encoding, the constant pool, and a disassembler. See ISA.bnf for the
//! full instruction-set reference.

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

/// One job per opcode; see ISA.bnf section 3 for exact semantics.
pub const OpCode = enum(u8) {
    push_const,
    push_true,
    push_false,
    pop,

    load_local,
    store_local,
    load_index,
    store_index,

    add,
    sub,
    mul,
    div,
    mod,
    pow,

    neg,
    not,

    eq,
    neq,
    lt,
    lte,
    gt,
    gte,

    jump,
    jump_if_false,

    call,
    ret,

    print,
    halt,
};

/// Every instruction is this same fixed shape regardless of opcode (ISA.bnf
/// section 1a) — opcodes that don't need an operand simply leave it zero.
pub const Instruction = struct {
    op: OpCode,
    operand: u32 = 0,
};

/// LOAD_INDEX/STORE_INDEX need two compile-time constants — an array's
/// base slot and its declared length (for the runtime bounds check) — but
/// Instruction has room for exactly one u32 operand (ISA.bnf section 1a).
/// Packing both into that one operand (16 bits each) keeps the "one
/// operand per instruction" shape intact rather than special-casing these
/// two opcodes; 16 bits is far more headroom than `stack_max` (vm.zig)
/// ever allows a real slot or array length to reach.
pub fn packIndexOperand(slot: u32, length: u32) u32 {
    std.debug.assert(slot <= 0xFFFF and length <= 0xFFFF);
    return (length << 16) | slot;
}

pub const IndexOperand = struct { slot: u32, length: u32 };

pub fn unpackIndexOperand(operand: u32) IndexOperand {
    return .{ .slot = operand & 0xFFFF, .length = operand >> 16 };
}

/// A compiled program: its instructions plus the pool of constants they
/// reference by index (PUSH_CONST's operand).
pub const Chunk = struct {
    code: std.ArrayList(Instruction) = .empty,
    constants: std.ArrayList(Value) = .empty,

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
    }

    pub fn emit(self: *Chunk, allocator: std.mem.Allocator, op: OpCode) !usize {
        return self.emitWithOperand(allocator, op, 0);
    }

    /// Returns the index of the emitted instruction, so callers can later
    /// `patchOperand` it (used for backpatching forward jumps).
    pub fn emitWithOperand(self: *Chunk, allocator: std.mem.Allocator, op: OpCode, operand: u32) !usize {
        const index = self.code.items.len;
        try self.code.append(allocator, .{ .op = op, .operand = operand });
        return index;
    }

    /// Returns the new constant's pool index, for use as a PUSH_CONST operand.
    pub fn addConstant(self: *Chunk, allocator: std.mem.Allocator, value: Value) !u32 {
        const index = self.constants.items.len;
        try self.constants.append(allocator, value);
        return @intCast(index);
    }

    pub fn patchOperand(self: *Chunk, index: usize, operand: u32) void {
        self.code.items[index].operand = operand;
    }

    /// Human-readable listing, one instruction per line, primarily for
    /// debugging and for making test assertions readable at a glance.
    pub fn disassemble(self: *const Chunk, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.code.items, 0..) |instr, i| {
            try writer.print("{d:0>4} {s}", .{ i, @tagName(instr.op) });
            switch (instr.op) {
                .push_const => {
                    try writer.print(" #{d} (", .{instr.operand});
                    try self.constants.items[instr.operand].print(writer);
                    try writer.writeAll(")\n");
                },
                .load_local, .store_local => try writer.print(" slot={d}\n", .{instr.operand}),
                .load_index, .store_index => {
                    const idx = unpackIndexOperand(instr.operand);
                    try writer.print(" slot={d} len={d}\n", .{ idx.slot, idx.length });
                },
                .jump, .jump_if_false => try writer.print(" -> {d}\n", .{instr.operand}),
                .call => try writer.print(" #{d}\n", .{instr.operand}),
                else => try writer.writeAll("\n"),
            }
        }
    }
};

/// One compiled function: its own self-contained `Chunk` (own instructions,
/// own constant pool — no access to any other function's or the top
/// level's, since Butter functions are not closures) plus the metadata the
/// VM needs to call it (see ISA.bnf section 6). `arity` is how many
/// arguments CALL expects on the stack, which also determines the callee's
/// frame base pointer (`sp - arity`) at call time.
pub const Function = struct {
    name: []const u8,
    arity: u32,
    chunk: Chunk,

    pub fn deinit(self: *Function, allocator: std.mem.Allocator) void {
        self.chunk.deinit(allocator);
    }
};

/// A fully compiled program: the top-level "main" chunk (executed as an
/// implicit frame 0) plus every function declared in it, indexed by the
/// operand CALL instructions use to name their target.
pub const Program = struct {
    main: Chunk = .{},
    functions: []Function = &.{},

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        self.main.deinit(allocator);
        for (self.functions) |*f| f.deinit(allocator);
        allocator.free(self.functions);
    }

    /// Disassembles the main chunk followed by every function's chunk,
    /// each under a header naming it.
    pub fn disassemble(self: *const Program, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("== main ==\n");
        try self.main.disassemble(writer);
        for (self.functions) |*f| {
            try writer.print("== {s} ==\n", .{f.name});
            try f.chunk.disassemble(writer);
        }
    }
};

test "emit records instructions in order and returns their index" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const first = try chunk.emit(allocator, .push_true);
    const second = try chunk.emit(allocator, .pop);

    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expectEqual(@as(usize, 1), second);
    try std.testing.expectEqual(OpCode.push_true, chunk.code.items[0].op);
    try std.testing.expectEqual(OpCode.pop, chunk.code.items[1].op);
}

test "patchOperand rewrites a previously emitted jump target" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const jump = try chunk.emitWithOperand(allocator, .jump, 0);
    _ = try chunk.emit(allocator, .halt);
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));

    try std.testing.expectEqual(@as(u32, 2), chunk.code.items[jump].operand);
}

test "addConstant returns sequential pool indices" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const a = try chunk.addConstant(allocator, .{ .int = 1 });
    const b = try chunk.addConstant(allocator, .{ .int = 2 });

    try std.testing.expectEqual(@as(u32, 0), a);
    try std.testing.expectEqual(@as(u32, 1), b);
}

test "disassemble renders operands appropriately for each instruction shape" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const idx = try chunk.addConstant(allocator, .{ .int = 7 });
    _ = try chunk.emitWithOperand(allocator, .push_const, idx);
    _ = try chunk.emitWithOperand(allocator, .load_local, 2);
    _ = try chunk.emitWithOperand(allocator, .jump, 0);
    _ = try chunk.emit(allocator, .add);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try chunk.disassemble(&writer);

    try std.testing.expectEqualStrings(
        "0000 push_const #0 (7)\n0001 load_local slot=2\n0002 jump -> 0\n0003 add\n",
        writer.buffered(),
    );
}

test "disassemble renders call and ret" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emitWithOperand(allocator, .call, 3);
    _ = try chunk.emit(allocator, .ret);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try chunk.disassemble(&writer);

    try std.testing.expectEqualStrings("0000 call #3\n0001 ret\n", writer.buffered());
}

test "packIndexOperand/unpackIndexOperand round-trip slot and length" {
    const packed_operand = packIndexOperand(5, 10);
    const unpacked = unpackIndexOperand(packed_operand);
    try std.testing.expectEqual(@as(u32, 5), unpacked.slot);
    try std.testing.expectEqual(@as(u32, 10), unpacked.length);
}

test "disassemble renders load_index and store_index" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emitWithOperand(allocator, .load_index, packIndexOperand(2, 5));
    _ = try chunk.emitWithOperand(allocator, .store_index, packIndexOperand(2, 5));

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try chunk.disassemble(&writer);

    try std.testing.expectEqualStrings(
        "0000 load_index slot=2 len=5\n0001 store_index slot=2 len=5\n",
        writer.buffered(),
    );
}

test "Program.deinit frees the main chunk and every function's chunk" {
    const allocator = std.testing.allocator;
    var program: Program = .{};
    _ = try program.main.emit(allocator, .halt);

    var functions: std.ArrayList(Function) = .empty;
    var fn_chunk: Chunk = .{};
    _ = try fn_chunk.emit(allocator, .ret);
    try functions.append(allocator, .{ .name = "f", .arity = 0, .chunk = fn_chunk });
    program.functions = try functions.toOwnedSlice(allocator);

    program.deinit(allocator); // must not leak (checked by std.testing.allocator)
}

test "Program.disassemble includes a header per function" {
    const allocator = std.testing.allocator;
    var program: Program = .{};
    defer program.deinit(allocator);
    _ = try program.main.emitWithOperand(allocator, .call, 0);
    _ = try program.main.emit(allocator, .halt);

    var functions: std.ArrayList(Function) = .empty;
    var fn_chunk: Chunk = .{};
    _ = try fn_chunk.emit(allocator, .ret);
    try functions.append(allocator, .{ .name = "square", .arity = 1, .chunk = fn_chunk });
    program.functions = try functions.toOwnedSlice(allocator);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try program.disassemble(&writer);

    try std.testing.expectEqualStrings(
        "== main ==\n0000 call #0\n0001 halt\n== square ==\n0000 ret\n",
        writer.buffered(),
    );
}
