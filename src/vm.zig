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
    /// More `try` blocks active at once than the VM's fixed handler table
    /// holds (ISA.bnf section 14). Like `CallStackOverflow` this is a hard
    /// limit rather than a hint — there is no heap to grow the table with —
    /// and like it, it is NOT itself catchable: a handler can only run if
    /// there is room to record one.
    HandlerStackOverflow,
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

    // Directory and filesystem metadata (ISA.bnf section 16, GRAMMAR.bnf
    // design note 3w). `path_exists` never raises any of these three — an
    // access failure it can't otherwise classify just reads as `false` — so
    // this trio only ever comes from `listDir`/`remove`/`rename`.
    /// `listDir(path)` couldn't list `path`'s entries — it doesn't exist,
    /// isn't a directory, or can't be opened for another reason (no
    /// permission, an I/O error). Unlike `remove`/`rename` below, there is
    /// no meaningful non-error fallback for "list this directory's
    /// contents".
    ListDirFailed,
    /// `remove(path)` found something at `path` but couldn't delete it (no
    /// permission, a non-empty directory, an I/O error). `path` simply not
    /// existing is NOT this — `remove` reports that by evaluating to
    /// `false` instead (mirroring `map_delete`'s "absent is a no-op, not an
    /// error" split).
    RemoveFailed,
    /// `rename(from, to)` found `from` but couldn't rename it (no
    /// permission, `to`'s parent doesn't exist, a cross-device move, an I/O
    /// error). `from` simply not existing is NOT this, for the same reason
    /// it isn't for `RemoveFailed`.
    RenameFailed,

    // Maps, lists, and JSON (ISA.bnf sections 11 and 12).
    /// Reading a map key that isn't present. No diagnostic — the bare tag
    /// says everything there is to say, same as `StreamClosed`.
    KeyNotFound,
    /// `json(...)`'s input wasn't well-formed JSON. `Vm.diagnostic` carries
    /// a fixed description, since the underlying parser's own error detail
    /// doesn't survive past `json.zig`'s simplified conversion.
    JsonParseFailed,
    /// `int(...)`/`float(...)`'s (ISA.bnf section 13) string operand wasn't
    /// a valid number in the target format — empty, a non-numeric byte,
    /// surrounding whitespace, a leading `+`, an out-of-range magnitude, or
    /// (for `int` specifically) a decimal point. `Vm.diagnostic` names which
    /// of the two ("int"/"float") failed, mirroring `JsonParseFailed`'s own
    /// fixed-description convention.
    NumberParseFailed,

    /// `exit <expr>`'s value wasn't an INT in 0..255 — the range a process
    /// exit code can actually carry (`std.process.exit`'s own `u8`
    /// parameter). Checked rather than silently wrapped (e.g. `exit(256)`
    /// quietly becoming exit code 0), matching the "checked, not trusted"
    /// stance the rest of this VM already takes (overflow-checked
    /// arithmetic, `ByteOutOfRange` on WRITE_BYTES).
    InvalidExitCode,
};

const stack_max = 1024;
const frames_max = 256;

/// How many `try` blocks may be active at once (ISA.bnf section 14). Fixed,
/// like `frames_max` and `max_open_files`, because the VM has no allocator
/// at run time. It has to be a RUNTIME limit rather than a compile-time one
/// even though `try` nesting is lexical: a function containing a `try` can
/// be called from inside another one's guarded block, recursively, so the
/// depth a program actually reaches isn't visible in any one chunk.
const max_handlers = 64;

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
    /// What the bare `args` keyword evaluates to (as a fresh `list` of
    /// strings, one per element, built on demand — PUSH_ARGS never reads
    /// this slice again after building that list). Absent by default: an
    /// embedder that never sets it gets an empty `args`, exactly like a
    /// program run with no arguments.
    args: []const []const u8 = &.{},
    /// The environment `getenv`/`hasenv` (GRAMMAR.bnf design note 3v) see —
    /// a flat slice rather than a map because it is read a handful of times
    /// per run at most, never in a loop the way a stack slot is, and this
    /// keeps the whole `Host` plain injected data (the same shape `args`
    /// has) instead of a container the VM would have to own. A repeated
    /// name resolves to its FIRST entry.
    ///
    /// Absent by default, which is an EMPTY environment: every variable is
    /// unset, so `getenv` is `""` and `hasenv` is `false` for all of them.
    /// Deliberately not a null-vs-empty capability gate like `fs` — a
    /// program can't tell the two apart, and there's nothing to refuse:
    /// unlike opening a file, reading a variable that isn't there does
    /// nothing observable outside the VM.
    env: []const EnvVar = &.{},

    /// The filesystem as the program sees it: `io` performs the operations,
    /// and `dir` is what a relative path in `open` resolves against.
    pub const Fs = struct {
        io: std.Io,
        dir: std.Io.Dir,
    };

    /// One environment variable. Both fields are borrowed for the duration
    /// of `run` — GET_ENV copies the value into a fresh heap string rather
    /// than aliasing it, so nothing the program holds outlives this slice.
    pub const EnvVar = struct {
        name: []const u8,
        value: []const u8,
    };

    /// The value of `name`, or null if it isn't set. A linear scan: see the
    /// `env` field's own note on why this isn't a hash map.
    ///
    /// Comparison is BYTE-EXACT on every platform, including Windows, whose
    /// own environment lookup is case-insensitive — a deliberate choice, so
    /// that one Butter program behaves identically everywhere rather than
    /// having `getenv("path")` succeed on one host and not another
    /// (GRAMMAR.bnf design note 3v).
    pub fn lookup(self: Host, name: []const u8) ?[]const u8 {
        for (self.env) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }
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

/// One active `try` block: everything needed to abandon whatever the
/// guarded region was doing and resume at its catch block instead (ISA.bnf
/// section 14). Recorded by PUSH_HANDLER from the live machine state rather
/// than from the chunk, because none of it is a compile-time property — the
/// same PUSH_HANDLER can execute with any number of frames beneath it.
///
/// `sp` is the value-stack depth to rewind to, which is also where the error
/// map lands (making it the catch block's first local — see ISA.bnf section
/// 14's codegen pattern). `frame_count` is what makes an error raised
/// several calls deep resumable: it names the frame the `try` itself was
/// running in, so unwinding can discard every frame entered since.
const Handler = struct {
    chunk: *const Chunk,
    ip: usize,
    sp: usize,
    bp: usize,
    frame_count: usize,
    return_width: usize,
};

/// The execution state one `run` threads through every `step`: which chunk
/// is executing, where in it, and the call stack underneath. All of this was
/// plain `run` locals until `step` was split out of it (see `step`'s own doc
/// comment for why) — it lives in a struct now only because a called
/// function can't reach its caller's locals, not because anything about the
/// state itself changed.
///
/// Still entirely a `run` local: `frames` is the same 8 KiB array it was
/// before, and nothing here is heap-allocated or kept on the `Vm` between
/// runs.
const Exec = struct {
    program: *const chunk_mod.Program,
    chunk: *const Chunk,
    ip: usize = 0,
    bp: usize = 0,
    /// The CURRENTLY executing chunk's return width, restored from a `Frame`
    /// on the way out of a call. Starts at 1 for the main chunk, which never
    /// executes a RET of its own.
    return_width: usize = 1,
    frames: [frames_max]Frame = undefined,
    frame_count: usize = 0,
    /// The active `try` blocks, innermost last. Lives here beside `frames`
    /// rather than on the `Vm` because it is the same kind of thing — where
    /// execution can go next — and because unwinding restores `frames`'
    /// depth along with everything else here.
    handlers: [max_handlers]Handler = undefined,
    handler_count: usize = 0,
};

