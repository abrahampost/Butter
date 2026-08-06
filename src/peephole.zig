//! Post-codegen bytecode cleanup: two passes over an already-compiled
//! `Chunk` that clean up artifacts of CODEGEN itself, not of the source
//! program — so they live here rather than in optimizer.zig, which only
//! ever sees the AST (see that file's own doc comment on why there's no
//! separate IR stage between it and the compiler). `compileIf`/
//! `compileTry` unconditionally emit a JUMP (or POP_HANDLER+JUMP) to skip
//! past the branch/handler they just compiled — needed when that branch
//! can fall through, dead weight when it can't (it ends in
//! return/exit/throw), and the compiler has no way to know which case
//! it's in when it emits that jump. optimizer.zig's `alwaysTerminates`
//! only prunes STATEMENTS after a terminator; it has no visibility into
//! bytecode the compiler emits that isn't backed by any statement at all.
//!
//! Run in this order:
//!   1. `threadJumps`: a jump-shaped instruction whose target is itself
//!      an unconditional JUMP is retargeted straight to THAT jump's own
//!      target, so control never bounces through an intermediate jump
//!      only to jump again.
//!   2. `removeUnreachable`: floods reachability out from index 0 through
//!      fall-through edges (every non-terminator reaches the instruction
//!      right after it) and jump edges (every JUMP/JUMP_IF_FALSE/
//!      JUMP_IF_FALSE_POP/PUSH_HANDLER reaches its operand) and drops
//!      whatever the flood never touches. Threading runs first
//!      specifically so an intermediate jump left with no remaining
//!      inbound edge after retargeting is correctly unreachable here too.
//!
//! Both are pure retarget-or-delete transformations over instructions
//! already emitted — neither ever changes what the chunk computes, only
//! how much of it there is to dispatch through.

const std = @import("std");
const chunk_mod = @import("chunk.zig");

/// Runs both passes over every chunk in `program` (the main chunk and
/// every function) in place.
pub fn optimizeProgram(allocator: std.mem.Allocator, program: *chunk_mod.Program) std.mem.Allocator.Error!void {
    try optimizeChunk(allocator, &program.main);
    for (program.functions) |*f| try optimizeChunk(allocator, &f.chunk);
}

fn optimizeChunk(allocator: std.mem.Allocator, chunk: *chunk_mod.Chunk) std.mem.Allocator.Error!void {
    threadJumps(chunk);
    try removeUnreachable(allocator, chunk);
}

/// Whether `op` never falls through to the instruction textually after
/// it in the chunk — the only reason a following instruction with no
/// other inbound jump would be unreachable. EXIT halts the whole process
/// and THROW unwinds to a handler (in this chunk or an ancestor frame's);
/// either way execution never returns to resume just past them.
fn isTerminator(op: chunk_mod.OpCode) bool {
    return switch (op) {
        .jump, .ret, .halt, .exit, .throw => true,
        else => false,
    };
}

/// Whether `op`'s operand is a code offset into this SAME chunk — the
/// only three opcodes where it is (mirrors chunk.zig's own
/// `disassemble`, which renders exactly these three as `-> {d}`).
fn isCodeOffset(op: chunk_mod.OpCode) bool {
    return switch (op) {
        .jump, .jump_if_false, .jump_if_false_pop, .push_handler => true,
        else => false,
    };
}

/// Retargets every jump-shaped instruction through a chain of
/// unconditional JUMPs to land on that chain's final destination.
/// Bounded by the chunk's own length so a jump cycle — never actually
/// produced by the compiler today, but not worth trusting blindly —
/// can't loop forever; it simply stops at whatever target it last saw,
/// which is always still a correct (if not maximally threaded) target.
fn threadJumps(chunk: *chunk_mod.Chunk) void {
    const len = chunk.code.items.len;
    for (chunk.code.items) |*instr| {
        if (!isCodeOffset(instr.op)) continue;
        var target = instr.operand;
        var hops: usize = 0;
        while (target < len and chunk.code.items[target].op == .jump and hops < len) : (hops += 1) {
            const next = chunk.code.items[target].operand;
            if (next == target) break; // a jump targeting itself: nothing further to thread
            target = next;
        }
        instr.operand = target;
    }
}

