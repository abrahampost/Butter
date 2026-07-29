//! The Butter VM's execution loop. See ISA.bnf for the instruction
//! semantics this implements.

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const value_mod = @import("value.zig");
const Chunk = chunk_mod.Chunk;
const Value = value_mod.Value;

pub const RuntimeError = error{
    StackOverflow,
    StackUnderflow,
    CallStackOverflow,
    TypeMismatch,
    DivisionByZero,
    Overflow,
    IndexOutOfBounds,
};

const stack_max = 1024;
const frames_max = 256;

/// One suspended caller: everything needed to resume it after the callee
/// returns (ISA.bnf section 6). `bp` here is the CALLER's own base
/// pointer, restored on return — not the callee's.
const Frame = struct {
    chunk: *const Chunk,
    ip: usize,
    bp: usize,
};

/// No allocator is needed at run time (section 2 of ISA.bnf): the stack is
/// a fixed-size array of value-type `Value`s, and strings are borrowed, not
/// owned, so there is nothing to free.
pub const Vm = struct {
    stack: [stack_max]Value = undefined,
    sp: usize = 0,

    pub fn init() Vm {
        return .{};
    }

    fn push(self: *Vm, value: Value) RuntimeError!void {
        if (self.sp >= stack_max) return RuntimeError.StackOverflow;
        self.stack[self.sp] = value;
        self.sp += 1;
    }

    fn pop(self: *Vm) RuntimeError!Value {
        if (self.sp == 0) return RuntimeError.StackUnderflow;
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn peek(self: *const Vm, distance: usize) RuntimeError!Value {
        if (self.sp <= distance) return RuntimeError.StackUnderflow;
        return self.stack[self.sp - 1 - distance];
    }

    const Pair = struct { a: Value, b: Value };

    fn popNumericPair(self: *Vm) RuntimeError!Pair {
        const b = try self.pop();
        const a = try self.pop();
        if (!a.isNumeric() or !b.isNumeric()) return RuntimeError.TypeMismatch;
        return .{ .a = a, .b = b };
    }

    fn checkedAdd(x: i64, y: i64) RuntimeError!i64 {
        const result, const overflow = @addWithOverflow(x, y);
        if (overflow != 0) return RuntimeError.Overflow;
        return result;
    }

    fn checkedSub(x: i64, y: i64) RuntimeError!i64 {
        const result, const overflow = @subWithOverflow(x, y);
        if (overflow != 0) return RuntimeError.Overflow;
        return result;
    }

    fn checkedMul(x: i64, y: i64) RuntimeError!i64 {
        const result, const overflow = @mulWithOverflow(x, y);
        if (overflow != 0) return RuntimeError.Overflow;
        return result;
    }

    fn add(self: *Vm) RuntimeError!void {
        const p = try self.popNumericPair();
        if (p.a == .int and p.b == .int) {
            try self.push(.{ .int = try checkedAdd(p.a.int, p.b.int) });
        } else {
            try self.push(.{ .float = p.a.asFloat() + p.b.asFloat() });
        }
    }

    fn sub(self: *Vm) RuntimeError!void {
        const p = try self.popNumericPair();
        if (p.a == .int and p.b == .int) {
            try self.push(.{ .int = try checkedSub(p.a.int, p.b.int) });
        } else {
            try self.push(.{ .float = p.a.asFloat() - p.b.asFloat() });
        }
    }

    fn mul(self: *Vm) RuntimeError!void {
        const p = try self.popNumericPair();
        if (p.a == .int and p.b == .int) {
            try self.push(.{ .int = try checkedMul(p.a.int, p.b.int) });
        } else {
            try self.push(.{ .float = p.a.asFloat() * p.b.asFloat() });
        }
    }

    fn div(self: *Vm) RuntimeError!void {
        const p = try self.popNumericPair();
        if (p.a == .int and p.b == .int) {
            if (p.b.int == 0) return RuntimeError.DivisionByZero;
            if (p.a.int == std.math.minInt(i64) and p.b.int == -1) return RuntimeError.Overflow;
            try self.push(.{ .int = @divTrunc(p.a.int, p.b.int) });
        } else {
            try self.push(.{ .float = p.a.asFloat() / p.b.asFloat() });
        }
    }

    fn mod(self: *Vm) RuntimeError!void {
        const p = try self.popNumericPair();
        if (p.a == .int and p.b == .int) {
            if (p.b.int == 0) return RuntimeError.DivisionByZero;
            try self.push(.{ .int = @rem(p.a.int, p.b.int) });
        } else {
            try self.push(.{ .float = @mod(p.a.asFloat(), p.b.asFloat()) });
        }
    }

    fn pow(self: *Vm) RuntimeError!void {
        const p = try self.popNumericPair();
        if (p.a == .int and p.b == .int and p.b.int >= 0) {
            const result = std.math.powi(i64, p.a.int, p.b.int) catch return RuntimeError.Overflow;
            try self.push(.{ .int = result });
        } else {
            try self.push(.{ .float = std.math.pow(f64, p.a.asFloat(), p.b.asFloat()) });
        }
    }

    const CompareOp = enum { lt, lte, gt, gte };

    fn compare(self: *Vm, comptime op: CompareOp) RuntimeError!void {
        const p = try self.popNumericPair();
        const result = if (p.a == .int and p.b == .int) switch (op) {
            .lt => p.a.int < p.b.int,
            .lte => p.a.int <= p.b.int,
            .gt => p.a.int > p.b.int,
            .gte => p.a.int >= p.b.int,
        } else switch (op) {
            .lt => p.a.asFloat() < p.b.asFloat(),
            .lte => p.a.asFloat() <= p.b.asFloat(),
            .gt => p.a.asFloat() > p.b.asFloat(),
            .gte => p.a.asFloat() >= p.b.asFloat(),
        };
        try self.push(.{ .boolean = result });
    }

    /// Runs `program`'s main chunk from instruction 0 until HALT, entering
    /// and returning from function chunks along the way as CALL/RET
    /// instructions execute. `writer` receives whatever PRINT instructions
    /// write (dependency-injected so tests can capture output instead of it
    /// going to a real stdout).
    pub fn run(self: *Vm, program: *const chunk_mod.Program, writer: *std.Io.Writer) !void {
        var frames: [frames_max]Frame = undefined;
        var frame_count: usize = 0;

        var chunk: *const Chunk = &program.main;
        var ip: usize = 0;
        var bp: usize = 0;

        while (true) {
            const instr = chunk.code.items[ip];
            ip += 1;
            switch (instr.op) {
                .push_const => try self.push(chunk.constants.items[instr.operand]),
                .push_true => try self.push(.{ .boolean = true }),
                .push_false => try self.push(.{ .boolean = false }),
                .pop => _ = try self.pop(),

                .load_local => try self.push(self.stack[bp + instr.operand]),
                .store_local => self.stack[bp + instr.operand] = try self.peek(0),

                .load_index => {
                    const idx_val = try self.pop();
                    if (idx_val != .int) return RuntimeError.TypeMismatch;
                    const idx = chunk_mod.unpackIndexOperand(instr.operand);
                    if (idx_val.int < 0 or idx_val.int >= idx.length) return RuntimeError.IndexOutOfBounds;
                    try self.push(self.stack[bp + idx.slot + @as(usize, @intCast(idx_val.int))]);
                },
                .store_index => {
                    const v = try self.pop();
                    const idx_val = try self.pop();
                    if (idx_val != .int) return RuntimeError.TypeMismatch;
                    const idx = chunk_mod.unpackIndexOperand(instr.operand);
                    if (idx_val.int < 0 or idx_val.int >= idx.length) return RuntimeError.IndexOutOfBounds;
                    self.stack[bp + idx.slot + @as(usize, @intCast(idx_val.int))] = v;
                    try self.push(v);
                },

                .add => try self.add(),
                .sub => try self.sub(),
                .mul => try self.mul(),
                .div => try self.div(),
                .mod => try self.mod(),
                .pow => try self.pow(),

                .neg => {
                    const v = try self.pop();
                    switch (v) {
                        .int => |x| try self.push(.{ .int = -x }),
                        .float => |x| try self.push(.{ .float = -x }),
                        else => return RuntimeError.TypeMismatch,
                    }
                },
                .not => {
                    const v = try self.pop();
                    if (v != .boolean) return RuntimeError.TypeMismatch;
                    try self.push(.{ .boolean = !v.boolean });
                },

                .eq => {
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(.{ .boolean = Value.eql(a, b) });
                },
                .neq => {
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(.{ .boolean = !Value.eql(a, b) });
                },
                .lt => try self.compare(.lt),
                .lte => try self.compare(.lte),
                .gt => try self.compare(.gt),
                .gte => try self.compare(.gte),

                .jump => ip = instr.operand,
                .jump_if_false => {
                    const cond = try self.peek(0);
                    if (cond != .boolean) return RuntimeError.TypeMismatch;
                    if (!cond.boolean) ip = instr.operand;
                },

                .call => {
                    if (frame_count >= frames_max) return RuntimeError.CallStackOverflow;
                    const func = &program.functions[instr.operand];
                    frames[frame_count] = .{ .chunk = chunk, .ip = ip, .bp = bp };
                    frame_count += 1;
                    bp = self.sp - func.arity;
                    chunk = &func.chunk;
                    ip = 0;
                },
                .ret => {
                    const result = try self.pop();
                    frame_count -= 1;
                    const frame = frames[frame_count];
                    self.sp = bp;
                    try self.push(result);
                    chunk = frame.chunk;
                    ip = frame.ip;
                    bp = frame.bp;
                },

                .print => {
                    const v = try self.pop();
                    try v.print(writer);
                    try writer.writeAll("\n");
                },

                .halt => return,
            }
        }
    }
};

fn runSource(chunk: *const Chunk, buf: []u8) !usize {
    var vm = Vm.init();
    var writer = std.Io.Writer.fixed(buf);
    const program = chunk_mod.Program{ .main = chunk.*, .functions = &.{} };
    try vm.run(&program, &writer);
    return writer.end;
}

fn expectRuntimeError(chunk: *const Chunk, expected: RuntimeError) !void {
    var vm = Vm.init();
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const program = chunk_mod.Program{ .main = chunk.*, .functions = &.{} };
    try std.testing.expectError(expected, vm.run(&program, &writer));
}

test "push and pop basic arithmetic: 2 + 3 -> prints 5" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const two = try chunk.addConstant(allocator, .{ .int = 2 });
    const three = try chunk.addConstant(allocator, .{ .int = 3 });
    _ = try chunk.emitWithOperand(allocator, .push_const, two);
    _ = try chunk.emitWithOperand(allocator, .push_const, three);
    _ = try chunk.emit(allocator, .add);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("5\n", buf[0..len]);
}

