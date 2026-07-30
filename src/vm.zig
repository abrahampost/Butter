//! The Butter VM's execution loop. See ISA.bnf for the instruction
//! semantics this implements.

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const value_mod = @import("value.zig");
const json_mod = @import("json.zig");
const Chunk = chunk_mod.Chunk;
const Value = value_mod.Value;
const Object = value_mod.Object;

pub const RuntimeError = error{
    StackOverflow,
    StackUnderflow,
    CallStackOverflow,
    TypeMismatch,
    DivisionByZero,
    Overflow,
    IndexOutOfBounds,
    /// A buffer element handed to WRITE_BYTES wasn't in 0..255, so it does
    /// not name a byte. Checked rather than silently masked to the low 8
    /// bits, in the same spirit as bounds- and overflow-checking (ISA.bnf
    /// section 3).
    ByteOutOfRange,
    StreamReadFailed,
    StreamWriteFailed,

    // Files (ISA.bnf section 10). `Vm.diagnostic` carries which file and
    // what the underlying cause was for the three that have one.
    /// `open` couldn't open the path at all — no such file, no permission,
    /// it's a directory, and so on.
    FileOpenFailed,
    /// More files open at once than the VM's fixed table holds. There is no
    /// heap to grow it with, so this is a hard limit rather than a hint.
    TooManyOpenFiles,
    /// Flushing a file's buffered writes failed, either at `close` or when
    /// the program ended.
    FileCloseFailed,
    /// Reading a stream opened only for writing, or vice versa. For a file
    /// this is genuinely a runtime property (it depends on the mode it was
    /// opened with); for a standard stream named by keyword the compiler
    /// catches it first (`CompileError.WrongStreamDirection`).
    StreamNotReadable,
    StreamNotWritable,
    /// Using a file stream whose slot is no longer open — either already
    /// `close`d, or never a valid slot. Never a dangling handle: a closed
    /// slot is cleared, so this is always a clean error.
    StreamClosed,
    /// `close stdout` and friends. The standard streams belong to whoever
    /// started the program, not to the program.
    CannotCloseStandardStream,
    /// The embedder gave the VM no filesystem access, so `open` cannot work
    /// at all (see `Host.fs`).
    FilesUnavailable,

    // Maps, lists, and JSON (ISA.bnf sections 11 and 12).
    /// Reading a map key that isn't present. No diagnostic — the bare tag
    /// says everything there is to say, same as `StreamClosed`.
    KeyNotFound,
    /// `json(...)`'s input wasn't well-formed JSON. `Vm.diagnostic` carries
    /// a fixed description, since the underlying parser's own error detail
    /// doesn't survive past `json.zig`'s simplified conversion.
    JsonParseFailed,
};

const stack_max = 1024;
const frames_max = 256;

/// How many files a program may have open at once, and how much buffering
/// each gets. Both are fixed because the VM has no allocator at run time
/// (ISA.bnf section 2) — the whole table is part of the `Vm` struct.
const max_open_files = 8;
const file_buffer_size = 512;

/// Everything outside the VM that a running program can reach (ISA.bnf
/// sections 9 and 10). Every field is injected rather than reached for
/// directly, which is what lets tests drive real I/O against in-memory
/// buffers and a temporary directory.
///
/// `out` is required because PRINT has nowhere else to go. The rest are
/// optional, and an absent one behaves exactly like the shell redirection
/// it stands in for:
///
///   - `in = null` behaves like `< /dev/null` — every `read(stdin, ...)`
///     immediately reports end of input (0 bytes) rather than failing.
///   - `err = null` behaves like `2>/dev/null` — bytes written to stderr
///     are counted as written (so `write` still returns the honest "this
///     many bytes were accepted") and then dropped.
///   - `fs = null` grants no filesystem access at all: `open` fails with
///     `RuntimeError.FilesUnavailable`. This makes file access a capability
///     the embedder hands over explicitly, rather than something every
///     `Vm` has by default.
pub const Host = struct {
    out: *std.Io.Writer,
    err: ?*std.Io.Writer = null,
    in: ?*std.Io.Reader = null,
    fs: ?Fs = null,

    /// The filesystem as the program sees it: `io` performs the operations,
    /// and `dir` is what a relative path in `open` resolves against.
    pub const Fs = struct {
        io: std.Io,
        dir: std.Io.Dir,
    };
};

/// Which file, doing what, and why it failed — the detail `RuntimeError`'s
/// bare tag can't carry. Every field is a borrowed or static string (a path
/// comes from a chunk's constant pool, a cause from `@errorName`), so this
/// needs no allocation, consistent with the rest of the VM.
pub const Diagnostic = struct {
    operation: []const u8,
    path: []const u8,
    cause: []const u8,
};

/// One entry in the VM's open-file table. `handle` holds a reader or a
/// writer but never both: a file is opened in exactly one direction, so the
/// other would only ever be an unused (and misleading) way to reach the
/// same file.
///
/// `buffer` is owned by this entry and borrowed by whichever handle is
/// active, which is why `openFile` fills the table slot in first and only
/// then points the handle at `&slot.buffer` — the handle must reference the
/// buffer's final address. That also means a `Vm` must not be moved while
/// it has files open; nothing does, since `run` operates through `*Vm`.
const OpenFile = struct {
    file: std.Io.File,
    mode: value_mod.OpenMode,
    handle: Handle,
    buffer: [file_buffer_size]u8 = undefined,

    const Handle = union(enum) {
        reading: std.Io.File.Reader,
        writing: std.Io.File.Writer,
    };
};

/// One suspended caller: everything needed to resume it after the callee
/// returns (ISA.bnf section 6). `bp` here is the CALLER's own base
/// pointer, restored on return — not the callee's. `return_width` is
/// likewise the CALLER's own return width, restored so a nested call's RET
/// doesn't clobber how many slots the outer call's eventual RET will copy.
const Frame = struct {
    chunk: *const Chunk,
    ip: usize,
    bp: usize,
    return_width: usize,
};