/// What one `step` tells `run` to do next.
const Flow = enum { running, halted };

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
    /// Set by EXIT just before it returns from `run` (a normal, non-error
    /// return — `exit(0)` is not a failure). `null` after a run that ended
    /// via HALT (falling off the end) instead, which the embedder should
    /// treat as exit code 0, exactly as if `exit(0)` had been the program's
    /// last statement.
    exit_code: ?u8 = null,

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{ .allocator = allocator };
    }

    fn push(self: *Vm, value: Value) RuntimeError!void {
        if (self.sp >= stack_max) return RuntimeError.StackOverflow;
        self.stack[self.sp] = value;
        self.sp += 1;
    }

    /// Hands the top value to the caller ALONG WITH the reference the stack
    /// was holding for it. Only `sp` moves — the slot keeps its bits — so a
    /// popped value is no longer reachable by `decrefStack`, which sweeps
    /// only what is still below `sp`.
    ///
    /// The invariant that falls out of that, and which every instruction
    /// owes: whatever you pop, you must either push back, store somewhere
    /// that takes over the reference, or `decref` — **on the failing paths
    /// as well as the successful one**. It's easy to miss because `decref`
    /// is a no-op for a non-object, so an operand that's an INT in every
    /// test you wrote will never expose the mistake; give it a `map`, `list`
    /// or `string` and the reference is stranded for good. `errdefer` is
    /// the right tool when the success path transfers ownership onward,
    /// plain `defer` when the value is consumed either way.
    ///
    /// This used to be moot — a `RuntimeError` ended the process, so a
    /// stranded reference died with it — but `try`/`catch` (TODO #9) will
    /// resume execution from exactly these paths. See the
    /// "Discarded-operand reference accounting" tests at the end of this
    /// file. The one deliberate exception is the errors that stay
    /// non-catchable: an allocation failure or a stack overflow still ends
    /// the run, so the few paths that strand a reference on the way out of
    /// those are left as they are.
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
    /// STORE_INDEX unchanged) — a map/list/string value already sitting on
    /// the stack, produced by any expression, including another INDEX_GET
    /// (chaining, e.g. `doc["a"]["b"]`). Read-only; never mutates
    /// `container`.
    ///
    /// Ownership differs by branch, which is why each one increfs (or not)
    /// itself rather than leaving a single blanket incref to the caller: the
    /// list/map cases return a value BORROWED from the container (still also
    /// owned by it), so the returned copy needs its own incref; the string
    /// case returns a FRESH `Value.newString` that already starts owned
    /// outright by this call, so increffing it too would leak it (nothing
    /// else would ever decref that extra reference).
    fn indexGet(allocator: std.mem.Allocator, container: Value, index: Value) !Value {
        if (container != .object) return RuntimeError.TypeMismatch;
        switch (container.object.payload) {
            .list => |list| {
                if (index != .int) return RuntimeError.TypeMismatch;
                if (index.int < 0 or index.int >= list.items.len) return RuntimeError.IndexOutOfBounds;
                const v = list.items[@as(usize, @intCast(index.int))];
                v.incref();
                return v;
            },
            .map => |map| {
                const key = index.asStringBytes() orelse return RuntimeError.TypeMismatch;
                const v = map.get(key) orelse return RuntimeError.KeyNotFound;
                v.incref();
                return v;
            },
            // `s[i]` (GRAMMAR.bnf's Strings design notes): byte-indexed,
            // bounds-checked, evaluates to a fresh length-1 string rather
            // than an int — there is no separate "char" type in this
            // language, and this lets a parser compare `s[i] == "{"`
            // directly against an ordinary string literal.
            .string => |bytes| {
                if (index != .int) return RuntimeError.TypeMismatch;
                if (index.int < 0 or index.int >= bytes.len) return RuntimeError.IndexOutOfBounds;
                const i: usize = @intCast(index.int);
                return Value.newString(allocator, bytes[i .. i + 1]);
            },
        }
    }

    /// `s[a..b]` (ISA.bnf section 11's Strings addendum): a fresh substring
    /// of the bytes `[start, end)` — end exclusive, matching the for-loop's
    /// own range convention. String only, unlike `indexGet`/`indexSet` —
    /// there is no list/map slice in this pass. Like the string branch of
    /// `indexGet`, the result is a fresh, already-owned `Value.newString`;
    /// the caller must not incref it again.
    fn indexSlice(allocator: std.mem.Allocator, container: Value, start: Value, end: Value) !Value {
        if (container != .object or container.object.payload != .string) return RuntimeError.TypeMismatch;
        if (start != .int or end != .int) return RuntimeError.TypeMismatch;
        const bytes = container.object.payload.string;
        const len: i64 = @intCast(bytes.len);
        if (start.int < 0 or start.int > end.int or end.int > len) return RuntimeError.IndexOutOfBounds;
        const s: usize = @intCast(start.int);
        const e: usize = @intCast(end.int);
        return Value.newString(allocator, bytes[s..e]);
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

    /// Truncates `f` toward zero into an `i64` — `int(x)`'s float-cast form
    /// (GRAMMAR.bnf design note 3r's addendum). `@intFromFloat` itself would
    /// do the same truncation but is safety-checked UB if the integer part
    /// doesn't fit; this checks first instead, the same "checked, not
    /// trusted" stance `checkedAdd`/`checkedSub`/`checkedMul` already take
    /// for int-side overflow. NaN, ±Infinity, and any magnitude that doesn't
    /// fit in i64 are all `RuntimeError.Overflow`.
    fn checkedIntFromFloat(f: f64) RuntimeError!i64 {
        // 2^63 is exactly representable in f64 and is one past i64's true
        // max (9223372036854775807, itself NOT exactly representable as
        // f64) — the correct exclusive upper bound to compare a truncated
        // float against before handing it to @intFromFloat.
        const limit: f64 = 9223372036854775808.0;
        const truncated = @trunc(f);
        if (std.math.isNan(f) or truncated < -limit or truncated >= limit) return RuntimeError.Overflow;
        return @intFromFloat(truncated);
    }

    /// `+` (GRAMMAR.bnf section 3, ISA.bnf ADD): numeric addition when both
    /// operands are numbers, byte-concatenation into a fresh heap string
    /// when both are strings, `TypeMismatch` otherwise. Unlike
    /// `popNumericPair`'s callers, this can't just check `isNumeric` up
    /// front — a string/string pair is valid here — so it pops and
    /// classifies the operands itself.
    fn add(self: *Vm) (RuntimeError || std.mem.Allocator.Error)!void {
        const b = try self.pop();
        const a = try self.pop();
        if (a.isNumeric() and b.isNumeric()) {
            if (a == .int and b == .int) {
                try self.push(.{ .int = try checkedAdd(a.int, b.int) });
            } else {
                try self.push(.{ .float = a.asFloat() + b.asFloat() });
            }
            return;
        }
        if (a.asStringBytes()) |av| {
            if (b.asStringBytes()) |bv| {
                const bytes = try self.allocator.alloc(u8, av.len + bv.len);
                @memcpy(bytes[0..av.len], av);
                @memcpy(bytes[av.len..], bv);
                const obj = Object.create(self.allocator, .{ .string = bytes }) catch |err| {
                    self.allocator.free(bytes);
                    return err;
                };
                a.decref(self.allocator);
                b.decref(self.allocator);
                try self.push(.{ .object = obj });
                return;
            }
        }
        a.decref(self.allocator);
        b.decref(self.allocator);
        return RuntimeError.TypeMismatch;
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

    /// `<`/`<=`/`>`/`>=` (GRAMMAR.bnf section 3, ISA.bnf CMP_*): numeric
    /// ordering when both operands are numbers, byte-lexicographic
    /// ordering (`std.mem.order`) when both are strings, `TypeMismatch`
    /// otherwise. Mirrors `add`'s string/numeric split rather than
    /// `popNumericPair`, since a string/string pair is valid here too.
    fn compare(self: *Vm, comptime op: CompareOp) RuntimeError!void {
        const b = try self.pop();
        const a = try self.pop();
        if (a.isNumeric() and b.isNumeric()) {
            const result = if (a == .int and b == .int) switch (op) {
                .lt => a.int < b.int,
                .lte => a.int <= b.int,
                .gt => a.int > b.int,
                .gte => a.int >= b.int,
            } else switch (op) {
                .lt => a.asFloat() < b.asFloat(),
                .lte => a.asFloat() <= b.asFloat(),
                .gt => a.asFloat() > b.asFloat(),
                .gte => a.asFloat() >= b.asFloat(),
            };
            try self.push(.{ .boolean = result });
            return;
        }
        if (a.asStringBytes()) |av| {
            if (b.asStringBytes()) |bv| {
                const ord = std.mem.order(u8, av, bv);
                const result = switch (op) {
                    .lt => ord == .lt,
                    .lte => ord != .gt,
                    .gt => ord == .gt,
                    .gte => ord != .lt,
                };
                a.decref(self.allocator);
                b.decref(self.allocator);
                try self.push(.{ .boolean = result });
                return;
            }
        }
        a.decref(self.allocator);
        b.decref(self.allocator);
        return RuntimeError.TypeMismatch;
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

    /// `exists(path)` (ISA.bnf section 16). Deliberately lenient: ANY reason
    /// the check can't be answered — not just `error.FileNotFound`, but
    /// permission denied, a bad path, and so on — reads as `false` rather
    /// than raising, matching `std.Io.Dir.access`'s own documented
    /// TOCTOU-racy, advisory-only contract (there is no way to turn a
    /// "false" here into a guarantee the path will still be there, or still
    /// absent, by the next instruction). The only ways this call can fail
    /// outright are the capability gate and a non-string operand, neither of
    /// which is about the path itself.
    fn pathExists(self: *Vm, host: Host, path: []const u8) RuntimeError!bool {
        const fs = host.fs orelse return self.failFile(RuntimeError.FilesUnavailable, "exists", path, "this program was run without filesystem access");
        fs.dir.access(fs.io, path, .{}) catch return false;
        return true;
    }

    /// `listDir(path)` (ISA.bnf section 16) — the names of `path`'s own
    /// entries, non-recursive, in whatever order the OS iterator hands them
    /// back (never sorted). Unlike `pathExists`, any failure to open or walk
    /// `path` as a directory is `RuntimeError.ListDirFailed`: there's no
    /// meaningful "couldn't tell" fallback for "list this" the way there is
    /// for "does this exist".
    fn listDirEntries(self: *Vm, host: Host, path: []const u8) (RuntimeError || std.mem.Allocator.Error)!Value {
        const fs = host.fs orelse return self.failFile(RuntimeError.FilesUnavailable, "listDir", path, "this program was run without filesystem access");

        var dir = fs.dir.openDir(fs.io, path, .{ .iterate = true }) catch |err| return self.failFile(RuntimeError.ListDirFailed, "listDir", path, @errorName(err));
        defer dir.close(fs.io);

        var list: std.ArrayList(Value) = .empty;
        errdefer {
            for (list.items) |item| item.decref(self.allocator);
            list.deinit(self.allocator);
        }
        var it = dir.iterate();
        while (it.next(fs.io) catch |err| return self.failFile(RuntimeError.ListDirFailed, "listDir", path, @errorName(err))) |entry| {
            try list.append(self.allocator, try Value.newString(self.allocator, entry.name));
        }

        const result_obj = try Object.create(self.allocator, .{ .list = list });
        return .{ .object = result_obj };
    }

    /// `remove(path)` (ISA.bnf section 16) — deletes the file or empty
    /// directory at `path`. `path` simply not being there is reported by
    /// evaluating to `false`, not an error (the same "absent is a no-op"
    /// split `map_delete` gives a map key); any other failure — no
    /// permission, a non-empty directory, an I/O error — is
    /// `RuntimeError.RemoveFailed`.
    fn removePath(self: *Vm, host: Host, path: []const u8) RuntimeError!bool {
        const fs = host.fs orelse return self.failFile(RuntimeError.FilesUnavailable, "remove", path, "this program was run without filesystem access");

        fs.dir.deleteFile(fs.io, path) catch |err| switch (err) {
            error.FileNotFound => return false,
            // `deleteFile` on something that turns out to be a directory —
            // try the directory-deletion path instead of failing outright.
            error.IsDir => fs.dir.deleteDir(fs.io, path) catch |dir_err| switch (dir_err) {
                error.FileNotFound => return false, // race: gone between the two calls
                else => return self.failFile(RuntimeError.RemoveFailed, "remove", path, @errorName(dir_err)),
            },
            else => return self.failFile(RuntimeError.RemoveFailed, "remove", path, @errorName(err)),
        };
        return true;
    }

    /// `rename(from, to)` (ISA.bnf section 16) — mirrors `removePath`'s
    /// "absent is a no-op" split: `from` not existing evaluates to `false`,
    /// checked with an independent `access` call first rather than trusting
    /// the underlying rename's own `error.FileNotFound`, which on some
    /// platforms can't be told apart from `to`'s PARENT directory being
    /// missing — a genuine failure, not a no-op. Any other failure is
    /// `RuntimeError.RenameFailed`.
    fn renamePath(self: *Vm, host: Host, from: []const u8, to: []const u8) RuntimeError!bool {
        const fs = host.fs orelse return self.failFile(RuntimeError.FilesUnavailable, "rename", from, "this program was run without filesystem access");

        fs.dir.access(fs.io, from, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => {},
        };
        fs.dir.rename(from, fs.dir, to, fs.io) catch |err| return self.failFile(RuntimeError.RenameFailed, "rename", from, @errorName(err));
        return true;
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
        if (v != .stream) {
            // A `Value.stream` is never refcounted, so the success path has
            // nothing to release — but a rejected operand can be anything,
            // including a heap object (`write(m["k"], ...)`), and it is
            // discarded here rather than pushed back.
            v.decref(self.allocator);
            return RuntimeError.TypeMismatch;
        }
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
        errdefer {
            self.closeAllFiles(host) catch {};
            self.decrefStack();
        }

        var exec: Exec = .{ .program = program, .chunk = &program.main };
        while (true) {
            const flow = self.step(&exec, host) catch |err| flow: {
                if (!catchable(err) or exec.handler_count == 0) return err;
                try self.unwindToHandler(&exec, err);
                break :flow .running;
            };
            switch (flow) {
                .running => {},
                .halted => return,
            }
        }
    }

    /// Whether a `try` block is allowed to intercept `err` (GRAMMAR.bnf
    /// design note 3u). This list IS the specification of what a Butter
    /// program can recover from, so it names every variant explicitly
    /// rather than testing membership of `RuntimeError` — adding a variant
    /// should be a decision, not an inheritance.
    fn catchable(err: anyerror) bool {
        return switch (err) {
            // Program conditions: things a program did, and could do
            // differently.
            error.TypeMismatch,
            error.DivisionByZero,
            error.Overflow,
            error.IndexOutOfBounds,
            error.ByteOutOfRange,
            error.StreamReadFailed,
            error.StreamWriteFailed,
            error.FileOpenFailed,
            error.TooManyOpenFiles,
            error.FileCloseFailed,
            error.StreamNotReadable,
            error.StreamNotWritable,
            error.StreamClosed,
            error.CannotCloseStandardStream,
            error.FilesUnavailable,
            error.KeyNotFound,
            error.JsonParseFailed,
            error.NumberParseFailed,
            error.InvalidExitCode,
            error.ListDirFailed,
            error.RemoveFailed,
            error.RenameFailed,
            => true,

            // VM-integrity failures. Not a program condition, and running a
            // catch block needs the very room these report having run out
            // of. `error.OutOfMemory` and any host I/O failure fall in the
            // same bucket via the `else` below — the first because building
            // the error map allocates, so a handler for it could not run.
            error.StackOverflow,
            error.StackUnderflow,
            error.CallStackOverflow,
            error.HandlerStackOverflow,
            => false,

            else => false,
        };
    }

    /// Abandons whatever the innermost `try` block was doing and resumes at
    /// its catch block, with the error map (see `errorValue`) pushed where
    /// the catch block expects its binding. The caller has already checked
    /// that a handler exists and that `err` is catchable.
    ///
    /// Note what is NOT undone: files opened inside the guarded block stay
    /// open (GRAMMAR.bnf design note 3u — a stream can outlive the block
    /// that opened it, and nothing here can tell that case apart from a
    /// leak), and `Vm.diagnostic` is cleared rather than kept, so a later
    /// uncaught error can't report detail belonging to this one.
    fn unwindToHandler(self: *Vm, ex: *Exec, err: anyerror) !void {
        ex.handler_count -= 1;
        const handler = ex.handlers[ex.handler_count];

        // Everything the abandoned region pushed is discarded — across as
        // many frames as it spans, since the value stack is one flat array
        // regardless of how many calls are layered on it (the same reason
        // `decrefStack` can sweep it in a single pass).
        var i = handler.sp;
        while (i < self.sp) : (i += 1) self.stack[i].decref(self.allocator);
        self.sp = handler.sp;

        ex.chunk = handler.chunk;
        ex.ip = handler.ip;
        ex.bp = handler.bp;
        ex.frame_count = handler.frame_count;
        ex.return_width = handler.return_width;

        // Built before `diagnostic` is cleared, since that's where the
        // operation/path detail comes from. If this fails (only OOM can),
        // the error propagates out of `run` with the stack already rewound —
        // harmless, since the errdefer there sweeps whatever is left.
        const info = try self.errorValue(err);
        self.diagnostic = null;
        try self.push(info);
    }

    /// The `map` a catch block binds: four keys, always all present, so a
    /// program can read any of them without guarding with `has()` first
    /// (GRAMMAR.bnf design note 3u).
    ///
    ///   error     - the `RuntimeError` tag name, the stable thing to
    ///               branch on ("KeyNotFound").
    ///   message   - human-readable, worded exactly as the CLI words an
    ///               uncaught error, so a caught-and-reported failure reads
    ///               identically to one that got away.
    ///   operation - what was being attempted ("open"), or "" for the
    ///               errors that carry no `Diagnostic`.
    ///   path      - the file involved, or "" likewise.
    fn errorValue(self: *Vm, err: anyerror) !Value {
        const obj = try Object.create(self.allocator, .{ .map = .empty });
        const result = Value{ .object = obj };
        errdefer result.decref(self.allocator);

        try self.mapSetText(obj, "error", @errorName(err));

        if (self.diagnostic) |d| {
            const message = if (d.path.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s} '{s}': {s}", .{ d.operation, d.path, d.cause })
            else
                try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ d.operation, d.cause });
            defer self.allocator.free(message);
            try self.mapSetText(obj, "message", message);
            try self.mapSetText(obj, "operation", d.operation);
            try self.mapSetText(obj, "path", d.path);
        } else {
            try self.mapSetText(obj, "message", @errorName(err));
            try self.mapSetText(obj, "operation", "");
            try self.mapSetText(obj, "path", "");
        }
        return result;
    }

    /// Sets `key` to a fresh string copy of `text`. `mapSet` takes over the
    /// value on success, so the errdefer only covers it failing first.
    fn mapSetText(self: *Vm, obj: *Object, key: []const u8, text: []const u8) !void {
        const v = try Value.newString(self.allocator, text);
        errdefer v.decref(self.allocator);
        try obj.mapSet(self.allocator, key, v);
    }

    /// Fetches and executes exactly one instruction, reporting whether the
    /// program is still running afterwards.
    ///
    /// This is a separate function from `run` rather than that loop's body
    /// purely so that a failing instruction becomes an error `run` can
    /// CATCH instead of one that unwinds straight out of the interpreter.
    /// Nothing uses that yet — `run` still propagates every error exactly as
    /// it did when this was one function — but it is the seam `try`/`catch`
    /// needs (TODO #9): a handler can only resume a program if something is
    /// still on the Zig stack to resume it, and until this split there was
    /// no such point.
    ///
    /// `ex` is by pointer because most of what an instruction does is
    /// mutate it — advancing `ip`, pushing and popping frames, switching
    /// chunks on a call.
    ///
    /// `inline` IS LOAD-BEARING, not a hint. A real call per instruction
    /// costs 33-42% on the dispatch-bound benchmarks — measured back to
    /// back with only this keyword changed (`zig build test-performance
    /// -Doptimize=ReleaseFast`: loop_sum 244ms -> 338ms, function_calls
    /// 157ms -> 223ms, bubble_sort 28.8ms -> 38.4ms; the allocation-bound
    /// map_ops is unaffected) — because `ip`/`bp`/`chunk` stop being
    /// registers the optimizer can keep across iterations and become memory
    /// round-trips through `ex` instead. Inlined into `run`'s loop, `exec`
    /// doesn't escape and those fields go back into registers — measured
    /// back to baseline. There's exactly one call site, so this costs no
    /// code size. Inlining does NOT weaken the seam described above: `try`
    /// inside an inline function still yields its error to the CALL SITE,
    /// which is the loop in `run`, which is precisely where a handler needs
    /// to catch it.
    inline fn step(self: *Vm, ex: *Exec, host: Host) !Flow {
        const instr = ex.chunk.code.items[ex.ip];
        ex.ip += 1;
        switch (instr.op) {
            .push_const => {
                const v = ex.chunk.constants.items[instr.operand];
                v.incref();
                try self.push(v);
            },
            .push_true => try self.push(.{ .boolean = true }),
            .push_false => try self.push(.{ .boolean = false }),
            .pop => {
                const v = try self.pop();
                v.decref(self.allocator);
            },

            .load_local => {
                const v = self.stack[ex.bp + instr.operand];
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
                self.stack[ex.bp + instr.operand].decref(self.allocator);
                self.stack[ex.bp + instr.operand] = new_v;
            },

            .load_index => {
                const idx_val = try self.pop();
                if (idx_val != .int) {
                    // The ONLY path where a discarded index can still be
                    // holding a heap reference (`xs[m["k"]]` with a string
                    // under the key): past this check it is an INT, which
                    // `decref` would treat as a no-op anyway. Releasing it
                    // here rather than under a `defer` keeps the release off
                    // the hot path entirely — this is indexing.
                    idx_val.decref(self.allocator);
                    return RuntimeError.TypeMismatch;
                }
                const idx = chunk_mod.unpackIndexOperand(instr.operand);
                if (idx_val.int < 0 or idx_val.int >= idx.length) return RuntimeError.IndexOutOfBounds;
                const v = self.stack[ex.bp + idx.slot + @as(usize, @intCast(idx_val.int))];
                v.incref();
                try self.push(v);
            },
            .store_index => {
                const v = try self.pop();
                // The value being stored, unlike the index, can be a heap
                // object on EVERY failing path, and on the successful one
                // its popped reference is handed to the array slot below —
                // which is exactly `errdefer`, and costs nothing when no
                // error happens.
                errdefer v.decref(self.allocator);
                const idx_val = try self.pop();
                if (idx_val != .int) {
                    idx_val.decref(self.allocator); // as in LOAD_INDEX above
                    return RuntimeError.TypeMismatch;
                }
                const idx = chunk_mod.unpackIndexOperand(instr.operand);
                if (idx_val.int < 0 or idx_val.int >= idx.length) return RuntimeError.IndexOutOfBounds;
                v.incref();
                self.stack[ex.bp + idx.slot + @as(usize, @intCast(idx_val.int))].decref(self.allocator);
                self.stack[ex.bp + idx.slot + @as(usize, @intCast(idx_val.int))] = v;
                try self.push(v);
            },

            .make_array_ref => {
                const idx = chunk_mod.unpackIndexOperand(instr.operand);
                try self.push(.{ .array_ref = .{ .base = @intCast(ex.bp + idx.slot), .len = idx.length } });
            },
            .load_index_ref => {
                const idx_val = try self.pop();
                if (idx_val != .int) {
                    idx_val.decref(self.allocator); // as in LOAD_INDEX above
                    return RuntimeError.TypeMismatch;
                }
                const ref = self.stack[ex.bp + instr.operand];
                if (ref != .array_ref) return RuntimeError.TypeMismatch;
                if (idx_val.int < 0 or idx_val.int >= ref.array_ref.len) return RuntimeError.IndexOutOfBounds;
                const v = self.stack[ref.array_ref.base + @as(usize, @intCast(idx_val.int))];
                v.incref();
                try self.push(v);
            },
            .store_index_ref => {
                const v = try self.pop();
                errdefer v.decref(self.allocator); // undone only if the store never happens, same as STORE_INDEX
                const idx_val = try self.pop();
                if (idx_val != .int) {
                    idx_val.decref(self.allocator); // as in LOAD_INDEX above
                    return RuntimeError.TypeMismatch;
                }
                const ref = self.stack[ex.bp + instr.operand];
                if (ref != .array_ref) return RuntimeError.TypeMismatch;
                if (idx_val.int < 0 or idx_val.int >= ref.array_ref.len) return RuntimeError.IndexOutOfBounds;
                v.incref();
                self.stack[ref.array_ref.base + @as(usize, @intCast(idx_val.int))].decref(self.allocator);
                self.stack[ref.array_ref.base + @as(usize, @intCast(idx_val.int))] = v;
                try self.push(v);
            },
            .load_ref_len => {
                const ref = self.stack[ex.bp + instr.operand];
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
                const result = try indexGet(self.allocator, container, index_val);
                try self.push(result);
            },
            .index_slice => {
                const end_val = try self.pop();
                defer end_val.decref(self.allocator);
                const start_val = try self.pop();
                defer start_val.decref(self.allocator);
                const container = try self.pop();
                defer container.decref(self.allocator);
                const result = try indexSlice(self.allocator, container, start_val, end_val);
                try self.push(result);
            },
            .index_set => {
                const v = try self.pop();
                errdefer v.decref(self.allocator); // undo the stack's own claim if we never restore it below
                v.incref();
                errdefer v.decref(self.allocator); // undo the copy indexSet would store, if it fails first
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
                    try list.append(self.allocator, try Value.newString(self.allocator, entry.key_ptr.*));
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
                    .string => |s| s.len,
                };
                try self.push(.{ .int = @intCast(len) });
            },

            // ---- JSON (ISA.bnf section 12) ----

            .json_parse => {
                const count_val = try self.pop();
                const ref_val = try self.pop();
                if (count_val != .int or ref_val != .array_ref) {
                    // Past this check neither can be a heap object, so this
                    // is the only path that has to release them — same
                    // reasoning as LOAD_INDEX above.
                    count_val.decref(self.allocator);
                    ref_val.decref(self.allocator);
                    return RuntimeError.TypeMismatch;
                }
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

            // ---- Numeric parsing (ISA.bnf section 13) ----

            .parse_int => {
                const v = try self.pop();
                defer v.decref(self.allocator);
                if (v.asStringBytes()) |bytes| {
                    const result = std.fmt.parseInt(i64, bytes, 10) catch return self.failFile(RuntimeError.NumberParseFailed, "int", "", "malformed integer literal");
                    try self.push(.{ .int = result });
                } else if (v == .float) {
                    try self.push(.{ .int = try checkedIntFromFloat(v.float) });
                } else {
                    return RuntimeError.TypeMismatch;
                }
            },
            .parse_float => {
                const v = try self.pop();
                defer v.decref(self.allocator);
                const bytes = v.asStringBytes() orelse return RuntimeError.TypeMismatch;
                const result = std.fmt.parseFloat(f64, bytes) catch return self.failFile(RuntimeError.NumberParseFailed, "float", "", "malformed float literal");
                try self.push(.{ .float = result });
            },

            // ---- Environment variables (ISA.bnf section 15) ----

            .get_env => {
                const name_val = try self.pop();
                defer name_val.decref(self.allocator);
                const name = name_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                // An unset variable is `""`, not an error and not `null` —
                // `hasenv` is how a program tells "unset" from "set to the
                // empty string" (GRAMMAR.bnf design note 3v). Always a
                // fresh copy, never a slice into `Host.env`, so the result
                // outlives the host slice exactly like PUSH_ARGS's strings.
                try self.push(try Value.newString(self.allocator, host.lookup(name) orelse ""));
            },
            .has_env => {
                const name_val = try self.pop();
                defer name_val.decref(self.allocator);
                const name = name_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                try self.push(.{ .boolean = host.lookup(name) != null });
            },

            .path_exists => {
                const path_val = try self.pop();
                defer path_val.decref(self.allocator);
                const path = path_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                try self.push(.{ .boolean = try self.pathExists(host, path) });
            },
            .list_dir => {
                const path_val = try self.pop();
                defer path_val.decref(self.allocator);
                const path = path_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                try self.push(try self.listDirEntries(host, path));
            },
            .path_remove => {
                const path_val = try self.pop();
                defer path_val.decref(self.allocator);
                const path = path_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                try self.push(.{ .boolean = try self.removePath(host, path) });
            },
            .path_rename => {
                const to_val = try self.pop();
                defer to_val.decref(self.allocator);
                const from_val = try self.pop();
                defer from_val.decref(self.allocator);
                const to = to_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                const from = from_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                try self.push(.{ .boolean = try self.renamePath(host, from, to) });
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

            .jump => ex.ip = instr.operand,
            .jump_if_false => {
                const cond = try self.peek(0);
                if (cond != .boolean) return RuntimeError.TypeMismatch;
                if (!cond.boolean) ex.ip = instr.operand;
            },

            .push_handler => {
                if (ex.handler_count >= max_handlers) return RuntimeError.HandlerStackOverflow;
                ex.handlers[ex.handler_count] = .{
                    .chunk = ex.chunk,
                    .ip = instr.operand,
                    .sp = self.sp,
                    .bp = ex.bp,
                    .frame_count = ex.frame_count,
                    .return_width = ex.return_width,
                };
                ex.handler_count += 1;
            },
            .pop_handler => {
                // Defense-in-depth: the compiler emits POP_HANDLER only to
                // match a PUSH_HANDLER it already emitted, so this can't
                // actually happen from compiled Butter source — same spirit
                // as MAKE_MAP's key check.
                if (ex.handler_count == 0) return RuntimeError.StackUnderflow;
                ex.handler_count -= 1;
            },

            .call => {
                if (ex.frame_count >= frames_max) return RuntimeError.CallStackOverflow;
                const func = &ex.program.functions[instr.operand];
                ex.frames[ex.frame_count] = .{ .chunk = ex.chunk, .ip = ex.ip, .bp = ex.bp, .return_width = ex.return_width };
                ex.frame_count += 1;
                ex.bp = self.sp - func.arity;
                ex.chunk = &func.chunk;
                ex.ip = 0;
                ex.return_width = func.return_width;
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
                const src_start = self.sp - ex.return_width;
                var discard_i: usize = ex.bp;
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
                while (i < ex.return_width) : (i += 1) self.stack[ex.bp + i] = self.stack[src_start + i];
                self.sp = ex.bp + ex.return_width;

                ex.frame_count -= 1;
                const frame = ex.frames[ex.frame_count];
                ex.chunk = frame.chunk;
                ex.ip = frame.ip;
                ex.bp = frame.bp;
                ex.return_width = frame.return_width;

                // A `return` out of a guarded block leaves that block's
                // handler behind, pointing at a catch block in a chunk this
                // frame is no longer running — so every handler the
                // departing frame installed goes with it. Done here rather
                // than by having the compiler emit POP_HANDLER before each
                // in-try `return` because this covers every way out of a
                // frame at once, by construction.
                while (ex.handler_count > 0 and ex.handlers[ex.handler_count - 1].frame_count > ex.frame_count) {
                    ex.handler_count -= 1;
                }
            },

            .print => {
                const v = try self.pop();
                defer v.decref(self.allocator);
                try v.print(host.out);
                try host.out.writeAll("\n");
            },

            .push_args => {
                var list: std.ArrayList(Value) = .empty;
                errdefer {
                    for (list.items) |item| item.decref(self.allocator);
                    list.deinit(self.allocator);
                }
                try list.ensureTotalCapacity(self.allocator, host.args.len);
                for (host.args) |arg| list.appendAssumeCapacity(try Value.newString(self.allocator, arg));
                const obj = try Object.create(self.allocator, .{ .list = list });
                try self.push(.{ .object = obj });
            },

            .read => {
                const ref_val = try self.pop();
                // `defer` rather than LOAD_INDEX's release-on-the-failing-
                // branch, because `popStream` below can fail FIRST, while
                // this is still potentially a heap object — two exits to
                // cover here, not one.
                defer ref_val.decref(self.allocator);
                const stream = try self.popStream();
                if (ref_val != .array_ref) return RuntimeError.TypeMismatch;
                const ref = ref_val.array_ref;
                try checkBufferRange(ref);

                // A null reader is stdin with no input supplied, i.e.
                // already at its end — a 0-byte read, not a failure.
                const reader = try self.readerFor(host, stream) orelse {
                    try self.push(.{ .int = 0 });
                    return .running;
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
                // Both `defer`red for the same reason as READ's operand
                // above: `popStream` sits between these pops and the type
                // check that would otherwise prove them non-objects.
                defer count_val.decref(self.allocator);
                const ref_val = try self.pop();
                defer ref_val.decref(self.allocator);
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
                defer path_val.decref(self.allocator);
                const path = path_val.asStringBytes() orelse return RuntimeError.TypeMismatch;
                const stream = try self.openFile(host, path, @enumFromInt(instr.operand));
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

            // `exit <expr>` — halts immediately, exactly like HALT
            // (same cleanup, same kind of `return` — success, not a
            // RuntimeError, since `exit(0)` isn't a failure), except the
            // requested code is stashed on `self.exit_code` first so
            // `run`'s caller can propagate it. Reachable from anywhere,
            // including mid-function or several call frames deep:
            // `decrefStack`/`closeAllFiles` already handle that exact
            // shape (see their own doc comments), since a RuntimeError
            // unwinding through an active frame needs the same cleanup.
            .exit => {
                const code_val = try self.pop();
                if (code_val != .int) {
                    // `exit doc` — already popped, so `decrefStack` below
                    // would never reach it. Past here it's an INT, and the
                    // range check needs no release of its own.
                    code_val.decref(self.allocator);
                    return RuntimeError.TypeMismatch;
                }
                if (code_val.int < 0 or code_val.int > 255) return RuntimeError.InvalidExitCode;
                try self.closeAllFiles(host);
                self.decrefStack();
                self.exit_code = @intCast(code_val.int);
                return .halted;
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
                return .halted;
            },
        }
        return .running;
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

test "exit halts immediately, before the next instruction runs" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const three = try chunk.addConstant(allocator, .{ .int = 3 });
    _ = try chunk.emitWithOperand(allocator, .push_const, three);
    _ = try chunk.emit(allocator, .exit);
    // Never reached: exit halts the whole program, not just this statement.
    const ninety_nine = try chunk.addConstant(allocator, .{ .int = 99 });
    _ = try chunk.emitWithOperand(allocator, .push_const, ninety_nine);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &writer });

    try std.testing.expectEqualStrings("", writer.buffered());
    try std.testing.expectEqual(@as(?u8, 3), vm.exit_code);
}

test "a program that never calls exit leaves exit_code null (ordinary halt)" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var writer = std.Io.Writer.fixed(&.{});
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &writer });

    try std.testing.expectEqual(@as(?u8, null), vm.exit_code);
}