test "int + float promotes to float" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const half = try chunk.addConstant(allocator, .{ .float = 0.5 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .push_const, half);
    _ = try chunk.emit(allocator, .add);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("1.5\n", buf[0..len]);
}

test "division by zero is a runtime error, not a trap" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try chunk.emit(allocator, .div);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.DivisionByZero);
}

test "integer overflow is a runtime error, not undefined behavior" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const max = try chunk.addConstant(allocator, .{ .int = std.math.maxInt(i64) });
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, max);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .add);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.Overflow);
}

test "adding a bool to an int is a type mismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emit(allocator, .push_true);
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .add);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "popping an empty stack is a stack underflow" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);
    _ = try chunk.emit(allocator, .pop);

    try expectRuntimeError(&chunk, RuntimeError.StackUnderflow);
}

test "pushing past capacity is a stack overflow" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    var i: usize = 0;
    while (i <= stack_max) : (i += 1) _ = try chunk.emitWithOperand(allocator, .push_const, one);

    try expectRuntimeError(&chunk, RuntimeError.StackOverflow);
}

test "load_local and store_local address the stack directly" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const seven = try chunk.addConstant(allocator, .{ .int = 7 });
    const nine = try chunk.addConstant(allocator, .{ .int = 9 });
    _ = try chunk.emitWithOperand(allocator, .push_const, seven); // slot 0
    _ = try chunk.emitWithOperand(allocator, .push_const, nine);
    _ = try chunk.emitWithOperand(allocator, .store_local, 0); // slot 0 := 9 (peeks)
    _ = try chunk.emit(allocator, .pop); // discard store's peeked value
    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("9\n", buf[0..len]);
}

