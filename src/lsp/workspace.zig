//! One-shot analysis of a document's whole import graph — the layer that
//! turns "current buffer text" into "everything hover/definition/
//! completion/diagnostics need", by driving the real `module.Loader` and
//! `compiler.Compiler` exactly like `src/main.zig` does, then building a
//! `symbols.FileSymbols` (+ token cache, for position recovery) for every
//! module reached.
//!
//! Every open document is analyzed as its OWN entry point (the same thing
//! `butter path/to/file.butter` would do) — Butter has no project-manifest
//! concept naming a single "real" entry point, and any file is a legal one
//! (module.zig's own `loadEntry`). A file that's only ever imported by
//! others still gets correct diagnostics/symbols this way.
//!
//! This module is stateless/functional — `analyze` always starts a fresh
//! `module.Loader`. Keeping the *previous* successful analysis around
//! across edits (for the "stale but valid tree" fallback while the
//! current buffer has a syntax error) is documents.zig's job, not this
//! one's.

const std = @import("std");
const butter = @import("butter");
const module = butter.module;
const compiler_mod = butter.compiler;
const stdlib = butter.stdlib;
const tk = @import("tokens.zig");
const symbols = @import("symbols.zig");

pub const ModuleAnalysis = struct {
    mod: *module.Module,
    tokens: []const tk.Token,
    symbols: symbols.FileSymbols,
    /// This module's own source text — `tokens` was tokenized from
    /// exactly this, so it's also the right text to pass to
    /// `tk.Position.toUtf16`/`fromUtf16` for any position of this
    /// module's own.
    text: []const u8,
};

/// At most one diagnostic per analysis pass — both `module.Loader` and
/// `compiler.Compiler` are fail-fast (the first error stops the whole
/// pass), so a single `analyze` call can never surface more than one new
/// problem. `column` is 1-based when known; a compiler (semantic)
/// diagnostic only ever carries a line, so `diagnostics.zig` recovers a
/// column itself by re-scanning that line for `name`.
pub const Diag = struct {
    path: []const u8,
    line: ?usize,
    column: ?usize,
    name: []const u8 = "",
    message: []const u8,
};

pub const Analysis = struct {
    /// Heap-allocated (not embedded by value) deliberately: `module.Loader`
    /// embeds a `std.heap.ArenaAllocator`, and `ArenaAllocator.allocator()`
    /// returns a handle pinned to that struct's OWN address — every
    /// `loader.allocator()` call below (building `modules`, tokens,
    /// symbols) happens while `analyze` still owns `loader` on its own
    /// stack, so returning it BY VALUE out of this function (moving it to
    /// a new address) would silently invalidate every one of those
    /// already-captured allocator handles. Pinning it behind a stable
    /// heap allocation instead is the same fix `std.json.Parsed(T)` uses
    /// for the identical problem (see std/json/static.zig).
    loader: *module.Loader,
    gpa: std.mem.Allocator,
    entry: *module.Module,
    /// Every module in `entry`'s transitive import graph, entry included,
    /// keyed by `module.Module.path`. Only absent an entry when that
    /// module's source couldn't be re-read for tokenizing after the
    /// loader itself already succeeded (see `analyze`'s doc comment on
    /// `rereadSource`) — a rare, gracefully-degraded case, not an error.
    modules: std.StringHashMap(ModuleAnalysis),
    diagnostic: ?Diag,

    pub fn deinit(self: *Analysis) void {
        self.modules.deinit();
        self.loader.deinit();
        self.gpa.destroy(self.loader);
    }

    pub fn findModule(self: *const Analysis, path: []const u8) ?ModuleAnalysis {
        return self.modules.get(path);
    }
};

/// A failed analysis: `module.Loader` itself couldn't even produce a
/// module graph (a lex/parse error anywhere in it, or a module-resolution
/// problem — file not found, a circular import, ...). `path`/`message`
/// are `gpa`-owned (NOT arena-owned — there is no surviving `Loader` to
/// anchor them to, so documents.zig must free them once superseded).
pub const LoadFailure = struct {
    path: []const u8,
    line: ?usize,
    message: []const u8,

    pub fn deinit(self: LoadFailure, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.message);
    }
};