test "exit with a non-int value is TypeMismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const idx = try chunk.addConstant(allocator, .{ .boolean = true });
    _ = try chunk.emitWithOperand(allocator, .push_const, idx);
    _ = try chunk.emit(allocator, .exit);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "exit with a negative code is InvalidExitCode" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const idx = try chunk.addConstant(allocator, .{ .int = -1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, idx);
    _ = try chunk.emit(allocator, .exit);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.InvalidExitCode);
}

test "exit with a code above 255 is InvalidExitCode" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const idx = try chunk.addConstant(allocator, .{ .int = 256 });
    _ = try chunk.emitWithOperand(allocator, .push_const, idx);
    _ = try chunk.emit(allocator, .exit);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.InvalidExitCode);
}

test "exit(255) is the top of the valid range, not an off-by-one error" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const idx = try chunk.addConstant(allocator, .{ .int = 255 });
    _ = try chunk.emitWithOperand(allocator, .push_const, idx);
    _ = try chunk.emit(allocator, .exit);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var writer = std.Io.Writer.fixed(&.{});
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &writer });

    try std.testing.expectEqual(@as(?u8, 255), vm.exit_code);
}

test "exit deep inside a nested call skips every remaining frame, not just its own" {
    // Hand-assembled equivalent of:
    //   func fail() -> int { exit 7 }
    //   fail()
    //   print 99   -- never reached
    const allocator = std.testing.allocator;

    var func_chunk: Chunk = .{};
    const seven = try func_chunk.addConstant(allocator, .{ .int = 7 });
    _ = try func_chunk.emitWithOperand(allocator, .push_const, seven);
    _ = try func_chunk.emit(allocator, .exit);
    // Never reached: exit unwinds the whole program, not just this frame,
    // so there is no RET to skip back to the caller — the call below the
    // .call it originated from never sees a result.
    _ = try func_chunk.emit(allocator, .ret);

    var main_chunk: Chunk = .{};
    _ = try main_chunk.emitWithOperand(allocator, .call, 0);
    _ = try main_chunk.emit(allocator, .pop);
    const ninety_nine = try main_chunk.addConstant(allocator, .{ .int = 99 });
    _ = try main_chunk.emitWithOperand(allocator, .push_const, ninety_nine);
    _ = try main_chunk.emit(allocator, .print);
    _ = try main_chunk.emit(allocator, .halt);

    var functions: std.ArrayList(chunk_mod.Function) = .empty;
    try functions.append(allocator, .{ .name = "fail", .arity = 0, .chunk = func_chunk });
    var program = chunk_mod.Program{ .main = main_chunk, .functions = try functions.toOwnedSlice(allocator) };
    defer program.deinit(allocator);

    var vm = Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&program, .{ .out = &writer });

    try std.testing.expectEqualStrings("", writer.buffered());
    try std.testing.expectEqual(@as(?u8, 7), vm.exit_code);
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