/// Most of a `Vm` needs no allocator at run time (section 2 of ISA.bnf): the
/// stack is a fixed-size array of value-type `Value`s, and a borrowed STRING
/// is never owned, so there is nothing to free. Maps and lists (section 11)
/// are the one exception — the VM's first and only heap-managed values — so
/// `Vm` now carries the allocator they're built from; a program that never
/// touches a map/list/`json(...)` never calls into it. Byte-stream I/O
/// doesn't change any of this: `io_buffer` is a fixed staging area for
/// translating between a Butter buffer's one-`Value`-per-byte slots and the
/// flat `[]u8` a stream reads and writes, sized so it can always hold the
/// largest buffer the value stack itself could contain.
pub const Vm = struct {
    allocator: std.mem.Allocator,
    stack: [stack_max]Value = undefined,
    sp: usize = 0,
    io_buffer: [stack_max]u8 = undefined,
    /// The open-file table a `Value.stream`'s `file` payload indexes into.
    /// A `null` slot is a free one; `close` sets a slot back to null, which
    /// is what turns "using a closed file" into `RuntimeError.StreamClosed`
    /// rather than a stale handle.
    files: [max_open_files]?OpenFile = @splat(null),
    /// Detail for the last file error raised, since a Zig error value can't
    /// carry a payload. Set only on the errors documented to have one.
    diagnostic: ?Diagnostic = null,

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{ .allocator = allocator };
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
        if (!a.isNumeric() or !b.isNumeric()) {
            // Neither operand is ever pushed back on this path, so whatever
            // heap object either one might be (e.g. `1 + doc`) needs to be
            // decreffed here rather than silently discarded — a no-op for
            // every non-`object` value.
            a.decref(self.allocator);
            b.decref(self.allocator);
            return RuntimeError.TypeMismatch;
        }
        return .{ .a = a, .b = b };
    }

    /// What bracket-indexing (INDEX_GET/INDEX_SET, ISA.bnf section 11)
    /// compiles to whenever the indexed thing isn't a bare local resolving
    /// to a fixed/generic array (that case still goes through LOAD_INDEX/
    /// STORE_INDEX unchanged) — a map/list value already sitting on the
    /// stack, produced by any expression, including another INDEX_GET
    /// (chaining, e.g. `doc["a"]["b"]`). Read-only; never mutates
    /// `container` or takes ownership of anything.
    fn indexGet(container: Value, index: Value) RuntimeError!Value {
        if (container != .object) return RuntimeError.TypeMismatch;
        switch (container.object.payload) {
            .list => |list| {
                if (index != .int) return RuntimeError.TypeMismatch;
                if (index.int < 0 or index.int >= list.items.len) return RuntimeError.IndexOutOfBounds;
                return list.items[@as(usize, @intCast(index.int))];
            },
            .map => |map| {
                const key = index.asStringBytes() orelse return RuntimeError.TypeMismatch;
                return map.get(key) orelse return RuntimeError.KeyNotFound;
            },
            // A heap STRING isn't indexable either — there is still no
            // per-character access in this language (GRAMMAR.bnf design
            // note 3n), borrowed or heap-owned alike.
            .string => return RuntimeError.TypeMismatch,
        }
    }

    /// The mutating counterpart to `indexGet`. Always inserts-or-updates for
    /// a map (never errors on a missing key, unlike a read); a list requires
    /// an in-bounds index (no auto-growing — `push` is how a list grows).
    /// Decrefs whatever value it replaces; does NOT take ownership of `value`
    /// itself (the caller still owns the incref that covers it living here).
    fn indexSet(allocator: std.mem.Allocator, container: Value, index: Value, value: Value) !void {
        if (container != .object) return RuntimeError.TypeMismatch;
        switch (container.object.payload) {
            .list => |*list| {
                if (index != .int) return RuntimeError.TypeMismatch;
                if (index.int < 0 or index.int >= list.items.len) return RuntimeError.IndexOutOfBounds;
                const slot = &list.items[@as(usize, @intCast(index.int))];
                slot.decref(allocator);
                slot.* = value;
            },
            .map => {
                const key = index.asStringBytes() orelse return RuntimeError.TypeMismatch;
                try container.object.mapSet(allocator, key, value);
            },
            .string => return RuntimeError.TypeMismatch,
        }
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

    fn failFile(self: *Vm, comptime err: RuntimeError, operation: []const u8, path: []const u8, cause: []const u8) RuntimeError {
        self.diagnostic = .{ .operation = operation, .path = path, .cause = cause };
        return err;
    }

    /// Opens `path` and records it in the first free table slot, returning
    /// the stream value naming that slot. Slots are reused after `close`, so
    /// a long-running program is limited by how many files it has open at
    /// once, not by how many it has opened in total.
    fn openFile(self: *Vm, host: Host, path: []const u8, mode: value_mod.OpenMode) RuntimeError!Value {
        const fs = host.fs orelse return self.failFile(RuntimeError.FilesUnavailable, "open", path, "this program was run without filesystem access");

        const slot = for (&self.files, 0..) |*entry, i| {
            if (entry.* == null) break i;
        } else return self.failFile(RuntimeError.TooManyOpenFiles, "open", path, "the open-file table is full");

        const file = switch (mode) {
            .read => fs.dir.openFile(fs.io, path, .{ .mode = .read_only, .allow_directory = false }),
            .write => fs.dir.createFile(fs.io, path, .{}),
            // Append keeps whatever is already there, so it must NOT go
            // through `createFile` (which truncates) unless the file is
            // genuinely absent. It also needs read access alongside write —
            // not to read the file's bytes, but because seeking to the
            // current end (below) means calling `file.stat`, which itself
            // needs read access to the file's metadata (on Windows, a
            // write-only handle can't satisfy an NtQueryInformationFile
            // call).
            .append => fs.dir.openFile(fs.io, path, .{ .mode = .read_write, .allow_directory = false }) catch |err| switch (err) {
                error.FileNotFound => fs.dir.createFile(fs.io, path, .{ .read = true }),
                else => err,
            },
        } catch |err| return self.failFile(RuntimeError.FileOpenFailed, "open", path, @errorName(err));

        // The slot has to hold the entry before the handle is built, so the
        // handle can borrow the buffer at its final address (see `OpenFile`).
        self.files[slot] = .{ .file = file, .mode = mode, .handle = undefined };
        const entry = &self.files[slot].?;
        entry.handle = switch (mode) {
            .read => .{ .reading = .init(file, fs.io, &entry.buffer) },
            .write, .append => .{ .writing = .init(file, fs.io, &entry.buffer) },
        };

        // Appending means starting at the current end rather than offset 0,
        // which is the only difference between the two writable modes.
        if (mode == .append) {
            const stat = file.stat(fs.io) catch |err| {
                self.closeSlot(fs, slot) catch {};
                return self.failFile(RuntimeError.FileOpenFailed, "open", path, @errorName(err));
            };
            entry.handle.writing.seekTo(stat.size) catch |err| {
                self.closeSlot(fs, slot) catch {};
                return self.failFile(RuntimeError.FileOpenFailed, "open", path, @errorName(err));
            };
        }

        return .{ .stream = .{ .file = @intCast(slot) } };
    }

    /// Flushes (if it was open for writing) and closes the file in `slot`,
    /// freeing the slot either way — a flush failure still closes the file
    /// and clears the slot, so a failed close can never leave the table
    /// holding a handle the program can't get rid of.
    fn closeSlot(self: *Vm, fs: Host.Fs, slot: usize) RuntimeError!void {
        const entry = &(self.files[slot] orelse return);
        var flush_error: ?[]const u8 = null;
        switch (entry.handle) {
            .writing => |*w| w.interface.flush() catch |err| {
                flush_error = @errorName(err);
            },
            .reading => {},
        }
        entry.file.close(fs.io);
        self.files[slot] = null;

        if (flush_error) |cause| {
            return self.failFile(RuntimeError.FileCloseFailed, "close", "", cause);
        }
    }

    /// Closes every still-open file, propagating the first flush failure.
    /// Called on the way out of `run` so buffered writes always reach disk
    /// even when the program didn't `close` its files itself.
    fn closeAllFiles(self: *Vm, host: Host) RuntimeError!void {
        const fs = host.fs orelse return;
        var first_error: ?RuntimeError = null;
        for (0..self.files.len) |slot| {
            self.closeSlot(fs, slot) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        if (first_error) |err| return err;
    }

    /// The reader behind a stream, or an error explaining why there isn't
    /// one. `.stdin` with no reader supplied is the one case with neither: a
    /// null result means "already at end of input" (see `Host`), which the
    /// caller turns into a 0-byte read rather than a failure.
    fn readerFor(self: *Vm, host: Host, stream: value_mod.Stream) RuntimeError!?*std.Io.Reader {
        switch (stream) {
            .standard => |standard| return switch (standard) {
                .stdin => host.in,
                .stdout, .stderr => RuntimeError.StreamNotReadable,
            },
            .file => |slot| {
                const entry = try self.fileEntry(slot);
                return switch (entry.handle) {
                    .reading => |*r| &r.interface,
                    .writing => RuntimeError.StreamNotReadable,
                };
            },
        }
    }

    /// The writer behind a stream. A null result means the bytes are to be
    /// counted and dropped — only possible for `.stderr` with no writer
    /// supplied (see `Host`).
    fn writerFor(self: *Vm, host: Host, stream: value_mod.Stream) RuntimeError!?*std.Io.Writer {
        switch (stream) {
            .standard => |standard| return switch (standard) {
                .stdout => host.out,
                .stderr => host.err,
                .stdin => RuntimeError.StreamNotWritable,
            },
            .file => |slot| {
                const entry = try self.fileEntry(slot);
                return switch (entry.handle) {
                    .writing => |*w| &w.interface,
                    .reading => RuntimeError.StreamNotWritable,
                };
            },
        }
    }

    fn fileEntry(self: *Vm, slot: u32) RuntimeError!*OpenFile {
        if (slot >= self.files.len) return RuntimeError.StreamClosed;
        return &(self.files[slot] orelse return RuntimeError.StreamClosed);
    }

    fn popStream(self: *Vm) RuntimeError!value_mod.Stream {
        const v = try self.pop();
        if (v != .stream) return RuntimeError.TypeMismatch;
        return v.stream;
    }

    /// Reads at least one byte into `dest`, returning how many — or 0, and
    /// only 0, at end of input. Deliberately a SHORT read (the same
    /// contract POSIX `read(2)` has) rather than "fill `dest` completely":
    /// an interactive program must be able to act on the line the user just
    /// typed without first waiting for enough further input to fill the
    /// whole buffer.
    fn readInto(reader: *std.Io.Reader, dest: []u8) RuntimeError!usize {
        if (dest.len == 0) return 0;

        // Anything already sitting in the reader's own buffer satisfies the
        // read immediately, with no underlying read at all.
        const ready = reader.buffered();
        if (ready.len > 0) {
            const n = @min(dest.len, ready.len);
            @memcpy(dest[0..n], ready[0..n]);
            reader.toss(n);
            return n;
        }

        // Nothing buffered, so one underlying read is needed. `readVec` may
        // return 0 without meaning end of input — it's allowed to fill the
        // reader's own buffer instead of `dest` — so a 0 sends us back to
        // the buffered case rather than being reported as EOF.
        while (true) {
            var vec: [1][]u8 = .{dest};
            const n = reader.readVec(&vec) catch |err| switch (err) {
                error.EndOfStream => return 0,
                error.ReadFailed => return RuntimeError.StreamReadFailed,
            };
            if (n > 0) return n;

            const refilled = reader.buffered();
            if (refilled.len > 0) {
                const m = @min(dest.len, refilled.len);
                @memcpy(dest[0..m], refilled[0..m]);
                reader.toss(m);
                return m;
            }
        }
    }

    /// Writes `v` in exactly the rendering PRINT uses, minus the trailing
    /// newline, and returns how many bytes that took. The count comes from
    /// a discarding pass rather than a staging buffer so that it stays
    /// exact for a value of any size — a string constant can be arbitrarily
    /// long, and `{d}` on an extreme float runs to hundreds of digits.
    ///
    /// A `null` writer is a stream the embedder didn't supply: the bytes
    /// are counted and dropped, exactly as writing to `/dev/null` would
    /// count them as written (see `Streams`).
    fn writeValue(v: Value, writer: ?*std.Io.Writer) RuntimeError!usize {
        var scratch: [64]u8 = undefined;
        var counting: std.Io.Writer.Discarding = .init(&scratch);
        v.print(&counting.writer) catch return RuntimeError.StreamWriteFailed;
        const count = counting.fullCount();

        if (writer) |w| v.print(w) catch return RuntimeError.StreamWriteFailed;
        return @intCast(count);
    }

    /// Rejects a buffer reference whose slots don't fit on the value stack.
    /// Compiled Butter code can't produce one — an array's slots all have
    /// to be on the stack for the program to have reached this instruction
    /// at all — but the VM checks rather than trusts it, the same as it does
    /// for every index. `io_buffer` is exactly `stack_max` bytes, so this
    /// single bound is also what guarantees the staging copy below stays in
    /// range without a second check of its own.
    fn checkBufferRange(ref: value_mod.ArrayRef) RuntimeError!void {
        if (@as(usize, ref.base) + ref.len > stack_max) return RuntimeError.IndexOutOfBounds;
    }

    /// Copies `len` bytes read from a stream into the buffer `ref` points
    /// at, one byte per slot as an INT — the representation a Butter
    /// program indexes with `buf[i]`. Slots past `len` are left exactly as
    /// they were, so a short read never clobbers the rest of the buffer.
    fn scatterBytes(self: *Vm, ref: value_mod.ArrayRef, len: usize) void {
        for (self.io_buffer[0..len], 0..) |byte, i| {
            self.stack[ref.base + i] = .{ .int = byte };
        }
    }

    /// The inverse of `scatterBytes`: flattens the first `len` slots of the
    /// buffer `ref` points at into `io_buffer` as raw bytes, checking each
    /// one actually names a byte.
    fn gatherBytes(self: *Vm, ref: value_mod.ArrayRef, len: usize) RuntimeError!void {
        for (0..len) |i| {
            const element = self.stack[ref.base + i];
            if (element != .int) return RuntimeError.TypeMismatch;
            if (element.int < 0 or element.int > 255) return RuntimeError.ByteOutOfRange;
            self.io_buffer[i] = @intCast(element.int);
        }
    }

    /// Decrefs every value still live on the stack, across every active
    /// frame at once (the physical stack is one flat array regardless of
    /// how many call frames are on it). Needed on the way out of `run` for
    /// the same reason `closeAllFiles` is: top-level code (frame 0) never
    /// runs a RET of its own, so without this its own locals — and any
    /// function frame still active when an error propagates — would never
    /// get decreffed at all (ISA.bnf section 11).
    fn decrefStack(self: *Vm) void {
        for (self.stack[0..self.sp]) |v| v.decref(self.allocator);
    }

    /// Runs `program`'s main chunk from instruction 0 until HALT, entering
    /// and returning from function chunks along the way as CALL/RET
    /// instructions execute. `host` supplies everything outside the VM the
    /// program can reach — the three standard streams and (optionally)
    /// filesystem access — all dependency-injected so tests can capture
    /// output, feed input, and open real files in a temporary directory
    /// without the VM ever reaching for a process-wide handle itself.
    ///
    /// Any file the program left open is closed on the way out, whether it
    /// halted normally or failed, so buffered writes are never silently
    /// lost just because the program forgot to `close`.
    pub fn run(self: *Vm, program: *const chunk_mod.Program, host: Host) !void {
        const writer = host.out;
        errdefer {
            self.closeAllFiles(host) catch {};
            self.decrefStack();
        }
        var frames: [frames_max]Frame = undefined;
        var frame_count: usize = 0;

        var chunk: *const Chunk = &program.main;
        var ip: usize = 0;
        var bp: usize = 0;
        var return_width: usize = 1;

        while (true) {
            const instr = chunk.code.items[ip];
            ip += 1;
            switch (instr.op) {
                .push_const => try self.push(chunk.constants.items[instr.operand]),
                .push_true => try self.push(.{ .boolean = true }),
                .push_false => try self.push(.{ .boolean = false }),
                .pop => {
                    const v = try self.pop();
                    v.decref(self.allocator);
                },

                .load_local => {
                    const v = self.stack[bp + instr.operand];
                    v.incref();
                    try self.push(v);
                },
                .store_local => {
                    const new_v = try self.peek(0);
                    // Incref before decref: safe even for `x := x`, where the
                    // old and new value are the same object — increffing
                    // first means it can never be freed out from under
                    // itself before the assignment finishes.
                    new_v.incref();
                    self.stack[bp + instr.operand].decref(self.allocator);
                    self.stack[bp + instr.operand] = new_v;
                },

                .load_index => {
                    const idx_val = try self.pop();
                    if (idx_val != .int) return RuntimeError.TypeMismatch;
                    const idx = chunk_mod.unpackIndexOperand(instr.operand);
                    if (idx_val.int < 0 or idx_val.int >= idx.length) return RuntimeError.IndexOutOfBounds;
                    const v = self.stack[bp + idx.slot + @as(usize, @intCast(idx_val.int))];
                    v.incref();
                    try self.push(v);
                },
                .store_index => {
                    const v = try self.pop();
                    const idx_val = try self.pop();
                    if (idx_val != .int) return RuntimeError.TypeMismatch;
                    const idx = chunk_mod.unpackIndexOperand(instr.operand);
                    if (idx_val.int < 0 or idx_val.int >= idx.length) return RuntimeError.IndexOutOfBounds;
                    v.incref();
                    self.stack[bp + idx.slot + @as(usize, @intCast(idx_val.int))].decref(self.allocator);
                    self.stack[bp + idx.slot + @as(usize, @intCast(idx_val.int))] = v;
                    try self.push(v);
                },

                .make_array_ref => {
                    const idx = chunk_mod.unpackIndexOperand(instr.operand);
                    try self.push(.{ .array_ref = .{ .base = @intCast(bp + idx.slot), .len = idx.length } });
                },
                .load_index_ref => {
                    const idx_val = try self.pop();
                    if (idx_val != .int) return RuntimeError.TypeMismatch;
                    const ref = self.stack[bp + instr.operand];
                    if (ref != .array_ref) return RuntimeError.TypeMismatch;
                    if (idx_val.int < 0 or idx_val.int >= ref.array_ref.len) return RuntimeError.IndexOutOfBounds;
                    const v = self.stack[ref.array_ref.base + @as(usize, @intCast(idx_val.int))];
                    v.incref();
                    try self.push(v);
                },
                .store_index_ref => {
                    const v = try self.pop();
                    const idx_val = try self.pop();
                    if (idx_val != .int) return RuntimeError.TypeMismatch;
                    const ref = self.stack[bp + instr.operand];
                    if (ref != .array_ref) return RuntimeError.TypeMismatch;
                    if (idx_val.int < 0 or idx_val.int >= ref.array_ref.len) return RuntimeError.IndexOutOfBounds;
                    v.incref();
                    self.stack[ref.array_ref.base + @as(usize, @intCast(idx_val.int))].decref(self.allocator);
                    self.stack[ref.array_ref.base + @as(usize, @intCast(idx_val.int))] = v;
                    try self.push(v);
                },
                .load_ref_len => {
                    const ref = self.stack[bp + instr.operand];
                    if (ref != .array_ref) return RuntimeError.TypeMismatch;
                    try self.push(.{ .int = ref.array_ref.len });
                },

                // ---- Maps, lists, and the heap (ISA.bnf section 11) ----

                .make_list => {
                    const n = instr.operand;
                    var list: std.ArrayList(Value) = .empty;
                    // A pure move: the n values already on the stack become
                    // this list's own elements, so neither an incref (moving
                    // in) nor a decref (the old stack slots, about to be
                    // discarded via sp -= n) is needed for them.
                    try list.appendSlice(self.allocator, self.stack[self.sp - n .. self.sp]);
                    self.sp -= n;
                    errdefer {
                        for (list.items) |item| item.decref(self.allocator);
                        list.deinit(self.allocator);
                    }
                    const obj = try Object.create(self.allocator, .{ .list = list });
                    try self.push(.{ .object = obj });
                },
                .make_map => {
                    const n = instr.operand;
                    const base = self.sp - 2 * n;
                    // Consumed up front: from here on, nothing in this range
                    // is still visible to the outer stack-teardown decref
                    // pass, so a failure partway through the loop below must
                    // clean up whatever it hasn't gotten to yet itself.
                    self.sp = base;
                    const obj = try Object.create(self.allocator, .{ .map = .empty });
                    errdefer (Value{ .object = obj }).decref(self.allocator);
                    var i: usize = 0;
                    errdefer {
                        while (i < n) : (i += 1) {
                            self.stack[base + 2 * i].decref(self.allocator);
                            self.stack[base + 2 * i + 1].decref(self.allocator);
                        }
                    }
                    while (i < n) : (i += 1) {
                        const key_val = self.stack[base + 2 * i];
                        const val = self.stack[base + 2 * i + 1];
                        // Defense-in-depth: the compiler only ever emits a
                        // string-literal key here (GRAMMAR.bnf design note
                        // 3m), so this can't actually fail from compiled
                        // Butter source today.
                        const key = key_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                        try obj.mapSet(self.allocator, key, val); // moves val in
                        key_val.decref(self.allocator); // the key Value itself is never retained
                    }
                    try self.push(.{ .object = obj });
                },

                .index_get => {
                    const index_val = try self.pop();
                    defer index_val.decref(self.allocator);
                    const container = try self.pop();
                    defer container.decref(self.allocator);
                    const result = try indexGet(container, index_val);
                    result.incref();
                    try self.push(result);
                },
                .index_set => {
                    const v = try self.peek(0);
                    v.incref();
                    errdefer v.decref(self.allocator); // undo if we never actually store it below
                    _ = try self.pop();
                    const index_val = try self.pop();
                    defer index_val.decref(self.allocator);
                    const container = try self.pop();
                    defer container.decref(self.allocator);
                    try indexSet(self.allocator, container, index_val, v);
                    try self.push(v);
                },

                .list_push => {
                    const v = try self.pop();
                    errdefer v.decref(self.allocator); // undo if it never ends up in the list
                    const container = try self.pop();
                    defer container.decref(self.allocator);
                    if (container != .object or container.object.payload != .list) return RuntimeError.TypeMismatch;
                    try container.object.payload.list.append(self.allocator, v); // moves v in
                    try self.push(.{ .int = @intCast(container.object.payload.list.items.len) });
                },
                .map_has => {
                    const key_val = try self.pop();
                    defer key_val.decref(self.allocator);
                    const container = try self.pop();
                    defer container.decref(self.allocator);
                    if (container != .object or container.object.payload != .map) return RuntimeError.TypeMismatch;
                    const key = key_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                    try self.push(.{ .boolean = container.object.mapGet(key) != null });
                },
                .map_delete => {
                    const key_val = try self.pop();
                    defer key_val.decref(self.allocator);
                    const container = try self.pop();
                    defer container.decref(self.allocator);
                    if (container != .object or container.object.payload != .map) return RuntimeError.TypeMismatch;
                    const key = key_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                    try self.push(.{ .boolean = container.object.mapDelete(self.allocator, key) });
                },
                .map_keys => {
                    const container = try self.pop();
                    defer container.decref(self.allocator);
                    if (container != .object or container.object.payload != .map) return RuntimeError.TypeMismatch;
                    var list: std.ArrayList(Value) = .empty;
                    errdefer {
                        for (list.items) |item| item.decref(self.allocator);
                        list.deinit(self.allocator);
                    }
                    var it = container.object.payload.map.iterator();
                    while (it.next()) |entry| {
                        // Always a fresh copy — never a slice into the map's
                        // own storage — so the returned list's lifetime is
                        // fully independent of the map it came from.
                        const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                        const key_obj = try Object.create(self.allocator, .{ .string = key_copy });
                        try list.append(self.allocator, .{ .object = key_obj });
                    }
                    const result_obj = try Object.create(self.allocator, .{ .list = list });
                    try self.push(.{ .object = result_obj });
                },
                .len_value => {
                    const v = try self.pop();
                    defer v.decref(self.allocator);
                    if (v != .object) return RuntimeError.TypeMismatch;
                    const len: usize = switch (v.object.payload) {
                        .list => |list| list.items.len,
                        .map => |map| map.count(),
                        .string => return RuntimeError.TypeMismatch,
                    };
                    try self.push(.{ .int = @intCast(len) });
                },

                // ---- JSON (ISA.bnf section 12) ----

                .json_parse => {
                    const count_val = try self.pop();
                    const ref_val = try self.pop();
                    if (count_val != .int or ref_val != .array_ref) return RuntimeError.TypeMismatch;
                    const ref = ref_val.array_ref;
                    try checkBufferRange(ref);
                    if (count_val.int < 0 or count_val.int > ref.len) return RuntimeError.IndexOutOfBounds;
                    const n: usize = @intCast(count_val.int);

                    try self.gatherBytes(ref, n);
                    const result = json_mod.parse(self.allocator, self.io_buffer[0..n]) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.JsonParseFailed => return self.failFile(RuntimeError.JsonParseFailed, "json", "", "malformed JSON input"),
                    };
                    try self.push(result);
                },

                .json_stringify => {
                    const v = try self.pop();
                    defer v.decref(self.allocator);
                    const result = json_mod.stringify(self.allocator, v) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        // Same bare-tag convention as MAP_HAS/LIST_PUSH's own
                        // TypeMismatch above — a stream or array reference
                        // has no diagnostic detail worth carrying beyond
                        // "wrong kind of value".
                        error.Unstringifiable => return RuntimeError.TypeMismatch,
                    };
                    try self.push(result);
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
                        else => {
                            // v is discarded either way (never numeric, so
                            // never refcounted on the success path above —
                            // but could be a heap object here, e.g. `-doc`).
                            v.decref(self.allocator);
                            return RuntimeError.TypeMismatch;
                        },
                    }
                },
                .not => {
                    const v = try self.pop();
                    if (v != .boolean) {
                        v.decref(self.allocator);
                        return RuntimeError.TypeMismatch;
                    }
                    try self.push(.{ .boolean = !v.boolean });
                },

                .eq => {
                    const b = try self.pop();
                    defer b.decref(self.allocator);
                    const a = try self.pop();
                    defer a.decref(self.allocator);
                    try self.push(.{ .boolean = Value.eql(a, b) });
                },
                .neq => {
                    const b = try self.pop();
                    defer b.decref(self.allocator);
                    const a = try self.pop();
                    defer a.decref(self.allocator);
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
                    frames[frame_count] = .{ .chunk = chunk, .ip = ip, .bp = bp, .return_width = return_width };
                    frame_count += 1;
                    bp = self.sp - func.arity;
                    chunk = &func.chunk;
                    ip = 0;
                    return_width = func.return_width;
                },
                .ret => {
                    // Everything the departing frame owns OTHER than the
                    // return value itself — its locals, its arguments, any
                    // temporaries — is being discarded, not moved anywhere,
                    // so each needs a decref (safe even though this range can
                    // overlap the copy-down destination below: this pass
                    // only ever READS a slot strictly below src_start, and
                    // the copy loop only ever WRITES into [bp, bp+return_width),
                    // and bp <= src_start always — so nothing here is ever
                    // double-decreffed or read after being overwritten).
                    const src_start = self.sp - return_width;
                    var discard_i: usize = bp;
                    while (discard_i < src_start) : (discard_i += 1) self.stack[discard_i].decref(self.allocator);

                    // Generalizes pop-then-push of a single scalar to `return_width`
                    // slots: the return value already sits at the top of the
                    // callee's own stack region (pushed by the return
                    // expression), so it's copied down onto the frame's base
                    // in place rather than popped into a temporary — this is
                    // the same move for width 1 as the old pop/push was.
                    // A pure move: the return value's ownership transfers to
                    // the caller, so no incref/decref of it here either.
                    var i: usize = 0;
                    while (i < return_width) : (i += 1) self.stack[bp + i] = self.stack[src_start + i];
                    self.sp = bp + return_width;

                    frame_count -= 1;
                    const frame = frames[frame_count];
                    chunk = frame.chunk;
                    ip = frame.ip;
                    bp = frame.bp;
                    return_width = frame.return_width;
                },

                .print => {
                    const v = try self.pop();
                    defer v.decref(self.allocator);
                    try v.print(writer);
                    try writer.writeAll("\n");
                },

                .read => {
                    const ref_val = try self.pop();
                    const stream = try self.popStream();
                    if (ref_val != .array_ref) return RuntimeError.TypeMismatch;
                    const ref = ref_val.array_ref;
                    try checkBufferRange(ref);

                    // A null reader is stdin with no input supplied, i.e.
                    // already at its end — a 0-byte read, not a failure.
                    const reader = try self.readerFor(host, stream) orelse {
                        try self.push(.{ .int = 0 });
                        continue;
                    };
                    const n = try readInto(reader, self.io_buffer[0..ref.len]);
                    self.scatterBytes(ref, n);
                    try self.push(.{ .int = @intCast(n) });
                },
                .write => {
                    const v = try self.pop();
                    defer v.decref(self.allocator);
                    const stream = try self.popStream();
                    const n = try writeValue(v, try self.writerFor(host, stream));
                    try self.push(.{ .int = @intCast(n) });
                },
                .write_bytes => {
                    const count_val = try self.pop();
                    const ref_val = try self.pop();
                    const stream = try self.popStream();
                    if (count_val != .int or ref_val != .array_ref) return RuntimeError.TypeMismatch;
                    const ref = ref_val.array_ref;
                    try checkBufferRange(ref);
                    if (count_val.int < 0 or count_val.int > ref.len) return RuntimeError.IndexOutOfBounds;
                    const n: usize = @intCast(count_val.int);

                    try self.gatherBytes(ref, n);
                    if (try self.writerFor(host, stream)) |w| {
                        w.writeAll(self.io_buffer[0..n]) catch return RuntimeError.StreamWriteFailed;
                    }
                    try self.push(.{ .int = @intCast(n) });
                },

                .open => {
                    const path_val = try self.pop();
                    // A no-op unless path_val turns out not to be `.string`
                    // (in which case it's rejected below anyway) — a path
                    // that IS `.string` is always borrowed, never refcounted.
                    defer path_val.decref(self.allocator);
                    if (path_val != .string) return RuntimeError.TypeMismatch;
                    const stream = try self.openFile(host, path_val.string, @enumFromInt(instr.operand));
                    try self.push(stream);
                },
                .close => {
                    const stream = try self.popStream();
                    switch (stream) {
                        .standard => return RuntimeError.CannotCloseStandardStream,
                        .file => |slot| {
                            _ = try self.fileEntry(slot); // StreamClosed if it isn't open
                            const fs = host.fs orelse return RuntimeError.FilesUnavailable;
                            try self.closeSlot(fs, slot);
                        },
                    }
                },

                // Closing here (rather than only in the errdefer above) is
                // what lets a failed flush of the program's own output be
                // reported instead of swallowed. A close failure returns
                // through `try`, which triggers the errdefer above (closing
                // — redundantly but harmlessly — and decreffing the stack);
                // decrefStack is only called again, directly, on the
                // ordinary success path, where the errdefer never fires.
                .halt => {
                    try self.closeAllFiles(host);
                    self.decrefStack();
                    return;
                },
            }
        }
    }
};