pub const Result = union(enum) {
    ok: Analysis,
    fail: LoadFailure,
};

/// Runs one full analysis pass for the document at `key` (its canonical
/// path, or a sentinel like documents.zig uses for an unsaved buffer),
/// whose current text is `source`, with `dir` as the directory its own
/// `import`s resolve against (mirroring `main.zig`'s own entry-file
/// handling). Never mutates any existing `Analysis` — the caller decides
/// whether to replace one with this result.
fn destroyLoader(gpa: std.mem.Allocator, loader: *module.Loader) void {
    loader.deinit();
    gpa.destroy(loader);
}

pub fn analyze(gpa: std.mem.Allocator, io: std.Io, source: []const u8, key: []const u8, dir: []const u8) std.mem.Allocator.Error!Result {
    const loader = try gpa.create(module.Loader);
    loader.* = module.Loader.init(gpa, io, std.Io.Dir.cwd());

    // `loader.loadEntry` (module.zig) lexes `source` directly — every
    // token's `lexeme`, and hence every AST field derived from one (e.g.
    // `FunctionDecl.name`), ends up a slice INTO `source` itself, on the
    // documented assumption that the CALLER keeps it alive for as long as
    // the resulting `Module`/AST is used (true for the CLI, which reads
    // its file once and holds the buffer for the whole process — see
    // `loadEntry`'s own doc comment). `documents.zig` can't honor that:
    // `Document.text` is freed and replaced on every edit, including ones
    // whose reanalysis FAILS to even load (`Document.good` is
    // deliberately kept alive across exactly those, per its own doc
    // comment) — without this copy, that retained `good` analysis (AST,
    // tokens, symbol names) would alias freed memory the moment the next
    // edit's `documents.change` runs. Duping into the loader's own arena
    // BEFORE parsing decouples the whole `Analysis` from `source`'s
    // lifetime; `rereadSource` below inherits the safe copy too (it's
    // passed `owned_source`, not `source`).
    const owned_source = loader.allocator().dupe(u8, source) catch |err| {
        destroyLoader(gpa, loader);
        return err;
    };

    const entry = loader.loadEntry(owned_source, key, dir) catch |err| {
        if (err == error.OutOfMemory) {
            destroyLoader(gpa, loader);
            return error.OutOfMemory;
        }
        const diag = loader.diagnostic.?;
        const path_copy = gpa.dupe(u8, diag.path) catch |e| {
            destroyLoader(gpa, loader);
            return e;
        };
        const message_copy = gpa.dupe(u8, diag.message) catch |e| {
            gpa.free(path_copy);
            destroyLoader(gpa, loader);
            return e;
        };
        destroyLoader(gpa, loader);
        return .{ .fail = .{ .path = path_copy, .line = diag.line, .message = message_copy } };
    };

    var modules: std.StringHashMap(ModuleAnalysis) = .init(loader.allocator());
    for (loader.order.items) |m| {
        const text = rereadSource(loader.allocator(), io, m, entry, owned_source) orelse continue;
        const toks = tk.tokenize(loader.allocator(), text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The loader already lexed this exact text successfully
            // moments ago (or it's the in-memory buffer we were handed
            // directly) — a lex error re-tokenizing it here would mean
            // the on-disk file changed out from under us mid-analysis.
            // Degrade the same way a re-read failure does, below, rather
            // than failing the whole pass over one file's position data.
            else => continue,
        };
        const file_symbols = symbols.build(loader.allocator(), m.program, toks, text) catch |err| return err;
        for (file_symbols.imports, 0..) |*imp, i| {
            if (i < m.imports.len) imp.resolved = m.imports[i];
        }
        try modules.put(m.path, .{ .mod = m, .tokens = toks, .symbols = file_symbols, .text = text });
    }

    var compiler = compiler_mod.Compiler.init(gpa);
    defer compiler.deinit();
    const units = module.toCompilerUnits(loader.allocator(), loader.order.items, entry) catch |err| return err;
    var diag: ?Diag = null;
    if (compiler.compileModules(units.entry_index, units.units)) |chunk| {
        // Diagnostics-only: the compiled chunk itself is never run or
        // inspected, only compiled far enough to know whether it COULD
        // compile — see this file's own doc comment.
        var owned_chunk = chunk;
        owned_chunk.deinit(gpa);
    } else |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const d = compiler.diagnostic.?;
        diag = .{ .path = d.path, .line = d.line, .column = null, .name = d.name, .message = d.message };
    }

    return .{ .ok = .{ .loader = loader, .gpa = gpa, .entry = entry, .modules = modules, .diagnostic = diag } };
}