test "adding two strings concatenates them into a fresh heap string" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const hello = try chunk.addConstant(allocator, try Value.newString(allocator, "hello, "));
    const world = try chunk.addConstant(allocator, try Value.newString(allocator, "world"));
    _ = try chunk.emitWithOperand(allocator, .push_const, hello);
    _ = try chunk.emitWithOperand(allocator, .push_const, world);
    _ = try chunk.emit(allocator, .add);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("hello, world\n", buf[0..len]);
}

test "adding an empty string to a string is a no-op concatenation" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const empty = try chunk.addConstant(allocator, try Value.newString(allocator, ""));
    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "hi"));
    _ = try chunk.emitWithOperand(allocator, .push_const, empty);
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .add);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("hi\n", buf[0..len]);
}

test "adding a string to an int is a type mismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "x"));
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .add);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "string ordering compares lexicographically by byte, not by length" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    // "ab" < "b" (first differing byte 'a' < 'b'), even though "ab" is longer.
    const ab = try chunk.addConstant(allocator, try Value.newString(allocator, "ab"));
    const b = try chunk.addConstant(allocator, try Value.newString(allocator, "b"));
    _ = try chunk.emitWithOperand(allocator, .push_const, ab);
    _ = try chunk.emitWithOperand(allocator, .push_const, b);
    _ = try chunk.emit(allocator, .lt);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("true\n", buf[0..len]);
}