fn runSource(chunk: *const Chunk, buf: []u8) !usize {
    var vm = Vm.init(std.testing.allocator);
    var writer = std.Io.Writer.fixed(buf);
    const program = chunk_mod.Program{ .main = chunk.*, .functions = &.{} };
    try vm.run(&program, .{ .out = &writer });
    return writer.end;
}

fn expectRuntimeError(chunk: *const Chunk, expected: RuntimeError) !void {
    var vm = Vm.init(std.testing.allocator);
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const program = chunk_mod.Program{ .main = chunk.*, .functions = &.{} };
    try std.testing.expectError(expected, vm.run(&program, .{ .out = &writer }));
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

    var vm = Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&program, .{ .out = &writer });
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

    var vm = Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&program, .{ .out = &writer });
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

    var vm = Vm.init(allocator);
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(RuntimeError.CallStackOverflow, vm.run(&program, .{ .out = &writer }));
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

// ---- Byte-stream I/O (ISA.bnf sections 9 and 10) ------------------------

/// Emits a push of one of the standard streams — how a stream reaches the
/// stack, now that the I/O instructions take no operand of their own.
fn emitStream(chunk: *Chunk, allocator: std.mem.Allocator, standard: value_mod.Stream.Standard) !void {
    const idx = try chunk.addConstant(allocator, .{ .stream = .ofStandard(standard) });
    _ = try chunk.emitWithOperand(allocator, .push_const, idx);
}