test "jump skips the instructions in between" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const two = try chunk.addConstant(allocator, .{ .int = 2 });
    _ = try chunk.emitWithOperand(allocator, .jump, 3);
    _ = try chunk.emitWithOperand(allocator, .push_const, one); // skipped
    _ = try chunk.emit(allocator, .print); // skipped
    _ = try chunk.emitWithOperand(allocator, .push_const, two);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("2\n", buf[0..len]);
}

test "jump_if_false branches on a false condition without consuming it" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emit(allocator, .push_false);
    const jump = try chunk.emitWithOperand(allocator, .jump_if_false, 0);
    _ = try chunk.emit(allocator, .print); // skipped: would print `false`
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .print); // prints the still-on-stack `false`
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("false\n", buf[0..len]);
}

test "jump_if_false requires a boolean condition" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .jump_if_false, 0);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "a tiny loop counts from 0 to 3" {
    // Hand-assembled equivalent of:
    //   int i := 0
    //   while i < 3 { print i  i := i + 1 }
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    const three = try chunk.addConstant(allocator, .{ .int = 3 });
    const one = try chunk.addConstant(allocator, .{ .int = 1 });

    _ = try chunk.emitWithOperand(allocator, .push_const, zero); // slot 0 = i

    const loop_start = chunk.code.items.len;
    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, three);
    _ = try chunk.emit(allocator, .lt);
    const exit_jump = try chunk.emitWithOperand(allocator, .jump_if_false, 0);
    _ = try chunk.emit(allocator, .pop);

    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emit(allocator, .print);

    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .add);
    _ = try chunk.emitWithOperand(allocator, .store_local, 0);
    _ = try chunk.emit(allocator, .pop);

    _ = try chunk.emitWithOperand(allocator, .jump, @intCast(loop_start));
    chunk.patchOperand(exit_jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .pop);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("0\n1\n2\n", buf[0..len]);
}