/// The source text to tokenize for module `m` — the in-memory buffer
/// itself for the entry module (already an arena-owned copy by the time
/// this is called — see `analyze`'s own doc comment on `owned_source` for
/// why that copy has to happen), the bundled stdlib text for a
/// `.std.butter` import (`stdlib.lookup`, no disk I/O — a static
/// constant, safe to borrow), or a fresh read from disk for an ordinary
/// file import. `module.Loader` already read (and lexed) this exact
/// content once internally but doesn't retain it on `Module` (see this
/// file's own doc comment) — this is a deliberate, accepted re-read, not
/// a bug. Returns `null` (rather than failing the whole analysis) if that
/// re-read fails, e.g. the file was deleted between the loader's own read
/// and this one.
fn rereadSource(arena: std.mem.Allocator, io: std.Io, m: *module.Module, entry: *module.Module, entry_source: []const u8) ?[]const u8 {
    if (m == entry) return entry_source;
    if (stdlib.lookup(m.path)) |std_source| return std_source;
    return std.Io.Dir.cwd().readFileAlloc(io, m.path, arena, .unlimited) catch null;
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;

test "analyze succeeds on a single-file program with no diagnostic" {
    const gpa = testing.allocator;
    var result = try analyze(gpa, testing.io, "print 1\n", "<test>", ".");
    switch (result) {
        .ok => |*a| {
            defer a.deinit();
            try testing.expect(a.diagnostic == null);
            try testing.expect(a.findModule("<test>") != null);
        },
        .fail => return error.TestUnexpectedResult,
    }
}

test "analyze surfaces a syntax error as a LoadFailure with a line" {
    const gpa = testing.allocator;
    const result = try analyze(gpa, testing.io, "int x @ 1\n", "<test>", ".");
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .fail => |f| {
            defer f.deinit(gpa);
            try testing.expectEqual(@as(?usize, 1), f.line);
        },
    }
}

test "analyze surfaces a semantic error as an Analysis diagnostic, not a LoadFailure" {
    const gpa = testing.allocator;
    var result = try analyze(gpa, testing.io, "print undefinedThing\n", "<test>", ".");
    switch (result) {
        .ok => |*a| {
            defer a.deinit();
            try testing.expect(a.diagnostic != null);
            try testing.expectEqualStrings("<test>", a.diagnostic.?.path);
        },
        .fail => return error.TestUnexpectedResult,
    }
}

test "analyze builds symbols for an imported stdlib module too" {
    const gpa = testing.allocator;
    var result = try analyze(gpa, testing.io, "import \"math.std.butter\"\nprint abs(-1)\n", "<test>", ".");
    switch (result) {
        .ok => |*a| {
            defer a.deinit();
            const math_mod = a.findModule("math.std.butter");
            try testing.expect(math_mod != null);
            try testing.expect(math_mod.?.symbols.findFunction("abs") != null);

            const entry_mod = a.findModule("<test>").?;
            try testing.expectEqual(@as(usize, 1), entry_mod.symbols.imports.len);
            try testing.expect(entry_mod.symbols.imports[0].resolved != null);
        },
        .fail => return error.TestUnexpectedResult,
    }
}