/// Drops every instruction unreachable from index 0 (the chunk's own
/// entry point) and remaps every surviving code-offset operand to its
/// target's post-compaction index. `lines` is compacted in lockstep with
/// `code` (they're parallel arrays, one entry per instruction) so
/// line-number diagnostics stay attributed to the right source line.
///
/// Reachability is a proper fixpoint over the whole chunk (a worklist
/// flood fill from index 0, following a fall-through edge from every
/// non-terminator and a jump edge from every code-offset operand — but
/// ONLY once the instruction itself has been reached some other way),
/// not just "does anything, live or not, happen to name this index" —
/// that distinction matters whenever the only thing naming an index turns
/// out to be dead itself (e.g. a `try` body that always returns: its
/// POP_HANDLER+JUMP past the handler is dead, per this file's module
/// doc — and a single linear pass would still treat their jump TARGET as
/// live purely for being named, even though the one thing naming it
/// never runs either).
fn removeUnreachable(allocator: std.mem.Allocator, chunk: *chunk_mod.Chunk) std.mem.Allocator.Error!void {
    const len = chunk.code.items.len;
    if (len == 0) return;

    const alive = try allocator.alloc(bool, len);
    defer allocator.free(alive);
    @memset(alive, false);

    var worklist: std.ArrayList(u32) = .empty;
    defer worklist.deinit(allocator);
    alive[0] = true;
    try worklist.append(allocator, 0);

    while (worklist.pop()) |i| {
        const instr = chunk.code.items[i];
        if (isCodeOffset(instr.op)) {
            std.debug.assert(instr.operand < len);
            if (!alive[instr.operand]) {
                alive[instr.operand] = true;
                try worklist.append(allocator, instr.operand);
            }
        }
        if (!isTerminator(instr.op) and i + 1 < len and !alive[i + 1]) {
            alive[i + 1] = true;
            try worklist.append(allocator, @intCast(i + 1));
        }
    }

    // old index -> new index; only ever read back for indices `alive`
    // marked true, so every lookup below lands on a slot this loop
    // actually wrote.
    const remap = try allocator.alloc(u32, len);
    defer allocator.free(remap);
    var write: usize = 0;
    for (0..len) |i| {
        if (!alive[i]) continue;
        remap[i] = @intCast(write);
        chunk.code.items[write] = chunk.code.items[i];
        chunk.lines.items[write] = chunk.lines.items[i];
        write += 1;
    }
    chunk.code.items.len = write;
    chunk.lines.items.len = write;

    for (chunk.code.items) |*instr| {
        if (isCodeOffset(instr.op)) instr.operand = remap[instr.operand];
    }
}

// ---- Tests -----------------------------------------------------------------

const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const optimizer_mod = @import("optimizer.zig");
const compiler_mod = @import("compiler.zig");
const vm_mod = @import("vm.zig");

/// Lexes, parses, AST-optimizes, compiles, peephole-optimizes, and runs
/// `source` end to end, returning whatever it printed and the compiled
/// program (so a test can also inspect its disassembly).
fn runPeepholed(allocator: std.mem.Allocator, source: []const u8, buf: []u8) !struct { output: []const u8, compiled: chunk_mod.Program } {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try optimizer_mod.optimizeProgram(allocator, try parser.parseProgram());

    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileProgram(program);
    try optimizeProgram(allocator, &compiled);

    var vm = vm_mod.Vm.init(allocator);
    var writer = std.Io.Writer.fixed(buf);
    try vm.run(&compiled, .{ .out = &writer });
    return .{ .output = writer.buffered(), .compiled = compiled };
}

fn disassembleToBuf(compiled: *chunk_mod.Program, buf: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try compiled.disassemble(&writer);
    return writer.buffered();
}

test "threadJumps retargets a jump_if_false_pop through an intermediate unconditional jump" {
    const allocator = std.testing.allocator;
    var chunk: chunk_mod.Chunk = .{};
    defer chunk.deinit(allocator);

    // 0: jump_if_false_pop -> 1     (points at the jump right below it)
    // 1: jump -> 3                  (the intermediate hop)
    // 2: halt                       (dead, but irrelevant to this test)
    // 3: halt                       (the real final destination)
    const branch = try chunk.emitWithOperand(allocator, .jump_if_false_pop, 1);
    _ = try chunk.emitWithOperand(allocator, .jump, 3);
    _ = try chunk.emit(allocator, .halt);
    _ = try chunk.emit(allocator, .halt);

    threadJumps(&chunk);
    try std.testing.expectEqual(@as(u32, 3), chunk.code.items[branch].operand);
}

test "threadJumps leaves a jump targeting itself alone rather than looping" {
    const allocator = std.testing.allocator;
    var chunk: chunk_mod.Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emitWithOperand(allocator, .jump, 0); // targets itself

    threadJumps(&chunk);
    try std.testing.expectEqual(@as(u32, 0), chunk.code.items[0].operand);
}