/// Emits `len` zeroed slots (the buffer, at slots 0..len-1), then the
/// (stream, ref) pair on top of it that READ and WRITE_BYTES expect. The
/// stream has to be pushed before MAKE_ARRAY_REF so the two land in the
/// order the stack effects are written in.
fn emitBufferFor(chunk: *Chunk, allocator: std.mem.Allocator, standard: value_mod.Stream.Standard, len: u32) !void {
    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    var i: u32 = 0;
    while (i < len) : (i += 1) _ = try chunk.emitWithOperand(allocator, .push_const, zero);
    try emitStream(chunk, allocator, standard);
    _ = try chunk.emitWithOperand(allocator, .make_array_ref, chunk_mod.packIndexOperand(0, len));
}

test "read fills a buffer's slots with bytes and pushes the count" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitBufferFor(&chunk, allocator, .stdin, 3);
    _ = try chunk.emit(allocator, .read);
    _ = try chunk.emit(allocator, .print); // the count

    // Each element is the byte's numeric value, so buf[0] of "ABCDE" is 65.
    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    _ = try chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try chunk.emitWithOperand(allocator, .load_index, chunk_mod.packIndexOperand(0, 3));
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var out_buf: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var in = std.Io.Reader.fixed("ABCDE");
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &out, .in = &in });

    try std.testing.expectEqualStrings("3\n65\n", out.buffered());
}