test "string ordering: a common prefix orders the shorter string first" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const abc = try chunk.addConstant(allocator, try Value.newString(allocator, "abc"));
    const ab = try chunk.addConstant(allocator, try Value.newString(allocator, "ab"));
    _ = try chunk.emitWithOperand(allocator, .push_const, ab);
    _ = try chunk.emitWithOperand(allocator, .push_const, abc);
    _ = try chunk.emit(allocator, .lte);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("true\n", buf[0..len]);
}

test "string ordering: equal strings are neither less nor greater" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const a = try chunk.addConstant(allocator, try Value.newString(allocator, "same"));
    const b = try chunk.addConstant(allocator, try Value.newString(allocator, "same"));
    _ = try chunk.emitWithOperand(allocator, .push_const, a);
    _ = try chunk.emitWithOperand(allocator, .push_const, b);
    _ = try chunk.emit(allocator, .gt);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("false\n", buf[0..len]);
}

test "an empty string orders before any non-empty string" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const empty = try chunk.addConstant(allocator, try Value.newString(allocator, ""));
    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "a"));
    _ = try chunk.emitWithOperand(allocator, .push_const, empty);
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .lt);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("true\n", buf[0..len]);
}

test "comparing a string to a number is a type mismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "1"));
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .lt);
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

    const to_out = try chunk.addConstant(allocator, try Value.newString(allocator, "out"));
    const to_err = try chunk.addConstant(allocator, try Value.newString(allocator, "err"));
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
    const value = try chunk.addConstant(allocator, try Value.newString(allocator, "abc"));
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

    const path = try chunk.addConstant(allocator, try Value.newString(allocator, "nope.txt"));
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

// ---- Directory and filesystem metadata (ISA.bnf section 16) -------------
//
// Only the capability gate and the non-string-operand path are covered
// here, mirroring `open`'s own two VM-level tests above — real successes
// and failures against an actual directory (ListDirFailed, RemoveFailed,
// RenameFailed, the `false`-not-error "absent" paths) need a real
// filesystem, which src/compiler.zig's `runProgramWithFs` (a real
// `std.testing.tmpDir`) provides; this file has none of its own the way
// the Files section above doesn't either.

test "exists/listDir/remove/rename without filesystem access are FilesUnavailable" {
    const allocator = std.testing.allocator;
    inline for (.{ .path_exists, .list_dir, .path_remove }) |op| {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);

        const path = try chunk.addConstant(allocator, try Value.newString(allocator, "nope"));
        _ = try chunk.emitWithOperand(allocator, .push_const, path);
        _ = try chunk.emit(allocator, op);
        _ = try chunk.emit(allocator, .halt);

        try expectRuntimeError(&chunk, RuntimeError.FilesUnavailable);
    }

    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);
    const from = try chunk.addConstant(allocator, try Value.newString(allocator, "a"));
    const to = try chunk.addConstant(allocator, try Value.newString(allocator, "b"));
    _ = try chunk.emitWithOperand(allocator, .push_const, from);
    _ = try chunk.emitWithOperand(allocator, .push_const, to);
    _ = try chunk.emit(allocator, .path_rename);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.FilesUnavailable);
}

test "exists/listDir/remove/rename on a non-string operand are TypeMismatch" {
    const allocator = std.testing.allocator;
    inline for (.{ .path_exists, .list_dir, .path_remove }) |op| {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);

        const not_a_path = try chunk.addConstant(allocator, .{ .int = 7 });
        _ = try chunk.emitWithOperand(allocator, .push_const, not_a_path);
        _ = try chunk.emit(allocator, op);
        _ = try chunk.emit(allocator, .halt);

        try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
    }

    // rename checks BOTH operands: a bad `to` (top of stack) ...
    {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);
        const from = try chunk.addConstant(allocator, try Value.newString(allocator, "a"));
        const not_a_path = try chunk.addConstant(allocator, .{ .int = 7 });
        _ = try chunk.emitWithOperand(allocator, .push_const, from);
        _ = try chunk.emitWithOperand(allocator, .push_const, not_a_path);
        _ = try chunk.emit(allocator, .path_rename);
        _ = try chunk.emit(allocator, .halt);

        try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
    }
    // ... and a bad `from`, even when `to` is fine.
    {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);
        const not_a_path = try chunk.addConstant(allocator, .{ .int = 7 });
        const to = try chunk.addConstant(allocator, try Value.newString(allocator, "b"));
        _ = try chunk.emitWithOperand(allocator, .push_const, not_a_path);
        _ = try chunk.emitWithOperand(allocator, .push_const, to);
        _ = try chunk.emit(allocator, .path_rename);
        _ = try chunk.emit(allocator, .halt);

        try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
    }
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

test "push_args builds a list of the host's args, in order" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emit(allocator, .push_args);
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &writer, .args = &.{ "first", "second" } });
    try std.testing.expectEqualStrings("second\n", buf[0..writer.end]);
}

test "push_args with no host args builds an empty list" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    _ = try chunk.emit(allocator, .push_args);
    _ = try chunk.emit(allocator, .len_value);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("0\n", buf[0..len]);
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

test "index_set on a list out of bounds with a heap-typed replacement value does not leak" {
    // Regression test: INDEX_SET used to incref the replacement value once
    // (for the copy it'd store) but silently rely on the stack's OWN
    // pre-existing claim on that value being "reused" by the final push —
    // which only happens on success. On failure the function returns
    // before that push, so the stack's claim was never released, leaking
    // one reference whenever the replacement value was heap-allocated.
    // std.testing.allocator (via expectRuntimeError/Vm.init) catches the
    // leak if this regresses.
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .make_list, 1);
    const five = try chunk.addConstant(allocator, .{ .int = 5 });
    const replacement = try chunk.addConstant(allocator, try Value.newString(allocator, "replacement"));
    _ = try chunk.emitWithOperand(allocator, .push_const, five);
    _ = try chunk.emitWithOperand(allocator, .push_const, replacement);
    _ = try chunk.emit(allocator, .index_set);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.IndexOutOfBounds);
}

test "index_get on a string produces a fresh length-1 string, not a leak or a double-free" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const hello = try chunk.addConstant(allocator, try Value.newString(allocator, "hello"));
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, hello);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .print); // "e"
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    // std.testing.allocator (via runSource/Vm.init) also catches a leak or
    // double-free here if the fresh string's refcount were ever wrong.
    try std.testing.expectEqualStrings("e\n", buf[0..len]);
}

test "index_get on a string out of bounds is IndexOutOfBounds" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const hi = try chunk.addConstant(allocator, try Value.newString(allocator, "hi"));
    const five = try chunk.addConstant(allocator, .{ .int = 5 });
    _ = try chunk.emitWithOperand(allocator, .push_const, hi);
    _ = try chunk.emitWithOperand(allocator, .push_const, five);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.IndexOutOfBounds);
}

test "index_set on a string is TypeMismatch (strings are read-only)" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const hi = try chunk.addConstant(allocator, try Value.newString(allocator, "hi"));
    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    // The replacement value is itself heap-allocated (a string), so this
    // also covers INDEX_SET's failure path releasing it cleanly instead of
    // leaking — std.testing.allocator catches it if it doesn't.
    const x = try chunk.addConstant(allocator, try Value.newString(allocator, "X"));
    _ = try chunk.emitWithOperand(allocator, .push_const, hi);
    _ = try chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try chunk.emitWithOperand(allocator, .push_const, x);
    _ = try chunk.emit(allocator, .index_set);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "index_slice extracts a substring, end exclusive" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "hello world"));
    const six = try chunk.addConstant(allocator, .{ .int = 6 });
    const eleven = try chunk.addConstant(allocator, .{ .int = 11 });
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emitWithOperand(allocator, .push_const, six);
    _ = try chunk.emitWithOperand(allocator, .push_const, eleven);
    _ = try chunk.emit(allocator, .index_slice);
    _ = try chunk.emit(allocator, .print); // "world"
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("world\n", buf[0..len]);
}

test "index_slice with start == end yields an empty string" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "hi"));
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emit(allocator, .index_slice);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("\n", buf[0..len]);
}

test "index_slice with start > end is IndexOutOfBounds" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "hi"));
    const two = try chunk.addConstant(allocator, .{ .int = 2 });
    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emitWithOperand(allocator, .push_const, two);
    _ = try chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try chunk.emit(allocator, .index_slice);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.IndexOutOfBounds);
}

test "index_slice on a non-string container is TypeMismatch" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .make_list, 1);
    _ = try chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try chunk.emit(allocator, .index_slice);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "make_map and index_get/index_set: insert-then-update round-trips through a local slot" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const name = try chunk.addConstant(allocator, try Value.newString(allocator, "name"));
    const ada = try chunk.addConstant(allocator, try Value.newString(allocator, "Ada"));
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emitWithOperand(allocator, .push_const, ada);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1); // slot 0 = {name: "Ada"}

    const grace = try chunk.addConstant(allocator, try Value.newString(allocator, "Grace"));
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

    const name = try chunk.addConstant(allocator, try Value.newString(allocator, "name"));
    const ada = try chunk.addConstant(allocator, try Value.newString(allocator, "Ada"));
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emitWithOperand(allocator, .push_const, ada);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1);

    const missing = try chunk.addConstant(allocator, try Value.newString(allocator, "missing"));
    _ = try chunk.emitWithOperand(allocator, .push_const, missing);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.KeyNotFound);
}