test "removeUnreachable drops dead code after an unconditional jump and remaps surviving targets" {
    const allocator = std.testing.allocator;
    var chunk: chunk_mod.Chunk = .{};
    defer chunk.deinit(allocator);

    // 0: jump -> 3      (unconditional; nothing after it can fall through)
    // 1: push_true      (dead — no fallthrough, no inbound jump)
    // 2: pop            (dead likewise)
    // 3: halt           (the live jump target)
    _ = try chunk.emitWithOperand(allocator, .jump, 3);
    _ = try chunk.emit(allocator, .push_true);
    _ = try chunk.emit(allocator, .pop);
    _ = try chunk.emit(allocator, .halt);

    try removeUnreachable(allocator, &chunk);

    try std.testing.expectEqual(@as(usize, 2), chunk.code.items.len);
    try std.testing.expectEqual(chunk_mod.OpCode.jump, chunk.code.items[0].op);
    try std.testing.expectEqual(@as(u32, 1), chunk.code.items[0].operand); // remapped 3 -> 1
    try std.testing.expectEqual(chunk_mod.OpCode.halt, chunk.code.items[1].op);
}

test "removeUnreachable keeps code that is only reachable via a jump target, not fallthrough" {
    const allocator = std.testing.allocator;
    var chunk: chunk_mod.Chunk = .{};
    defer chunk.deinit(allocator);

    // 0: jump -> 2
    // 1: halt      (dead — unreachable)
    // 2: push_true (the jump's target, live despite no fallthrough reaching it)
    // 3: halt
    _ = try chunk.emitWithOperand(allocator, .jump, 2);
    _ = try chunk.emit(allocator, .halt);
    _ = try chunk.emit(allocator, .push_true);
    _ = try chunk.emit(allocator, .halt);

    try removeUnreachable(allocator, &chunk);

    try std.testing.expectEqual(@as(usize, 3), chunk.code.items.len);
    try std.testing.expectEqual(chunk_mod.OpCode.push_true, chunk.code.items[1].op);
}

test "end to end: an if where both branches always return drops the dead skip-jump" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;

    var result = try runPeepholed(allocator,
        \\func f(int x) -> int {
        \\  if x > 0 {
        \\    return 1
        \\  } else {
        \\    return 2
        \\  }
        \\}
        \\print f(5)
        \\print f(-5)
        \\
    , &buf);
    defer result.compiled.deinit(allocator);
    try std.testing.expectEqualStrings("1\n2\n", result.output);

    var disasm_buf: [1024]u8 = undefined;
    const disasm = try disassembleToBuf(&result.compiled, &disasm_buf);
    // Only the return in each branch should reach RET — no unconditional
    // JUMP left over between them now that neither branch falls through.
    // (Searches for the exact opcode name, not just "jump", since
    // JUMP_IF_FALSE_POP — still legitimately present for the condition
    // itself — contains "jump" as a substring too.)
    try std.testing.expect(std.mem.indexOf(u8, disasm, "jump -> ") == null);
}

test "end to end: a try body that always returns drops the dead pop_handler+jump" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;

    var result = try runPeepholed(allocator,
        \\func f() -> int {
        \\  try {
        \\    return 1
        \\  } catch e {
        \\    return 2
        \\  }
        \\  return 3
        \\}
        \\print f()
        \\
    , &buf);
    defer result.compiled.deinit(allocator);
    try std.testing.expectEqualStrings("1\n", result.output);

    var disasm_buf: [1024]u8 = undefined;
    const disasm = try disassembleToBuf(&result.compiled, &disasm_buf);
    try std.testing.expect(std.mem.indexOf(u8, disasm, "pop_handler") == null);
}

test "end to end: output matches the unoptimized bytecode for a battery of branches and loops" {
    const allocator = std.testing.allocator;
    const source =
        \\func classify(int x) -> int {
        \\  if x > 0 {
        \\    return 1
        \\  } else {
        \\    if x < 0 {
        \\      return -1
        \\    } else {
        \\      return 0
        \\    }
        \\  }
        \\}
        \\int total := 0
        \\for i in -2..3 {
        \\  total := total + classify(i)
        \\}
        \\print total
        \\try {
        \\  print classify(5)
        \\} catch e {
        \\  print -99
        \\}
        \\
    ;

    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var unopt_parser = parser_mod.Parser.init(allocator, tokens);
    defer unopt_parser.deinit();
    const unopt_program = try unopt_parser.parseProgram();
    var unopt_compiled = try compiler_mod.compile(allocator, unopt_program);
    defer unopt_compiled.deinit(allocator);
    var unopt_buf: [256]u8 = undefined;
    var unopt_writer = std.Io.Writer.fixed(&unopt_buf);
    var unopt_vm = vm_mod.Vm.init(allocator);
    try unopt_vm.run(&unopt_compiled, .{ .out = &unopt_writer });

    var buf: [256]u8 = undefined;
    var result = try runPeepholed(allocator, source, &buf);
    defer result.compiled.deinit(allocator);

    try std.testing.expectEqualStrings(unopt_writer.buffered(), result.output);
}