test "read is a short read: fewer bytes than the buffer holds is not an error" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitBufferFor(&chunk, allocator, .stdin, 4);
    _ = try chunk.emit(allocator, .read);
    _ = try chunk.emit(allocator, .print); // the count

    // Slot 1 was never written by the 1-byte read, so it still holds the
    // zero the buffer was initialized with rather than stale bytes.
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .load_index, chunk_mod.packIndexOperand(0, 4));
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var out_buf: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var in = std.Io.Reader.fixed("Z");
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &out, .in = &in });

    try std.testing.expectEqualStrings("1\n0\n", out.buffered());
}

test "read at end of input reports 0 rather than failing" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitBufferFor(&chunk, allocator, .stdin, 2);
    _ = try chunk.emit(allocator, .read);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var out_buf: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var in = std.Io.Reader.fixed("");
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &out, .in = &in });

    try std.testing.expectEqualStrings("0\n", out.buffered());
}

test "an unsupplied stdin behaves as end of input, not as an error" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitBufferFor(&chunk, allocator, .stdin, 2);
    _ = try chunk.emit(allocator, .read);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf); // no `in` supplied
    try std.testing.expectEqualStrings("0\n", buf[0..len]);
}

test "reading a stream that isn't readable is a runtime error" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    // The compiler rejects `read(stdout, buf)` before it can ever run, but
    // the VM is the general check — a file opened for writing reaches this
    // same path, and there the direction isn't statically known.
    try emitBufferFor(&chunk, allocator, .stdout, 2);
    _ = try chunk.emit(allocator, .read);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.StreamNotReadable);
}