test "map_has reports presence without erroring on a missing key" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const name = try chunk.addConstant(allocator, try Value.newString(allocator, "name"));
    const ada = try chunk.addConstant(allocator, try Value.newString(allocator, "Ada"));
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emitWithOperand(allocator, .push_const, ada);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1); // slot 0

    _ = try chunk.emitWithOperand(allocator, .load_local, 0);
    _ = try chunk.emitWithOperand(allocator, .push_const, name);
    _ = try chunk.emit(allocator, .map_has);
    _ = try chunk.emit(allocator, .print); // true

    const missing = try chunk.addConstant(allocator, try Value.newString(allocator, "missing"));
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

    const name = try chunk.addConstant(allocator, try Value.newString(allocator, "name"));
    const ada = try chunk.addConstant(allocator, try Value.newString(allocator, "Ada"));
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

    const a = try chunk.addConstant(allocator, try Value.newString(allocator, "a"));
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const b = try chunk.addConstant(allocator, try Value.newString(allocator, "b"));
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

test "len_value reads a list's, a map's, and a string's length" {
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

    const x = try chunk.addConstant(allocator, try Value.newString(allocator, "x"));
    _ = try chunk.emitWithOperand(allocator, .push_const, x);
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .make_map, 1);
    _ = try chunk.emit(allocator, .len_value);
    _ = try chunk.emit(allocator, .print); // 1

    const hello = try chunk.addConstant(allocator, try Value.newString(allocator, "hello"));
    _ = try chunk.emitWithOperand(allocator, .push_const, hello);
    _ = try chunk.emit(allocator, .len_value);
    _ = try chunk.emit(allocator, .print); // 5

    const empty = try chunk.addConstant(allocator, try Value.newString(allocator, ""));
    _ = try chunk.emitWithOperand(allocator, .push_const, empty);
    _ = try chunk.emit(allocator, .len_value);
    _ = try chunk.emit(allocator, .print); // 0
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("3\n1\n5\n0\n", buf[0..len]);
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

    const a = try chunk.addConstant(allocator, try Value.newString(allocator, "a"));
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

    const self_key = try chunk.addConstant(allocator, try Value.newString(allocator, "self"));
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

    const str = try chunk.addConstant(allocator, try Value.newString(allocator, "a\"b"));
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

// ---- Numeric parsing (ISA.bnf section 13) --------------------------------

test "parse_int parses a well-formed integer string, including a negative one" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "-42"));
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .parse_int);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("-42\n", buf[0..len]);
}

test "parse_float parses a well-formed float string, including a negative one" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "-3.5"));
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .parse_float);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("-3.5\n", buf[0..len]);
}

test "parse_float accepts a plain integer-shaped string" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "42"));
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .parse_float);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("42\n", buf[0..len]);
}

test "parse_int on malformed input is NumberParseFailed" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "abc"));
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .parse_int);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.NumberParseFailed);
}

test "parse_int rejects a decimal string rather than truncating" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "3.5"));
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .parse_int);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.NumberParseFailed);
}

test "parse_int/parse_float reject leading or trailing whitespace" {
    const allocator = std.testing.allocator;
    {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);
        const s = try chunk.addConstant(allocator, try Value.newString(allocator, " 42"));
        _ = try chunk.emitWithOperand(allocator, .push_const, s);
        _ = try chunk.emit(allocator, .parse_int);
        _ = try chunk.emit(allocator, .halt);
        try expectRuntimeError(&chunk, RuntimeError.NumberParseFailed);
    }
    {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);
        const s = try chunk.addConstant(allocator, try Value.newString(allocator, "42 "));
        _ = try chunk.emitWithOperand(allocator, .push_const, s);
        _ = try chunk.emit(allocator, .parse_float);
        _ = try chunk.emit(allocator, .halt);
        try expectRuntimeError(&chunk, RuntimeError.NumberParseFailed);
    }
}

test "parse_int/parse_float on an empty string are NumberParseFailed" {
    const allocator = std.testing.allocator;
    {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);
        const s = try chunk.addConstant(allocator, try Value.newString(allocator, ""));
        _ = try chunk.emitWithOperand(allocator, .push_const, s);
        _ = try chunk.emit(allocator, .parse_int);
        _ = try chunk.emit(allocator, .halt);
        try expectRuntimeError(&chunk, RuntimeError.NumberParseFailed);
    }
    {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);
        const s = try chunk.addConstant(allocator, try Value.newString(allocator, ""));
        _ = try chunk.emitWithOperand(allocator, .push_const, s);
        _ = try chunk.emit(allocator, .parse_float);
        _ = try chunk.emit(allocator, .halt);
        try expectRuntimeError(&chunk, RuntimeError.NumberParseFailed);
    }
}

test "parse_int/parse_float on a non-string value is TypeMismatch" {
    const allocator = std.testing.allocator;
    {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);
        _ = try chunk.emit(allocator, .push_true);
        _ = try chunk.emit(allocator, .parse_int);
        _ = try chunk.emit(allocator, .halt);
        try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
    }
    {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);
        const n = try chunk.addConstant(allocator, .{ .int = 5 });
        _ = try chunk.emitWithOperand(allocator, .push_const, n);
        _ = try chunk.emit(allocator, .parse_float);
        _ = try chunk.emit(allocator, .halt);
        try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
    }
}

// ---- int(x)'s float-cast form (GRAMMAR.bnf design note 3r's addendum) ----

test "parse_int on an INT operand is TypeMismatch (no implicit identity cast)" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const n = try chunk.addConstant(allocator, .{ .int = 5 });
    _ = try chunk.emitWithOperand(allocator, .push_const, n);
    _ = try chunk.emit(allocator, .parse_int);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

fn expectParseIntFloat(f: f64, expected: i64) !void {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const n = try chunk.addConstant(allocator, .{ .float = f });
    _ = try chunk.emitWithOperand(allocator, .push_const, n);
    _ = try chunk.emit(allocator, .parse_int);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    var expected_buf: [32]u8 = undefined;
    const expected_str = try std.fmt.bufPrint(&expected_buf, "{d}\n", .{expected});
    try std.testing.expectEqualStrings(expected_str, buf[0..len]);
}

fn expectParseIntFloatOverflow(f: f64) !void {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const n = try chunk.addConstant(allocator, .{ .float = f });
    _ = try chunk.emitWithOperand(allocator, .push_const, n);
    _ = try chunk.emit(allocator, .parse_int);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.Overflow);
}

test "parse_int truncates a positive float toward zero" {
    try expectParseIntFloat(3.9, 3);
}

test "parse_int truncates a negative float toward zero (not floor)" {
    try expectParseIntFloat(-3.9, -3);
}

test "parse_int on an exact-integer float returns it unchanged" {
    try expectParseIntFloat(4.0, 4);
    try expectParseIntFloat(-4.0, -4);
    try expectParseIntFloat(0.0, 0);
}

test "parse_int on a float just inside i64's range succeeds" {
    // 2^62, comfortably inside i64's range and exactly representable in f64.
    try expectParseIntFloat(4611686018427387904.0, 4611686018427387904);
}

test "parse_int on a float at or beyond i64's range is Overflow" {
    // 2^63 exactly: the nearest f64 to i64's true max
    // (9223372036854775807), but itself one past it.
    try expectParseIntFloatOverflow(9223372036854775808.0);
    // One f64 ULP below i64's exact min (-2^63) at this magnitude (ULP
    // spacing here is 2^11 = 2048) — the next representable float past the
    // valid range in the negative direction.
    try expectParseIntFloatOverflow(-9223372036854777856.0);
    try expectParseIntFloatOverflow(1e300);
    try expectParseIntFloatOverflow(-1e300);
}

test "parse_int on NaN or infinity is Overflow" {
    try expectParseIntFloatOverflow(std.math.nan(f64));
    try expectParseIntFloatOverflow(std.math.inf(f64));
    try expectParseIntFloatOverflow(-std.math.inf(f64));
}

// ---- Environment variables (ISA.bnf section 15) --------------------------

/// Runs a one-instruction GET_ENV/HAS_ENV program looking up `name` against
/// `env`, and returns what it printed. `op` is the opcode under test.
fn runEnvLookup(
    buf: []u8,
    op: chunk_mod.OpCode,
    name: []const u8,
    env: []const Host.EnvVar,
) ![]const u8 {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const name_const = try chunk.addConstant(allocator, try Value.newString(allocator, name));
    _ = try chunk.emitWithOperand(allocator, .push_const, name_const);
    _ = try chunk.emit(allocator, op);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var writer = std.Io.Writer.fixed(buf);
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &writer, .env = env });
    return buf[0..writer.end];
}

const test_env = [_]Host.EnvVar{
    .{ .name = "BUTTER_HOME", .value = "/opt/butter" },
    .{ .name = "BUTTER_EMPTY", .value = "" },
};

test "get_env returns a set variable's value" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/opt/butter\n", try runEnvLookup(&buf, .get_env, "BUTTER_HOME", &test_env));
}

test "get_env on an unset variable is the empty string, not an error" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\n", try runEnvLookup(&buf, .get_env, "BUTTER_MISSING", &test_env));
}

// The pair get_env alone can't tell apart, and the whole reason has_env
// exists (GRAMMAR.bnf design note 3v).
test "has_env distinguishes a variable set to \"\" from one that is unset" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\n", try runEnvLookup(&buf, .get_env, "BUTTER_EMPTY", &test_env));
    try std.testing.expectEqualStrings("true\n", try runEnvLookup(&buf, .has_env, "BUTTER_EMPTY", &test_env));
    try std.testing.expectEqualStrings("false\n", try runEnvLookup(&buf, .has_env, "BUTTER_MISSING", &test_env));
}

test "get_env/has_env with no host env at all see every variable as unset" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\n", try runEnvLookup(&buf, .get_env, "BUTTER_HOME", &.{}));
    try std.testing.expectEqualStrings("false\n", try runEnvLookup(&buf, .has_env, "BUTTER_HOME", &.{}));
}

test "get_env matches names byte-exactly, including case" {
    var buf: [64]u8 = undefined;
    // Windows' own environment lookup is case-insensitive; Butter's is not,
    // deliberately, so a program reads the same everywhere.
    try std.testing.expectEqualStrings("\n", try runEnvLookup(&buf, .get_env, "butter_home", &test_env));
    try std.testing.expectEqualStrings("false\n", try runEnvLookup(&buf, .has_env, "butter_home", &test_env));
}

test "a repeated name resolves to its first entry" {
    var buf: [64]u8 = undefined;
    const dupes = [_]Host.EnvVar{
        .{ .name = "SHADOWED", .value = "first" },
        .{ .name = "SHADOWED", .value = "second" },
    };
    try std.testing.expectEqualStrings("first\n", try runEnvLookup(&buf, .get_env, "SHADOWED", &dupes));
}

