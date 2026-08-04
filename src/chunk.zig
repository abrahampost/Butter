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

    // Generic (unsized) array support — a single-slot runtime reference
    // value rather than raw consecutive slots (ISA.bnf section 6's
    // generic-array addendum). `make_array_ref`'s operand packs
    // (slot, length) exactly like LOAD_INDEX/STORE_INDEX, since both are
    // compile-time constants at the point a reference is synthesized from
    // a concrete local array. The other three address a slot holding an
    // already-synthesized `Value.array_ref` — no length to pack, since the
    // whole point is that it's read from the reference at runtime instead.
    make_array_ref,
    load_index_ref,
    store_index_ref,
    load_ref_len,

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

    // Error handling (ISA.bnf section 14). PUSH_HANDLER's operand is the
    // offset of the catch block's first instruction in the CURRENT chunk;
    // everything else needed to resume there (the value-stack depth, base
    // pointer, frame count and return width) is recorded from the live
    // machine state instead, since none of it is known at compile time —
    // the same instruction can be reached with any number of frames under
    // it. POP_HANDLER takes no operand: discarding the innermost handler is
    // all "the guarded block finished without failing" has to mean.
    push_handler,
    pop_handler,

    call,
    ret,

    print,

    // The bare `args` keyword (ISA.bnf section 9's addendum). No operand:
    // the program's own argv lives on the Host passed to `Vm.run`, not the
    // chunk, since it varies per run rather than being fixed at compile
    // time the way a `stdin`/`stdout`/`stderr` PUSH_CONST is.
    push_args,

    // Byte-stream I/O (ISA.bnf section 9). All three take zero operands:
    // the stream they act on is an ordinary `Value` on the stack, pushed by
    // whatever expression named it, so the same instruction serves a
    // standard stream and an opened file alike (GRAMMAR.bnf design note
    // 3l). READ and WRITE_BYTES likewise find their buffer as an ARRAY_REF
    // already on the stack — the compiler reuses MAKE_ARRAY_REF (fixed
    // array) or LOAD_LOCAL (generic array) to put it there, exactly as a
    // generic call argument is passed.
    read,
    write,
    write_bytes,

    // Files (ISA.bnf section 10). OPEN's operand is the `ast.OpenMode` it
    // was written with — the one part of a file that IS fixed at compile
    // time, since the mode is a bare keyword. CLOSE needs no operand: like
    // the three above, it acts on whatever stream is on the stack.
    open,
    close,

    // Maps, lists, and the heap (ISA.bnf section 11). MAKE_LIST/MAKE_MAP's
    // operand is an element/pair count — the compiler already knows exactly
    // how many values it just pushed for the literal/no-initializer case.
    // INDEX_GET/INDEX_SET/INDEX_SLICE take no operand: unlike LOAD_INDEX/
    // STORE_INDEX, the container they act on is an ordinary popped `Value`
    // (so that indexing can chain — `doc["a"]["b"]` — off any expression,
    // not just a bare local), not a compile-time-known slot. LIST_PUSH/
    // MAP_HAS/MAP_DELETE/MAP_KEYS/LEN_VALUE likewise take their operand(s)
    // as ordinary popped expression results.
    make_list,
    make_map,
    index_get,
    index_set,
    // `s[a..b]` (ISA.bnf section 11's Strings addendum) — read-only, string
    // only; there is no INDEX_SLICE_SET.
    index_slice,
    list_push,
    map_has,
    map_delete,
    map_keys,
    len_value,

    // JSON (ISA.bnf section 12).
    json_parse,
    json_stringify,

    // Numeric parsing (ISA.bnf section 13, GRAMMAR.bnf design note 3r). No
    // operand: like JSON_STRINGIFY, the string to parse is an ordinary
    // popped `Value`, not a compile-time constant.
    parse_int,
    parse_float,

    // Environment variables (ISA.bnf section 15, GRAMMAR.bnf design note
    // 3v). No operand, for the same reason PUSH_ARGS has none: the
    // environment lives on the Host passed to `Vm.run`, not in the chunk.
    // The NAME to look up is an ordinary popped `Value`, so it can be
    // computed rather than written out as a literal.
    get_env,
    has_env,

    // `exit <expr>` (ISA.bnf's addendum to section 3). No operand: the
    // requested code is an ordinary popped `Value`, exactly like every
    // other opcode that acts on an expression result rather than a
    // compile-time constant.
    exit,

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
/// reference by index (PUSH_CONST's operand). Any heap-object constant
/// (a string literal, a map-literal key — see `Value.newString`) is owned
/// by its pool entry: that's one permanent reference, incref'd by PUSH_CONST
/// on every push and released only by `deinit`, below.
pub const Chunk = struct {
    code: std.ArrayList(Instruction) = .empty,
    constants: std.ArrayList(Value) = .empty,

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        for (self.constants.items) |v| v.decref(allocator);
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
                .load_local, .store_local, .load_index_ref, .store_index_ref, .load_ref_len => try writer.print(" slot={d}\n", .{instr.operand}),
                .load_index, .store_index, .make_array_ref => {
                    const idx = unpackIndexOperand(instr.operand);
                    try writer.print(" slot={d} len={d}\n", .{ idx.slot, idx.length });
                },
                .jump, .jump_if_false, .push_handler => try writer.print(" -> {d}\n", .{instr.operand}),
                .call, .make_list, .make_map => try writer.print(" #{d}\n", .{instr.operand}),
                .open => {
                    const mode: value_mod.OpenMode = @enumFromInt(instr.operand);
                    try writer.print(" {s}\n", .{mode.name()});
                },
                else => try writer.writeAll("\n"),
            }
        }
    }
};