test "call and ret: a function computes double its argument" {
    // Hand-assembled equivalent of:
    //   func double(int n) -> int { return n + n }
    //   print double(21)
    const allocator = std.testing.allocator;

    var func_chunk: Chunk = .{};
    _ = try func_chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try func_chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try func_chunk.emit(allocator, .add);
    _ = try func_chunk.emit(allocator, .ret);

    var main_chunk: Chunk = .{};
    const twenty_one = try main_chunk.addConstant(allocator, .{ .int = 21 });
    _ = try main_chunk.emitWithOperand(allocator, .push_const, twenty_one);
    _ = try main_chunk.emitWithOperand(allocator, .call, 0);
    _ = try main_chunk.emit(allocator, .print);
    _ = try main_chunk.emit(allocator, .halt);

    var functions: std.ArrayList(chunk_mod.Function) = .empty;
    try functions.append(allocator, .{ .name = "double", .arity = 1, .chunk = func_chunk });
    var program = chunk_mod.Program{ .main = main_chunk, .functions = try functions.toOwnedSlice(allocator) };
    defer program.deinit(allocator);

    var vm = Vm.init();
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&program, &writer);
    try std.testing.expectEqualStrings("42\n", writer.buffered());
}

test "recursive calls each get their own frame" {
    // Hand-assembled equivalent of:
    //   func sum(int n) -> int {
    //       if n == 0 { return 0 }
    //       return n + sum(n - 1)
    //   }
    //   print sum(3)   -- 3 + 2 + 1 + 0 = 6
    //
    // This is the key proof that recursion works at all: slot 0 must
    // resolve to *this call's* n, not get clobbered by the n of whichever
    // nested sum(n - 1) call is currently active on the same stack.
    const allocator = std.testing.allocator;

    var func_chunk: Chunk = .{};
    const zero = try func_chunk.addConstant(allocator, .{ .int = 0 });
    const one = try func_chunk.addConstant(allocator, .{ .int = 1 });

    _ = try func_chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try func_chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try func_chunk.emit(allocator, .eq);
    const else_jump = try func_chunk.emitWithOperand(allocator, .jump_if_false, 0);
    _ = try func_chunk.emit(allocator, .pop);
    _ = try func_chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try func_chunk.emit(allocator, .ret);
    func_chunk.patchOperand(else_jump, @intCast(func_chunk.code.items.len));
    _ = try func_chunk.emit(allocator, .pop);
    _ = try func_chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try func_chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try func_chunk.emitWithOperand(allocator, .push_const, one);
    _ = try func_chunk.emit(allocator, .sub);
    _ = try func_chunk.emitWithOperand(allocator, .call, 0); // recurse: sum(n - 1)
    _ = try func_chunk.emit(allocator, .add);
    _ = try func_chunk.emit(allocator, .ret);

    var main_chunk: Chunk = .{};
    const three = try main_chunk.addConstant(allocator, .{ .int = 3 });
    _ = try main_chunk.emitWithOperand(allocator, .push_const, three);
    _ = try main_chunk.emitWithOperand(allocator, .call, 0);
    _ = try main_chunk.emit(allocator, .print);
    _ = try main_chunk.emit(allocator, .halt);

    var functions: std.ArrayList(chunk_mod.Function) = .empty;
    try functions.append(allocator, .{ .name = "sum", .arity = 1, .chunk = func_chunk });
    var program = chunk_mod.Program{ .main = main_chunk, .functions = try functions.toOwnedSlice(allocator) };
    defer program.deinit(allocator);

    var vm = Vm.init();
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&program, &writer);
    try std.testing.expectEqualStrings("6\n", writer.buffered());
}