test "get_env's result is an ordinary heap string, not a borrowed view" {
    // Concatenating it proves it's a real refcounted string value (the same
    // kind `add` builds), not a slice aliasing `Host.env`'s own storage —
    // `Value.newString` is the single choke point that guarantees the copy,
    // and `std.testing.allocator` catches the leak if the extra reference
    // this creates is ever mishandled.
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const name_const = try chunk.addConstant(allocator, try Value.newString(allocator, "BUTTER_HOME"));
    const suffix = try chunk.addConstant(allocator, try Value.newString(allocator, "/bin"));
    _ = try chunk.emitWithOperand(allocator, .push_const, name_const);
    _ = try chunk.emit(allocator, .get_env);
    _ = try chunk.emitWithOperand(allocator, .push_const, suffix);
    _ = try chunk.emit(allocator, .add);
    _ = try chunk.emit(allocator, .print);
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &writer, .env = &test_env });
    try std.testing.expectEqualStrings("/opt/butter/bin\n", buf[0..writer.end]);
}

test "get_env/has_env on a non-string name is TypeMismatch, with no leak" {
    const allocator = std.testing.allocator;
    for ([_]chunk_mod.OpCode{ .get_env, .has_env }) |op| {
        var chunk: Chunk = .{};
        defer chunk.deinit(allocator);

        // A map, so a rejected operand that isn't decreffed leaks a heap
        // object `std.testing.allocator` will catch.
        _ = try chunk.emitWithOperand(allocator, .make_map, 0);
        _ = try chunk.emit(allocator, op);
        _ = try chunk.emit(allocator, .halt);

        var buf: [64]u8 = undefined;
        try std.testing.expectError(RuntimeError.TypeMismatch, runSource(&chunk, &buf));
    }
}

// ---- Discarded-operand reference accounting (TODO #9, step 2) ------------
//
// An instruction that fails must not strand a heap reference. `pop` only
// moves `sp`; it doesn't clear the slot, and the stack teardown on the way
// out of `run` (`decrefStack`) only covers slots BELOW `sp` — so a popped
// object that an error path drops without decreffing is leaked outright.
//
// That was invisible while every runtime error killed the process, but
// `try`/`catch` is going to resume from these paths, so each one has to
// balance its own references. `Value.decref` is a no-op on a non-object, so
// only pops that CAN yield a string/map/list matter — which is what every
// test below forces, by making the discarded operand a heap string and
// letting `std.testing.allocator` fail the test if its refcount never
// reaches zero.

test "a non-stream operand is released, not leaked, when close rejects it" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "not a stream"));
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .close);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "a non-int index is released, not leaked, when load_index rejects it" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "not an index"));
    _ = try chunk.emitWithOperand(allocator, .push_const, one); // slot 0: the array
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emitWithOperand(allocator, .load_index, chunk_mod.packIndexOperand(0, 1));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "both operands are released, not leaked, when store_index rejects its index" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const key = try chunk.addConstant(allocator, try Value.newString(allocator, "not an index"));
    const val = try chunk.addConstant(allocator, try Value.newString(allocator, "the value"));
    _ = try chunk.emitWithOperand(allocator, .push_const, one); // slot 0: the array
    _ = try chunk.emitWithOperand(allocator, .push_const, key);
    _ = try chunk.emitWithOperand(allocator, .push_const, val);
    _ = try chunk.emitWithOperand(allocator, .store_index, chunk_mod.packIndexOperand(0, 1));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "the stored value is released, not leaked, when store_index is out of bounds" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const seven = try chunk.addConstant(allocator, .{ .int = 7 });
    const val = try chunk.addConstant(allocator, try Value.newString(allocator, "the value"));
    _ = try chunk.emitWithOperand(allocator, .push_const, one); // slot 0: the array
    _ = try chunk.emitWithOperand(allocator, .push_const, seven); // out of bounds
    _ = try chunk.emitWithOperand(allocator, .push_const, val);
    _ = try chunk.emitWithOperand(allocator, .store_index, chunk_mod.packIndexOperand(0, 1));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.IndexOutOfBounds);
}

test "a non-int index is released, not leaked, when load_index_ref rejects it" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "not an index"));
    _ = try chunk.emitWithOperand(allocator, .push_const, zero); // slot 0: the array
    _ = try chunk.emitWithOperand(allocator, .make_array_ref, chunk_mod.packIndexOperand(0, 1)); // slot 1: the ref
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emitWithOperand(allocator, .load_index_ref, 1);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "both operands are released, not leaked, when store_index_ref rejects its index" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    const key = try chunk.addConstant(allocator, try Value.newString(allocator, "not an index"));
    const val = try chunk.addConstant(allocator, try Value.newString(allocator, "the value"));
    _ = try chunk.emitWithOperand(allocator, .push_const, zero); // slot 0: the array
    _ = try chunk.emitWithOperand(allocator, .make_array_ref, chunk_mod.packIndexOperand(0, 1)); // slot 1: the ref
    _ = try chunk.emitWithOperand(allocator, .push_const, key);
    _ = try chunk.emitWithOperand(allocator, .push_const, val);
    _ = try chunk.emitWithOperand(allocator, .store_index_ref, 1);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "a non-int count is released, not leaked, when json rejects it" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "not a count"));
    _ = try chunk.emitWithOperand(allocator, .push_const, zero); // slot 0: the buffer
    _ = try chunk.emitWithOperand(allocator, .make_array_ref, chunk_mod.packIndexOperand(0, 1));
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .json_parse);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "a non-int count is released, not leaked, when write_bytes rejects it" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "not a count"));
    try emitBufferFor(&chunk, allocator, .stdout, 1); // buffer, stream, ref
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .write_bytes);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "a non-buffer operand is released, not leaked, when read rejects it" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "not a buffer"));
    try emitStream(&chunk, allocator, .stdin);
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .read);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

// ---- Error handling: handlers and unwinding (ISA.bnf section 14) --------
//
// These drive the runtime directly, the way `tests/cases/` will drive it
// through `try`/`catch` source once the front end lands. Every chunk here is
// hand-assembled into the codegen shape ISA.bnf section 14 specifies:
//
//     PUSH_HANDLER catch_target / <guarded> / POP_HANDLER / JUMP end
//   catch_target:
//     <catch block, with the error map already pushed as its first local>
//   end:

/// Emits PUSH_HANDLER with a placeholder target, returning its index for
/// `closeGuard` to patch.
fn openGuard(chunk: *Chunk, allocator: std.mem.Allocator) !usize {
    return try chunk.emitWithOperand(allocator, .push_handler, 0);
}

/// Closes a guarded region: POP_HANDLER and a JUMP over the catch block,
/// patching the handler's target to the instruction that comes next (where
/// the caller then emits the catch block). Returns the JUMP's index, to be
/// patched once the catch block ends.
fn closeGuard(chunk: *Chunk, allocator: std.mem.Allocator, push_at: usize) !usize {
    _ = try chunk.emit(allocator, .pop_handler);
    const jump_at = try chunk.emitWithOperand(allocator, .jump, 0);
    chunk.patchOperand(push_at, @intCast(chunk.code.items.len));
    return jump_at;
}

/// Emits `print <map at `slot`>[key]` — how these tests read the error map
/// a handler bound, without a DUP opcode to work with: LOAD_LOCAL makes the
/// extra reference INDEX_GET consumes, leaving the map itself in place.
fn emitPrintKey(chunk: *Chunk, allocator: std.mem.Allocator, slot: u32, key: []const u8) !void {
    _ = try chunk.emitWithOperand(allocator, .load_local, slot);
    const k = try chunk.addConstant(allocator, try Value.newString(allocator, key));
    _ = try chunk.emitWithOperand(allocator, .push_const, k);
    _ = try chunk.emit(allocator, .index_get);
    _ = try chunk.emit(allocator, .print);
}

/// `1 / 0` — a compact, reliably catchable failure.
fn emitDivByZero(chunk: *Chunk, allocator: std.mem.Allocator) !void {
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    const zero = try chunk.addConstant(allocator, .{ .int = 0 });
    _ = try chunk.emitWithOperand(allocator, .push_const, one);
    _ = try chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try chunk.emit(allocator, .div);
}

test "a handler catches a runtime error and resumes at its catch block" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const push = try openGuard(&chunk, allocator);
    try emitDivByZero(&chunk, allocator);
    _ = try chunk.emit(allocator, .print); // never reached
    const jump = try closeGuard(&chunk, allocator, push);
    try emitPrintKey(&chunk, allocator, 0, "error");
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("DivisionByZero\n", buf[0..len]);
}

test "the error map describes an error that carries no diagnostic" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const push = try openGuard(&chunk, allocator);
    try emitDivByZero(&chunk, allocator);
    const jump = try closeGuard(&chunk, allocator, push);
    try emitPrintKey(&chunk, allocator, 0, "error");
    try emitPrintKey(&chunk, allocator, 0, "message");
    try emitPrintKey(&chunk, allocator, 0, "operation");
    try emitPrintKey(&chunk, allocator, 0, "path");
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .halt);

    var buf: [128]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    // operation/path are empty rather than absent, so a program can read
    // them unconditionally (GRAMMAR.bnf design note 3u).
    try std.testing.expectEqualStrings("DivisionByZero\nDivisionByZero\n\n\n", buf[0..len]);
}

test "the error map carries the operation and path of a file failure" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    // No `fs` on the Host (runSource supplies none), so this is
    // FilesUnavailable — one of the errors that sets `Vm.diagnostic`.
    const push = try openGuard(&chunk, allocator);
    const path = try chunk.addConstant(allocator, try Value.newString(allocator, "data.txt"));
    _ = try chunk.emitWithOperand(allocator, .push_const, path);
    _ = try chunk.emitWithOperand(allocator, .open, @intFromEnum(value_mod.OpenMode.read));
    const jump = try closeGuard(&chunk, allocator, push);
    try emitPrintKey(&chunk, allocator, 0, "error");
    try emitPrintKey(&chunk, allocator, 0, "message");
    try emitPrintKey(&chunk, allocator, 0, "operation");
    try emitPrintKey(&chunk, allocator, 0, "path");
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .halt);

    var buf: [256]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings(
        \\FilesUnavailable
        \\open 'data.txt': this program was run without filesystem access
        \\open
        \\data.txt
        \\
    , buf[0..len]);
}

test "a guarded block that finishes normally leaves no handler behind" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const push = try openGuard(&chunk, allocator);
    const ok = try chunk.addConstant(allocator, .{ .int = 7 });
    _ = try chunk.emitWithOperand(allocator, .push_const, ok);
    _ = try chunk.emit(allocator, .pop);
    const jump = try closeGuard(&chunk, allocator, push);
    _ = try chunk.emit(allocator, .print); // catch block, must not run
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));
    // The handler is spent, so this one has nothing to catch it.
    try emitDivByZero(&chunk, allocator);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.DivisionByZero);
}

test "an error raised inside a catch block is not caught by its own handler" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const push = try openGuard(&chunk, allocator);
    try emitDivByZero(&chunk, allocator);
    const jump = try closeGuard(&chunk, allocator, push);
    // The handler was consumed on the way in here, so this second failure
    // has nowhere to go.
    try emitDivByZero(&chunk, allocator);
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.DivisionByZero);
}