/// One compiled function: its own self-contained `Chunk` (own instructions,
/// own constant pool — no access to any other function's or the top
/// level's, since Butter functions are not closures) plus the metadata the
/// VM needs to call it (see ISA.bnf section 6). `arity` is how many stack
/// slots CALL expects its arguments to occupy in total — not the parameter
/// count, since an array-typed parameter occupies `array_len` slots rather
/// than one — which also determines the callee's frame base pointer
/// (`sp - arity`) at call time. `return_width` is likewise how many slots
/// RET copies back to the caller (1 for a scalar return, `array_len` for an
/// array return).
pub const Function = struct {
    name: []const u8,
    arity: u32,
    return_width: u32 = 1,
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

test "the I/O instructions carry no operand — their stream comes off the stack" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emit(allocator, .read);
    _ = try chunk.emit(allocator, .write);
    _ = try chunk.emit(allocator, .write_bytes);
    _ = try chunk.emit(allocator, .close);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try chunk.disassemble(&writer);

    try std.testing.expectEqualStrings(
        "0000 read\n0001 write\n0002 write_bytes\n0003 close\n",
        writer.buffered(),
    );
}

test "disassemble names the mode an open was written with" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emitWithOperand(allocator, .open, @intFromEnum(value_mod.OpenMode.read));
    _ = try chunk.emitWithOperand(allocator, .open, @intFromEnum(value_mod.OpenMode.write));
    _ = try chunk.emitWithOperand(allocator, .open, @intFromEnum(value_mod.OpenMode.append));

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try chunk.disassemble(&writer);

    try std.testing.expectEqualStrings(
        "0000 open read\n0001 open write\n0002 open append\n",
        writer.buffered(),
    );
}

test "a stream constant renders as the stream it names" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const idx = try chunk.addConstant(allocator, .{ .stream = .ofStandard(.stdout) });
    _ = try chunk.emitWithOperand(allocator, .push_const, idx);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try chunk.disassemble(&writer);

    try std.testing.expectEqualStrings("0000 push_const #0 (<stdout>)\n", writer.buffered());
}

test "disassemble renders make_list and make_map with their element/pair count" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emitWithOperand(allocator, .make_list, 3);
    _ = try chunk.emitWithOperand(allocator, .make_map, 2);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try chunk.disassemble(&writer);

    try std.testing.expectEqualStrings(
        "0000 make_list #3\n0001 make_map #2\n",
        writer.buffered(),
    );
}

test "disassemble renders the operand-less map/list/json instructions" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .index_set);
    _ = try chunk.emit(allocator, .list_push);
    _ = try chunk.emit(allocator, .map_has);
    _ = try chunk.emit(allocator, .map_delete);
    _ = try chunk.emit(allocator, .map_keys);
    _ = try chunk.emit(allocator, .len_value);
    _ = try chunk.emit(allocator, .json_parse);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try chunk.disassemble(&writer);

    try std.testing.expectEqualStrings(
        "0000 index_get\n0001 index_set\n0002 list_push\n0003 map_has\n" ++
            "0004 map_delete\n0005 map_keys\n0006 len_value\n0007 json_parse\n",
        writer.buffered(),
    );
}

test "disassemble renders parse_int and parse_float" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emit(allocator, .parse_int);
    _ = try chunk.emit(allocator, .parse_float);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try chunk.disassemble(&writer);

    try std.testing.expectEqualStrings("0000 parse_int\n0001 parse_float\n", writer.buffered());
}

test "disassemble renders get_env and has_env" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emit(allocator, .get_env);
    _ = try chunk.emit(allocator, .has_env);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try chunk.disassemble(&writer);

    try std.testing.expectEqualStrings("0000 get_env\n0001 has_env\n", writer.buffered());
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