test "read into something that isn't a buffer reference is a type mismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitStream(&chunk, allocator, .stdin);
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .read);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "an I/O instruction handed something other than a stream is a type mismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const not_a_stream = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, not_a_stream);
    _ = try chunk.emitWithOperand(allocator, .push_const, not_a_stream);
    _ = try chunk.emit(allocator, .write);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "write renders a value without a trailing newline and pushes its byte count" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    // Writing to stderr keeps the written bytes and the PRINTed count in
    // two separately-assertable streams.
    try emitStream(&chunk, allocator, .stderr);
    const value = try chunk.addConstant(allocator, .{ .int = 42 });
    _ = try chunk.emitWithOperand(allocator, .push_const, value);
    _ = try chunk.emit(allocator, .write);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &out, .err = &err });

    try std.testing.expectEqualStrings("42", err.buffered());
    try std.testing.expectEqualStrings("2\n", out.buffered());
}

test "write sends stdout to out and stderr to err, never the other way" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const to_out = try chunk.addConstant(allocator, .{ .string = "out" });
    const to_err = try chunk.addConstant(allocator, .{ .string = "err" });
    try emitStream(&chunk, allocator, .stdout);
    _ = try chunk.emitWithOperand(allocator, .push_const, to_out);
    _ = try chunk.emit(allocator, .write);
    _ = try chunk.emit(allocator, .pop);
    try emitStream(&chunk, allocator, .stderr);
    _ = try chunk.emitWithOperand(allocator, .push_const, to_err);
    _ = try chunk.emit(allocator, .write);
    _ = try chunk.emit(allocator, .pop);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &out, .err = &err });

    try std.testing.expectEqualStrings("out", out.buffered());
    try std.testing.expectEqualStrings("err", err.buffered());
}

test "writing a stream that isn't writable is a runtime error" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitStream(&chunk, allocator, .stdin);
    const value = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, value);
    _ = try chunk.emit(allocator, .write);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.StreamNotWritable);
}

test "an unsupplied stderr still counts what was written, like /dev/null" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitStream(&chunk, allocator, .stderr);
    const value = try chunk.addConstant(allocator, .{ .string = "abc" });
    _ = try chunk.emitWithOperand(allocator, .push_const, value);
    _ = try chunk.emit(allocator, .write);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf); // no `err` supplied
    try std.testing.expectEqualStrings("3\n", buf[0..len]);
}

test "write_bytes writes a buffer's elements as raw bytes" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const h = try chunk.addConstant(allocator, .{ .int = 'H' });
    const i = try chunk.addConstant(allocator, .{ .int = 'i' });
    _ = try chunk.emitWithOperand(allocator, .push_const, h); // slot 0
    _ = try chunk.emitWithOperand(allocator, .push_const, i); // slot 1
    try emitStream(&chunk, allocator, .stdout);
    _ = try chunk.emitWithOperand(allocator, .make_array_ref, chunk_mod.packIndexOperand(0, 2));
    const two = try chunk.addConstant(allocator, .{ .int = 2 });
    _ = try chunk.emitWithOperand(allocator, .push_const, two);
    _ = try chunk.emit(allocator, .write_bytes);
    _ = try chunk.emit(allocator, .pop);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("Hi", buf[0..len]);
}

test "write_bytes writes only the first `count` elements" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const x = try chunk.addConstant(allocator, .{ .int = 'x' });
    const y = try chunk.addConstant(allocator, .{ .int = 'y' });
    _ = try chunk.emitWithOperand(allocator, .push_const, x);
    _ = try chunk.emitWithOperand(allocator, .push_const, y);
    try emitStream(&chunk, allocator, .stdout);
    _ = try chunk.emitWithOperand(allocator, .make_array_ref, chunk_mod.packIndexOperand(0, 2));
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .write_bytes);
    _ = try chunk.emit(allocator, .pop);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("x", buf[0..len]);
}

/// Emits a one-element buffer holding `element`, plus the (stream, ref,
/// count) WRITE_BYTES expects — the shape every one of the range/type
/// rejection tests below needs.
fn emitWriteOneByte(chunk: *Chunk, allocator: std.mem.Allocator, element: Value, count: i64) !void {
    const element_idx = try chunk.addConstant(allocator, element);
    _ = try chunk.emitWithOperand(allocator, .push_const, element_idx);
    try emitStream(chunk, allocator, .stdout);
    _ = try chunk.emitWithOperand(allocator, .make_array_ref, chunk_mod.packIndexOperand(0, 1));
    const count_idx = try chunk.addConstant(allocator, .{ .int = count });
    _ = try chunk.emitWithOperand(allocator, .push_const, count_idx);
    _ = try chunk.emit(allocator, .write_bytes);
    _ = try chunk.emit(allocator, .halt);
}

test "write_bytes rejects an element that isn't a byte, rather than masking it" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitWriteOneByte(&chunk, allocator, .{ .int = 256 }, 1);
    try expectRuntimeError(&chunk, RuntimeError.ByteOutOfRange);
}

test "write_bytes rejects a negative element too" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitWriteOneByte(&chunk, allocator, .{ .int = -1 }, 1);
    try expectRuntimeError(&chunk, RuntimeError.ByteOutOfRange);
}

test "write_bytes rejects a non-int element as a type mismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitWriteOneByte(&chunk, allocator, .{ .boolean = true }, 1);
    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "write_bytes past the buffer's length is bounds-checked" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitWriteOneByte(&chunk, allocator, .{ .int = 'a' }, 5);
    try expectRuntimeError(&chunk, RuntimeError.IndexOutOfBounds);
}

test "write_bytes with a negative count is bounds-checked too" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    try emitWriteOneByte(&chunk, allocator, .{ .int = 'a' }, -1);
    try expectRuntimeError(&chunk, RuntimeError.IndexOutOfBounds);
}