test "the innermost of two nested handlers is the one that catches" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const inner_label = try chunk.addConstant(allocator, try Value.newString(allocator, "inner"));
    const outer_label = try chunk.addConstant(allocator, try Value.newString(allocator, "outer"));

    const outer_push = try openGuard(&chunk, allocator);
    const inner_push = try openGuard(&chunk, allocator);
    try emitDivByZero(&chunk, allocator);
    const inner_jump = try closeGuard(&chunk, allocator, inner_push);
    _ = try chunk.emitWithOperand(allocator, .push_const, inner_label);
    _ = try chunk.emit(allocator, .print);
    chunk.patchOperand(inner_jump, @intCast(chunk.code.items.len));
    const outer_jump = try closeGuard(&chunk, allocator, outer_push);
    _ = try chunk.emitWithOperand(allocator, .push_const, outer_label);
    _ = try chunk.emit(allocator, .print);
    chunk.patchOperand(outer_jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("inner\n", buf[0..len]);
}

test "everything the abandoned region pushed is released, not leaked" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    // Two heap strings are live on the stack when the failure happens; the
    // testing allocator is what checks unwinding released them.
    const a = try chunk.addConstant(allocator, try Value.newString(allocator, "still on the stack"));
    const b = try chunk.addConstant(allocator, try Value.newString(allocator, "and so is this"));
    const push = try openGuard(&chunk, allocator);
    _ = try chunk.emitWithOperand(allocator, .push_const, a);
    _ = try chunk.emitWithOperand(allocator, .push_const, b);
    try emitDivByZero(&chunk, allocator);
    const jump = try closeGuard(&chunk, allocator, push);
    try emitPrintKey(&chunk, allocator, 0, "error");
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .halt);

    var buf: [64]u8 = undefined;
    const len = try runSource(&chunk, &buf);
    try std.testing.expectEqualStrings("DivisionByZero\n", buf[0..len]);
}

test "an error several frames deep unwinds to the handler's own frame" {
    const allocator = std.testing.allocator;

    // func fails() -> int { return 1 / 0 }   (via a second frame, to prove
    // unwinding crosses more than one)
    var inner_chunk: Chunk = .{};
    try emitDivByZero(&inner_chunk, allocator);
    _ = try inner_chunk.emit(allocator, .ret);

    var outer_chunk: Chunk = .{};
    _ = try outer_chunk.emitWithOperand(allocator, .call, 0);
    _ = try outer_chunk.emit(allocator, .ret);

    var main_chunk: Chunk = .{};
    const push = try openGuard(&main_chunk, allocator);
    _ = try main_chunk.emitWithOperand(allocator, .call, 1);
    _ = try main_chunk.emit(allocator, .pop);
    const jump = try closeGuard(&main_chunk, allocator, push);
    try emitPrintKey(&main_chunk, allocator, 0, "error");
    main_chunk.patchOperand(jump, @intCast(main_chunk.code.items.len));
    _ = try main_chunk.emit(allocator, .halt);

    var functions: std.ArrayList(chunk_mod.Function) = .empty;
    try functions.append(allocator, .{ .name = "inner", .arity = 0, .chunk = inner_chunk });
    try functions.append(allocator, .{ .name = "outer", .arity = 0, .chunk = outer_chunk });
    var program = chunk_mod.Program{ .main = main_chunk, .functions = try functions.toOwnedSlice(allocator) };
    defer program.deinit(allocator);

    var vm = Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&program, .{ .out = &writer });
    try std.testing.expectEqualStrings("DivisionByZero\n", writer.buffered());
}

test "returning out of a guarded block takes its handler with it" {
    const allocator = std.testing.allocator;

    // func f() -> int { try { return 0 } catch e { print "caught"; return e } }
    // — the handler is installed and then abandoned by the `return`.
    //
    // The marker print is what gives this test teeth. A stale handler is
    // NOT observable through the error alone: main's failure would resume
    // in f's dead catch block, whose RET hands the error map back to main
    // as if the original call had returned it, and main then reaches the
    // very same division a second time — reporting DivisionByZero either
    // way. Only the catch block having run at all distinguishes them.
    var func_chunk: Chunk = .{};
    const push = try openGuard(&func_chunk, allocator);
    const zero = try func_chunk.addConstant(allocator, .{ .int = 0 });
    _ = try func_chunk.emitWithOperand(allocator, .push_const, zero);
    _ = try func_chunk.emit(allocator, .ret);
    const jump = try closeGuard(&func_chunk, allocator, push);
    const marker = try func_chunk.addConstant(allocator, try Value.newString(allocator, "caught"));
    _ = try func_chunk.emitWithOperand(allocator, .push_const, marker);
    _ = try func_chunk.emit(allocator, .print);
    _ = try func_chunk.emit(allocator, .ret);
    func_chunk.patchOperand(jump, @intCast(func_chunk.code.items.len));

    var main_chunk: Chunk = .{};
    _ = try main_chunk.emitWithOperand(allocator, .call, 0);
    _ = try main_chunk.emit(allocator, .pop);
    try emitDivByZero(&main_chunk, allocator);
    _ = try main_chunk.emit(allocator, .halt);

    var functions: std.ArrayList(chunk_mod.Function) = .empty;
    try functions.append(allocator, .{ .name = "f", .arity = 0, .chunk = func_chunk });
    var program = chunk_mod.Program{ .main = main_chunk, .functions = try functions.toOwnedSlice(allocator) };
    defer program.deinit(allocator);

    var vm = Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(RuntimeError.DivisionByZero, vm.run(&program, .{ .out = &writer }));
    try std.testing.expectEqualStrings("", writer.buffered());
}

test "a VM-integrity failure escapes even with a handler installed" {
    const allocator = std.testing.allocator;

    // func recurse() -> int { return recurse() }
    var func_chunk: Chunk = .{};
    _ = try func_chunk.emitWithOperand(allocator, .call, 0);
    _ = try func_chunk.emit(allocator, .ret);

    var main_chunk: Chunk = .{};
    const push = try openGuard(&main_chunk, allocator);
    _ = try main_chunk.emitWithOperand(allocator, .call, 0);
    const jump = try closeGuard(&main_chunk, allocator, push);
    _ = try main_chunk.emit(allocator, .print); // catch block, must not run
    main_chunk.patchOperand(jump, @intCast(main_chunk.code.items.len));
    _ = try main_chunk.emit(allocator, .halt);

    var functions: std.ArrayList(chunk_mod.Function) = .empty;
    try functions.append(allocator, .{ .name = "recurse", .arity = 0, .chunk = func_chunk });
    var program = chunk_mod.Program{ .main = main_chunk, .functions = try functions.toOwnedSlice(allocator) };
    defer program.deinit(allocator);

    var vm = Vm.init(allocator);
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(RuntimeError.CallStackOverflow, vm.run(&program, .{ .out = &writer }));
}

test "more nested handlers than the table holds is HandlerStackOverflow" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    // One past the table's capacity — and not catchable by any of the 64
    // handlers already installed.
    var i: usize = 0;
    while (i <= max_handlers) : (i += 1) _ = try chunk.emitWithOperand(allocator, .push_handler, 0);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.HandlerStackOverflow);
}

test "exit inside a guarded block still exits, uncatchably" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const push = try openGuard(&chunk, allocator);
    const code = try chunk.addConstant(allocator, .{ .int = 3 });
    _ = try chunk.emitWithOperand(allocator, .push_const, code);
    _ = try chunk.emit(allocator, .exit);
    const jump = try closeGuard(&chunk, allocator, push);
    _ = try chunk.emit(allocator, .print); // catch block, must not run
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .halt);

    var vm = Vm.init(allocator);
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const program = chunk_mod.Program{ .main = chunk, .functions = &.{} };
    try vm.run(&program, .{ .out = &writer });
    // `exit` is not an error, so no handler ever sees it (GRAMMAR.bnf
    // design note 3u).
    try std.testing.expectEqual(@as(?u8, 3), vm.exit_code);
    try std.testing.expectEqualStrings("", writer.buffered());
}

test "a non-int exit code is released, not leaked, when exit rejects it" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const s = try chunk.addConstant(allocator, try Value.newString(allocator, "not a code"));
    _ = try chunk.emitWithOperand(allocator, .push_const, s);
    _ = try chunk.emit(allocator, .exit);
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.TypeMismatch);
}

test "every RuntimeError variant has the catchability ISA.bnf section 14 documents" {
    // The whole enum, listed by hand rather than reflected over, so that
    // adding a variant fails this test until someone decides which half it
    // belongs in — the same reason `catchable` itself enumerates rather
    // than testing by exclusion. This is also the only per-variant coverage
    // `StreamReadFailed` and `FileCloseFailed` can get: both need a genuine
    // OS-level I/O failure to raise, which no test program can provoke.
    const catchable_variants = [_]RuntimeError{
        RuntimeError.TypeMismatch,
        RuntimeError.DivisionByZero,
        RuntimeError.Overflow,
        RuntimeError.IndexOutOfBounds,
        RuntimeError.ByteOutOfRange,
        RuntimeError.StreamReadFailed,
        RuntimeError.StreamWriteFailed,
        RuntimeError.FileOpenFailed,
        RuntimeError.TooManyOpenFiles,
        RuntimeError.FileCloseFailed,
        RuntimeError.StreamNotReadable,
        RuntimeError.StreamNotWritable,
        RuntimeError.StreamClosed,
        RuntimeError.CannotCloseStandardStream,
        RuntimeError.FilesUnavailable,
        RuntimeError.KeyNotFound,
        RuntimeError.JsonParseFailed,
        RuntimeError.NumberParseFailed,
        RuntimeError.InvalidExitCode,
        RuntimeError.ListDirFailed,
        RuntimeError.RemoveFailed,
        RuntimeError.RenameFailed,
    };
    const uncatchable_variants = [_]RuntimeError{
        RuntimeError.StackOverflow,
        RuntimeError.StackUnderflow,
        RuntimeError.CallStackOverflow,
        RuntimeError.HandlerStackOverflow,
    };
    // Every variant appears in exactly one of the two lists above.
    try std.testing.expectEqual(
        @typeInfo(RuntimeError).error_set.?.len,
        catchable_variants.len + uncatchable_variants.len,
    );

    for (catchable_variants) |err| try std.testing.expect(Vm.catchable(err));
    for (uncatchable_variants) |err| try std.testing.expect(!Vm.catchable(err));

    // Not a RuntimeError at all: building the error map allocates, so a
    // handler for this could not run (ISA.bnf section 14).
    try std.testing.expect(!Vm.catchable(error.OutOfMemory));
}

test "a value-stack overflow escapes even with a handler installed" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const push = try openGuard(&chunk, allocator);
    const one = try chunk.addConstant(allocator, .{ .int = 1 });
    var i: usize = 0;
    while (i <= stack_max) : (i += 1) _ = try chunk.emitWithOperand(allocator, .push_const, one);
    const jump = try closeGuard(&chunk, allocator, push);
    _ = try chunk.emit(allocator, .print); // catch block, must not run
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.StackOverflow);
}

test "a value-stack underflow escapes even with a handler installed" {
    const allocator = std.testing.allocator;
    var chunk: Chunk = .{};
    defer chunk.deinit(allocator);

    const push = try openGuard(&chunk, allocator);
    _ = try chunk.emit(allocator, .pop); // nothing on the stack to pop
    const jump = try closeGuard(&chunk, allocator, push);
    _ = try chunk.emit(allocator, .print); // catch block, must not run
    chunk.patchOperand(jump, @intCast(chunk.code.items.len));
    _ = try chunk.emit(allocator, .halt);

    try expectRuntimeError(&chunk, RuntimeError.StackUnderflow);
}