test "unbounded recursion is a call stack overflow, not a crash" {
    const allocator = std.testing.allocator;

    var func_chunk: Chunk = .{};
    const zero = try func_chunk.addConstant(allocator, .{ .int = 0 });
    _ = try func_chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try func_chunk.emitWithOperand(allocator, .call, 0); // calls itself unconditionally
    _ = try func_chunk.emit(allocator, .ret);

    var main_chunk: Chunk = .{};
    const zero_main = try main_chunk.addConstant(allocator, .{ .int = 0 });
    _ = try main_chunk.emitWithOperand(allocator, .push_const, zero_main);
    _ = try main_chunk.emitWithOperand(allocator, .call, 0);
    _ = try main_chunk.emit(allocator, .halt);

    var functions: std.ArrayList(chunk_mod.Function) = .empty;
    try functions.append(allocator, .{ .name = "loop", .arity = 1, .chunk = func_chunk });
    var program = chunk_mod.Program{ .main = main_chunk, .functions = try functions.toOwnedSlice(allocator) };
    defer program.deinit(allocator);

    var vm = Vm.init();
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(RuntimeError.CallStackOverflow, vm.run(&program, &writer));
}

test "load_index and store_index address a slot relative to the base pointer" {
    // Hand-assembled equivalent of:
    //   int[3] arr := [7, 8, 9]
    //   arr[1] := 42
    //   print arr[1]
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const seven = try chunk.addConstant(allocator, .{ .int = 7 });
    const eight = try chunk.addConstant(allocator, .{ .int = 8 });
    const nine = try chunk.addConstant(allocator, .{ .int = 9 });
    _ = try chunk.emitWithOperand(allocator, .push_const, seven); // slot 0
    _ = try chunk.emitWithOperand(allocator, .push_const, eight); // slot 1
    _ = try chunk.emitWithOperand(allocator, .push_const, nine); // slot 2

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const forty_two = try chunk.addConstant(allocator, .{ .int = 42 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one); // index
    _ = try chunk.emitWithOperand(allocator, .push_const, forty_two); // value
    _ = try chunk.emitWithOperand(allocator, .store_index, chunk_mod.packIndexOperand(0, 3));
    _ = try chunk.emit(allocator, .pop); // discard store_index's peeked result

    _ = try chunk.emitWithOperand(allocator, .push_const, one); // index
    _ = try chunk.emitWithOperand(allocator, .load_index, chunk_mod.packIndexOperand(0, 3));
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("42\n", buf[0..len]);
}

test "load_index out of bounds is a runtime error, not memory corruption" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const three = try chunk.addConstant(allocator, .{ .int = 3 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one); // slot 0 (a 1-element array)
    _ = try chunk.emitWithOperand(allocator, .push_const, three); // out-of-bounds index
    _ = try chunk.emitWithOperand(allocator, .load_index, chunk_mod.packIndexOperand(0, 1));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.IndexOutOfBounds);
}

test "a negative index is a runtime error, not wraparound" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const neg_one = try chunk.addConstant(allocator, .{ .int = -1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .push_const, neg_one);
    _ = try chunk.emitWithOperand(allocator, .load_index, chunk_mod.packIndexOperand(0, 1));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.IndexOutOfBounds);
}

test "indexing with a non-integer is a type mismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .push_true);
    _ = try chunk.emitWithOperand(allocator, .load_index, chunk_mod.packIndexOperand(0, 1));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}