test "a buffer reference reaching past the value stack is rejected" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    // Not reachable from compiled Butter code — an array this long could
    // never have had its slots pushed in the first place — but the VM
    // checks the reference rather than trusting it.
    try emitStream(&chunk, allocator, .stdin);
    _ = try chunk.emitWithOperand(allocator, .make_array_ref, chunk_mod.packIndexOperand(0, stack_max + 1));
    _ = try chunk.emit(allocator, .read);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.IndexOutOfBounds);
}

// ---- Files (ISA.bnf section 10) -----------------------------------------

test "open without filesystem access fails rather than reaching for one" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const path = try chunk.addConstant(allocator, .{ .string = "nope.txt" });
    _ = try chunk.emitWithOperand(allocator, .push_const, path);
    _ = try chunk.emitWithOperand(allocator, .open, @intFromEnum(value_mod.OpenMode.read));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.FilesUnavailable);
}

test "open with a non-string path is a type mismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const not_a_path = try chunk.addConstant(allocator, .{ .int = 7 });
    _ = try chunk.emitWithOperand(allocator, .push_const, not_a_path);
    _ = try chunk.emitWithOperand(allocator, .open, @intFromEnum(value_mod.OpenMode.read));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "closing a standard stream is refused" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    // The compiler rejects a literal `close stdout` first; this is the VM's
    // own check, which is what a stream reaching CLOSE by any other route
    // (a variable holding `stdout`, say) runs into.
    try emitStream(&chunk, allocator, .stdout);
    _ = try chunk.emit(allocator, .close);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.CannotCloseStandardStream);
}

test "using a file slot that was never opened is a clean error, not a stale handle" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const bogus = try chunk.addConstant(allocator, .{ .stream = .{ .file = 3 } });
    _ = try chunk.emitWithOperand(allocator, .push_const, bogus);
    const value = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, value);
    _ = try chunk.emit(allocator, .write);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.StreamClosed);
}

test "a file slot beyond the table's size is the same clean error" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const bogus = try chunk.addConstant(allocator, .{ .stream = .{ .file = max_open_files + 1 } });
    _ = try chunk.emitWithOperand(allocator, .push_const, bogus);
    _ = try chunk.emit(allocator, .close);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.StreamClosed);
}

// ---- Maps, lists, and the heap (ISA.bnf section 11) ---------------------
//
// Every test in this section runs against `std.testing.allocator`, so a
// leaked or double-freed heap object fails the test even though nothing
// here asserts a refcount directly — the allocator's own bookkeeping is the
// correctness check (the one exception is the deliberately-cyclic test
// near the end, which uses a scoped arena instead, precisely because it is
// NOT expected to be leak-free).

test "make_list and index_get: a list literal's elements round-trip" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const ten = try chunk.addConstant(allocator, .{ .int = 10 });
    const twenty = try chunk.addConstant(allocator, .{ .int = 20 });
    const thirty = try chunk.addConstant(allocator, .{ .int = 30 });
    _ = try chunk.emitWithOperand(allocator, .push_const, ten);
    _ = try chunk.emitWithOperand(allocator, .push_const, twenty);
    _ = try chunk.emitWithOperand(allocator, .push_const, thirty);
    _ = try chunk.emitWithOperand(allocator, .make_list, 3);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("20\n", buf[0..len]);
}

test "index_get on a list out of bounds is IndexOutOfBounds, not memory corruption" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .make_list, 1);
    const five = try chunk.addConstant(allocator, .{ .int = 5 });
    _ = try chunk.emitWithOperand(allocator, .push_const, five);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.IndexOutOfBounds);
}

test "make_map and index_get/index_set: insert-then-update round-trips through a local slot" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const name = try chunk.addConstant(allocator, .{ .string = "name" });
    const ada = try chunk.addConstant(allocator, .{ .string = "Ada" });
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emitWithOperand(allocator, .push_const, ada);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1); // slot 0 = {name: "Ada"}

    const grace = try chunk.addConstant(allocator, .{ .string = "Grace" });
    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emitWithOperand(allocator, .push_const, grace);
    _ = try chunk.emit(allocator, .index_set);
    _ = try chunk.emit(allocator, .pop); // discard index_set's peeked "Grace"

    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("Grace\n", buf[0..len]);
}

test "index_get on a missing map key is KeyNotFound" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const name = try chunk.addConstant(allocator, .{ .string = "name" });
    const ada = try chunk.addConstant(allocator, .{ .string = "Ada" });
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emitWithOperand(allocator, .push_const, ada);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1);

    const missing = try chunk.addConstant(allocator, .{ .string = "missing" });
    _ = try chunk.emitWithOperand(allocator, .push_const, missing);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.KeyNotFound);
}

test "map_has reports presence without erroring on a missing key" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const name = try chunk.addConstant(allocator, .{ .string = "name" });
    const ada = try chunk.addConstant(allocator, .{ .string = "Ada" });
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emitWithOperand(allocator, .push_const, ada);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1); // slot 0

    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emit(allocator, .map_has);
    _ = try chunk.emit(allocator, .print); // true

    const missing = try chunk.addConstant(allocator, .{ .string = "missing" });
    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, missing);
    _ = try chunk.emit(allocator, .map_has);
    _ = try chunk.emit(allocator, .print); // false
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("true\nfalse\n", buf[0..len]);
}

test "map_delete removes an entry once, then reports it's already gone" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const name = try chunk.addConstant(allocator, .{ .string = "name" });
    const ada = try chunk.addConstant(allocator, .{ .string = "Ada" });
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emitWithOperand(allocator, .push_const, ada);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1); // slot 0

    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emit(allocator, .map_delete);
    _ = try chunk.emit(allocator, .print); // true

    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emit(allocator, .map_delete);
    _ = try chunk.emit(allocator, .print); // false
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("true\nfalse\n", buf[0..len]);
}

test "map_keys preserves insertion order" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const a = try chunk.addConstant(allocator, .{ .string = "a" });
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const b = try chunk.addConstant(allocator, .{ .string = "b" });
    const two = try chunk.addConstant(allocator, .{ .int = 2 });
    _ = try chunk.emitWithOperand(allocator, .push_const, a);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .push_const, b);
    _ = try chunk.emitWithOperand(allocator, .push_const, two);
    _ = try chunk.emitWithOperand(allocator, .make_map, 2); // {a: 1, b: 2}
    _ = try chunk.emit(allocator, .map_keys); // slot 0 = ["a", "b"]

    const zero_idx = try chunk.addConstant(allocator, .{ .int = 0 });
    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, zero_idx);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .print); // "a"

    const one_idx = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, one_idx);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .print); // "b"
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("a\nb\n", buf[0..len]);
}

test "len_value reads a list's and a map's length" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const two = try chunk.addConstant(allocator, .{ .int = 2 });
    const three = try chunk.addConstant(allocator, .{ .int = 3 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .push_const, two);
    _ = try chunk.emitWithOperand(allocator, .push_const, three);
    _ = try chunk.emitWithOperand(allocator, .make_list, 3);
    _ = try chunk.emit(allocator, .len_value);
    _ = try chunk.emit(allocator, .print); // 3

    const x = try chunk.addConstant(allocator, .{ .string = "x" });
    _ = try chunk.emitWithOperand(allocator, .push_const, x);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1);
    _ = try chunk.emit(allocator, .len_value);
    _ = try chunk.emit(allocator, .print); // 1
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("3\n1\n", buf[0..len]);
}

test "len_value on a plain scalar is TypeMismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .len_value);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "list_push grows a list and evaluates to its new length" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emitWithOperand(allocator, .make_list, 0); // slot 0 = []

    const ten = try chunk.addConstant(allocator, .{ .int = 10 });
    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, ten);
    _ = try chunk.emit(allocator, .list_push);
    _ = try chunk.emit(allocator, .print); // 1

    const twenty = try chunk.addConstant(allocator, .{ .int = 20 });
    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, twenty);
    _ = try chunk.emit(allocator, .list_push);
    _ = try chunk.emit(allocator, .print); // 2

    const zero_idx = try chunk.addConstant(allocator, .{ .int = 0 });
    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, zero_idx);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .print); // 10

    const one_idx = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, one_idx);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .print); // 20
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("1\n2\n10\n20\n", buf[0..len]);
}

test "list_push on a non-list is TypeMismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    const two = try chunk.addConstant(allocator, .{ .int = 2 });
    _ = try chunk.emitWithOperand(allocator, .push_const, two);
    _ = try chunk.emit(allocator, .list_push);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "chained index_get reaches through a list-of-maps two levels deep" {
    // Hand-assembled equivalent of:
    //   list outer := [{"a": 1}, {"a": 2}]
    //   print outer[1]["a"]
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const a = try chunk.addConstant(allocator, .{ .string = "a" });
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, a);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1); // {a: 1}

    const two = try chunk.addConstant(allocator, .{ .int = 2 });
    _ = try chunk.emitWithOperand(allocator, .push_const, a);
    _ = try chunk.emitWithOperand(allocator, .push_const, two);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1); // {a: 2}

    _ = try chunk.emitWithOperand(allocator, .make_list, 2); // [{a:1}, {a:2}]

    _ = try chunk.emitWithOperand(allocator, .push_const, one); // index 1
    _ = try chunk.emit(allocator, .index_get); // -> {a: 2}
    _ = try chunk.emitWithOperand(allocator, .push_const, a);
    _ = try chunk.emit(allocator, .index_get); // -> 2
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("2\n", buf[0..len]);
}

test "eq discards both list operands (compared by identity) without leaking" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emitWithOperand(allocator, .make_list, 0); // list a
    _ = try chunk.emitWithOperand(allocator, .make_list, 0); // list b
    _ = try chunk.emit(allocator, .eq);
    _ = try chunk.emit(allocator, .print); // false: distinct objects
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("false\n", buf[0..len]);
}

test "ret discards a callee-local list that never reaches the return, without leaking" {
    // Hand-assembled equivalent of:
    //   func helper() -> int {
    //       list temp := [1, 2, 3]
    //       return 42
    //   }
    //   print helper()
    const allocator = std.testing.allocator;

    var func_chunk: Chunk = .{};
    const one = try func_chunk.addConstant(allocator, .{ .int = 1 });
    const two = try func_chunk.addConstant(allocator, .{ .int = 2 });
    const three = try func_chunk.addConstant(allocator, .{ .int = 3 });
    _ = try func_chunk.emitWithOperand(allocator, .push_const, one);
    _ = try func_chunk.emitWithOperand(allocator, .push_const, two);
    _ = try func_chunk.emitWithOperand(allocator, .push_const, three);
    _ = try func_chunk.emitWithOperand(allocator, .make_list, 3); // slot 0 = temp
    const forty_two = try func_chunk.addConstant(allocator, .{ .int = 42 });
    _ = try func_chunk.emitWithOperand(allocator, .push_const, forty_two);
    _ = try func_chunk.emit(allocator, .ret);

    var main_chunk: Chunk = .{};
    _ = try main_chunk.emitWithOperand(allocator, .call, 0);
    _ = try main_chunk.emit(allocator, .print);
    _ = try main_chunk.emit(allocator, .halt);

    var functions: std.ArrayList(chunk_mod.Function) = .empty;
    try functions.append(allocator, .{ .name = "helper", .arity = 0, .chunk = func_chunk });
    var program = chunk_mod.Program{ .main = main_chunk, .functions = try functions.toOwnedSlice(allocator) };
    defer program.deinit(allocator);

    var vm = Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&program, .{ .out = &writer });
    try std.testing.expectEqualStrings("42\n", writer.buffered());
}

test "store_local frees the local's old list value before overwriting it" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const two = try chunk.addConstant(allocator, .{ .int = 2 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .push_const, two);
    _ = try chunk.emitWithOperand(allocator, .make_list, 2); // slot 0 = [1, 2]

    const three = try chunk.addConstant(allocator, .{ .int = 3 });
    const four = try chunk.addConstant(allocator, .{ .int = 4 });
    const five = try chunk.addConstant(allocator, .{ .int = 5 });
    _ = try chunk.emitWithOperand(allocator, .push_const, three);
    _ = try chunk.emitWithOperand(allocator, .push_const, four);
    _ = try chunk.emitWithOperand(allocator, .push_const, five);
    _ = try chunk.emitWithOperand(allocator, .make_list, 3); // [3, 4, 5], about to overwrite slot 0
    _ = try chunk.emitWithOperand(allocator, .store_local, 0);
    _ = try chunk.emit(allocator, .pop); // discard store_local's peeked copy

    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emit(allocator, .len_value);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("3\n", buf[0..len]);
    // If the old [1, 2] list weren't freed here, std.testing.allocator's own
    // leak check (via runSource's Vm.init(std.testing.allocator)) would fail
    // this test even though the assertion above passes.
}

test "a self-referential map is an accepted, documented leak (GRAMMAR.bnf design note 3m), not a crash" {
    // Hand-assembled equivalent of:
    //   map m := {}
    //   m["self"] := m
    //
    // Deliberately does NOT use std.testing.allocator directly: the whole
    // point of this test is that the cycle is never collected, which would
    // otherwise fail every other test in this file via the leak checker.
    // Wrapping it in an arena still returns everything to the real testing
    // allocator once the arena itself is torn down, so this doesn't mask a
    // genuine leak anywhere else.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const heap_allocator = arena.allocator();

    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emitWithOperand(allocator, .make_map, 0); // slot 0 = {}

    const self_key = try chunk.addConstant(allocator, .{ .string = "self" });
    _ = try chunk.emitWithOperand(allocator, .load_local, 0); // container
    _ = try chunk.emitWithOperand(allocator, .push_const, self_key);
    _ = try chunk.emitWithOperand(allocator, .load_local, 0); // value: m itself
    _ = try chunk.emit(allocator, .index_set);
    _ = try chunk.emit(allocator, .pop); // discard the assignment-expression's value
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(heap_allocator);
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &writer }); // must complete, not hang or crash
}

test "json_parse converts a byte buffer into the equivalent Butter value" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    // The buffer holds the ASCII bytes of "42".
    const four = try chunk.addConstant(allocator, .{ .int = '4' });
    const two = try chunk.addConstant(allocator, .{ .int = '2' });
    _ = try chunk.emitWithOperand(allocator, .push_const, four);
    _ = try chunk.emitWithOperand(allocator, .push_const, two);
    _ = try chunk.emitWithOperand(allocator, .make_array_ref, chunk_mod.packIndexOperand(0, 2));

    const count = try chunk.addConstant(allocator, .{ .int = 2 });
    _ = try chunk.emitWithOperand(allocator, .push_const, count);
    _ = try chunk.emit(allocator, .json_parse);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("42\n", buf[0..len]);
}

test "json_parse on malformed input is JsonParseFailed" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    // The buffer holds the single (invalid, on its own) byte '{'.
    const brace = try chunk.addConstant(allocator, .{ .int = '{' });
    _ = try chunk.emitWithOperand(allocator, .push_const, brace);
    _ = try chunk.emitWithOperand(allocator, .make_array_ref, chunk_mod.packIndexOperand(0, 1));

    const count = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, count);
    _ = try chunk.emit(allocator, .json_parse);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.JsonParseFailed);
}

test "json_stringify renders a string value with proper JSON escaping" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const str = try chunk.addConstant(allocator, .{ .string = "a\"b" });
    _ = try chunk.emitWithOperand(allocator, .push_const, str);
    _ = try chunk.emit(allocator, .json_stringify);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("\"a\\\"b\"\n", buf[0..len]);
}

test "json_stringify on a stream value is TypeMismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const stream = try chunk.addConstant(allocator, .{ .stream = .ofStandard(.stdout) });
    _ = try chunk.emitWithOperand(allocator, .push_const, stream);
    _ = try chunk.emit(allocator, .json_stringify);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}
