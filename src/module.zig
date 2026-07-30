//! Multi-file module loading for `import` (see GRAMMAR.bnf design note h
//! and ISA.bnf section 8). `Loader` recursively lexes and parses every
//! file reachable from an entry program, memoizing each one by a
//! lexically normalized path so a file reached via more than one import
//! path — a "diamond" — is read, tokenized, and parsed exactly once. That
//! memoization is also what the compiler relies on for deduping generated
//! code: `compiler.compileModules` compiles whatever `Loader.order` hands
//! it, and a module never appears in `order` more than once.
//!
//! An import path is checked against `stdlib.lookup` before it is ever
//! resolved against the filesystem — a reserved `.std.butter` name (e.g.
//! `"math.std.butter"`) resolves to Butter source bundled into the
//! `butter` binary itself (see stdlib.zig), keyed by that bare name rather
//! than a path resolved against the importing file's directory, so it
//! imports the same way from anywhere.

const std = @import("std");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const ast = @import("ast.zig");
const compiler_mod = @import("compiler.zig");
const stdlib = @import("stdlib.zig");

pub const Diagnostic = struct {
    /// The canonical path of the file the error occurred in (or while
    /// trying to read).
    path: []const u8,
    message: []const u8,
};

/// Errors the loader itself raises; detail is left in `Loader.diagnostic`.
/// Also folds in the lexer's and parser's own error sets, since loading a
/// module means lexing and parsing it — a lex/parse failure in an
/// imported file is reported exactly like one in the entry file, just
/// tagged with which file it came from.
pub const LoadError = error{
    ImportReadFailed,
    CircularImport,
    ImportedFileHasTopLevelCode,
} || lexer_mod.Error || parser_mod.Error || std.mem.Allocator.Error;

/// One loaded file: its parsed program, plus the modules it directly
/// `import`s (in source order). `path` is the lexically normalized key
/// `Loader` deduplicates on — two different relative spellings of the
/// same file resolve to the same `path` and thus the same `*Module`.
pub const Module = struct {
    path: []const u8,
    program: ast.Program,
    /// Direct imports only — deliberately not transitive. This is what
    /// `compiler.zig`'s `functionVisible` uses to reject calling a
    /// function that belongs to an import-of-an-import (no automatic
    /// re-export; GRAMMAR.bnf design note h).
    imports: []const *Module,
};

/// Recursively loads an entry program and everything it transitively
/// imports. Every allocation the loader itself makes (read file sources,
/// token slices, parser arenas, path strings, `Module` structs) lives in
/// one internal arena freed in one shot by `deinit` — mirroring how
/// `parser.Parser` owns its own AST nodes, just one level up, since a
/// `Module`'s AST must stay alive for every importer that shares it, not
/// just the first one to reach it.
pub const Loader = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    /// Directory imports resolve against; real code passes
    /// `std.Io.Dir.cwd()`, tests pass an isolated `std.testing.tmpDir`.
    root: std.Io.Dir,
    loaded: std.StringHashMap(*Module),
    /// Canonical paths currently being loaded, innermost last — used only
    /// to detect a cycle (a path re-encountered while it's still on this
    /// stack, i.e. not yet fully loaded). Unrelated to `order`.
    stack: std.ArrayList([]const u8) = .empty,
    /// Every module that finished loading, in dependency-first order and
    /// each appearing exactly once — see the module-level doc comment.
    order: std.ArrayList(*Module) = .empty,
    diagnostic: ?Diagnostic = null,

    pub fn init(child_allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) Loader {
        return .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
            .io = io,
            .root = root,
            .loaded = std.StringHashMap(*Module).init(child_allocator),
        };
    }

    pub fn deinit(self: *Loader) void {
        self.loaded.deinit();
        self.arena.deinit();
    }

    /// The allocator backing every `Module`/path/source/token this loader
    /// produces. Exposed so callers can build derived data (see
    /// `toCompilerUnits`) that shares the loader's lifetime instead of
    /// needing its own separate cleanup.
    pub fn allocator(self: *Loader) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn fail(self: *Loader, comptime err: LoadError, path: []const u8, message: []const u8) LoadError {
        self.diagnostic = .{ .path = path, .message = message };
        return err;
    }

    /// Loads the entry program. `source` is already-read text (the CLI
    /// reads it itself, since it also has to support `--stdin`); `key` is
    /// its canonical path (or a sentinel like `"<stdin>"` when there is no
    /// real path) and `dir` is the directory its own `import`s resolve
    /// against.
    pub fn loadEntry(self: *Loader, source: []const u8, key: []const u8, dir: []const u8) LoadError!*Module {
        return self.loadModule(source, key, dir, true);
    }

    fn readFile(self: *Loader, path: []const u8) ![]const u8 {
        return self.root.readFileAlloc(self.io, path, self.allocator(), .unlimited);
    }

    /// `allow_top_level_code` is true only for the entry module — an
    /// imported file may declare only `import`s and functions (see
    /// GRAMMAR.bnf design note h): there is no notion of "running" an
    /// imported file's own top-level statements, so it simply isn't
    /// allowed to have any.
    fn loadModule(self: *Loader, source: []const u8, key: []const u8, dir: []const u8, allow_top_level_code: bool) LoadError!*Module {
        if (self.loaded.get(key)) |m| return m;
        for (self.stack.items) |s| {
            if (std.mem.eql(u8, s, key)) return self.fail(LoadError.CircularImport, key, "circular import");
        }
        try self.stack.append(self.allocator(), key);
        defer _ = self.stack.pop();

        var lex = lexer_mod.Lexer.init(source);
        const tokens = lex.tokenizeAll(self.allocator()) catch |err| {
            self.diagnostic = .{ .path = key, .message = lex.diagnostic.?.message };
            return err;
        };

        var parser = parser_mod.Parser.init(self.allocator(), tokens);
        const program = parser.parseProgram() catch |err| {
            self.diagnostic = .{ .path = key, .message = parser.diagnostic.?.message };
            return err;
        };

        if (!allow_top_level_code) {
            for (program) |*stmt| {
                switch (stmt.*) {
                    .function_decl, .import_stmt => {},
                    else => return self.fail(
                        LoadError.ImportedFileHasTopLevelCode,
                        key,
                        "an imported file may only contain 'import' statements and function declarations",
                    ),
                }
            }
        }

        var import_list: std.ArrayList(*Module) = .empty;
        for (program) |*stmt| {
            if (stmt.* != .import_stmt) continue;
            // A bundled standard-library module (reserved `.std.butter`
            // name) is matched before ever touching the filesystem, and by
            // its bare name rather than a path resolved against `dir` — it
            // has no real file/directory of its own, so it resolves the
            // same way regardless of which directory imports it.
            if (stdlib.lookup(stmt.import_stmt.path)) |std_source| {
                const child_key = try self.allocator().dupe(u8, stmt.import_stmt.path);
                const child = try self.loadModule(std_source, child_key, ".", false);
                try import_list.append(self.allocator(), child);
                continue;
            }
            const child_key = try std.fs.path.resolve(self.allocator(), &.{ dir, stmt.import_stmt.path });
            const child_dir = std.fs.path.dirname(child_key) orelse ".";
            const child_source = self.readFile(child_key) catch |err| {
                self.diagnostic = .{ .path = child_key, .message = @errorName(err) };
                return LoadError.ImportReadFailed;
            };
            const child = try self.loadModule(child_source, child_key, child_dir, false);
            try import_list.append(self.allocator(), child);
        }

        const module = try self.allocator().create(Module);
        module.* = .{ .path = key, .program = program, .imports = try import_list.toOwnedSlice(self.allocator()) };
        try self.loaded.put(key, module);
        try self.order.append(self.allocator(), module);
        return module;
    }
};

/// Flattens a loaded module graph into the `[]compiler.ModuleUnit` +
/// entry index `compiler.Compiler.compileModules` expects — translating
/// each `Module`'s `imports` (pointers) into indices into `order` (which
/// is exactly the array `compileModules` will iterate).
///
/// `allocator` is expected to be the same `Loader.allocator()` the modules
/// themselves came from, so the returned slices are cleaned up by the same
/// `Loader.deinit` call rather than needing their own.
pub fn toCompilerUnits(allocator: std.mem.Allocator, order: []const *Module, entry: *Module) std.mem.Allocator.Error!struct {
    entry_index: usize,
    units: []compiler_mod.ModuleUnit,
} {
    var index_of = std.AutoHashMap(*Module, usize).init(allocator);
    defer index_of.deinit();
    for (order, 0..) |m, i| try index_of.put(m, i);

    const units = try allocator.alloc(compiler_mod.ModuleUnit, order.len);
    for (order, 0..) |m, i| {
        const import_indices = try allocator.alloc(usize, m.imports.len);
        for (m.imports, 0..) |child, j| import_indices[j] = index_of.get(child).?;
        units[i] = .{ .program = m.program, .imports = import_indices };
    }
    return .{ .entry_index = index_of.get(entry).?, .units = units };
}

// ---- Tests ---------------------------------------------------------------

const vm_mod = @import("vm.zig");

fn writeFile(dir: std.Io.Dir, io: std.Io, path: []const u8, contents: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = path, .data = contents });
}

test "loads an entry program with no imports" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry("print 1\n", "main.butter", ".");
    try std.testing.expectEqual(@as(usize, 1), entry.program.len);
    try std.testing.expectEqual(@as(usize, 0), entry.imports.len);
    try std.testing.expectEqual(@as(usize, 1), loader.order.items.len);
}

test "loads a direct import and resolves its exported function" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, std.testing.io, "lib.butter", "export func double(int n) -> int { return n * 2 }\n");

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry("import \"lib.butter\"\nprint double(21)\n", "main.butter", ".");
    try std.testing.expectEqual(@as(usize, 1), entry.imports.len);
    try std.testing.expectEqualStrings("lib.butter", entry.imports[0].path);
    try std.testing.expectEqual(@as(usize, 2), loader.order.items.len);
}

test "a diamond import graph loads the shared dependency exactly once" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, std.testing.io, "d.butter", "export func ten() -> int { return 10 }\n");
    try writeFile(tmp.dir, std.testing.io, "b.butter", "import \"d.butter\"\nexport func fromB() -> int { return ten() }\n");
    try writeFile(tmp.dir, std.testing.io, "c.butter", "import \"d.butter\"\nexport func fromC() -> int { return ten() }\n");

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry(
        "import \"b.butter\"\nimport \"c.butter\"\nprint fromB() + fromC()\n",
        "main.butter",
        ".",
    );
    try std.testing.expectEqual(@as(usize, 2), entry.imports.len);
    // main, b, c, d — d must appear only once despite two import paths.
    try std.testing.expectEqual(@as(usize, 4), loader.order.items.len);
    try std.testing.expect(entry.imports[0].imports[0] == entry.imports[1].imports[0]);
}

test "importing the same file two different ways still loads it once" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sub");
    try writeFile(tmp.dir, std.testing.io, "util.butter", "export func one() -> int { return 1 }\n");
    try writeFile(tmp.dir, std.testing.io, "sub/reexport.butter", "import \"../util.butter\"\nexport func two() -> int { return one() + one() }\n");

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry(
        "import \"util.butter\"\nimport \"sub/reexport.butter\"\nprint one() + two()\n",
        "main.butter",
        ".",
    );
    // main -> util, main -> sub/reexport -> ../util (== util.butter) — 3
    // distinct modules total, not 4, even though "util.butter" and
    // "sub/../util.butter" are spelled differently in the two imports.
    try std.testing.expectEqual(@as(usize, 3), loader.order.items.len);
    try std.testing.expect(entry.imports[0] == entry.imports[1].imports[0]);
}

test "a circular import is a load error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, std.testing.io, "a.butter", "import \"b.butter\"\nexport func fromA() -> int { return 1 }\n");
    try writeFile(tmp.dir, std.testing.io, "b.butter", "import \"a.butter\"\nexport func fromB() -> int { return 1 }\n");

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    try std.testing.expectError(LoadError.CircularImport, loader.loadEntry("import \"a.butter\"\n", "main.butter", "."));
}

test "an imported file with top-level executable code is a load error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, std.testing.io, "lib.butter", "print 1\n");

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    try std.testing.expectError(
        LoadError.ImportedFileHasTopLevelCode,
        loader.loadEntry("import \"lib.butter\"\n", "main.butter", "."),
    );
}

test "importing a nonexistent file is a load error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    try std.testing.expectError(
        LoadError.ImportReadFailed,
        loader.loadEntry("import \"nope.butter\"\n", "main.butter", "."),
    );
}

test "a lex error in an imported file is reported against that file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, std.testing.io, "bad.butter", "export func f() -> int { return 1 @ }\n");

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    try std.testing.expectError(
        lexer_mod.Error.UnexpectedCharacter,
        loader.loadEntry("import \"bad.butter\"\n", "main.butter", "."),
    );
    try std.testing.expectEqualStrings("bad.butter", loader.diagnostic.?.path);
}

test "toCompilerUnits translates a diamond import graph into index-based ModuleUnits" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, std.testing.io, "d.butter", "export func ten() -> int { return 10 }\n");
    try writeFile(tmp.dir, std.testing.io, "b.butter", "import \"d.butter\"\nexport func fromB() -> int { return ten() }\n");
    try writeFile(tmp.dir, std.testing.io, "c.butter", "import \"d.butter\"\nexport func fromC() -> int { return ten() }\n");

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry(
        "import \"b.butter\"\nimport \"c.butter\"\nprint fromB() + fromC()\n",
        "main.butter",
        ".",
    );
    const result = try toCompilerUnits(loader.allocator(), loader.order.items, entry);

    try std.testing.expectEqual(@as(usize, 4), result.units.len);
    const entry_unit = result.units[result.entry_index];
    try std.testing.expectEqual(@as(usize, 2), entry_unit.imports.len);

    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileModules(result.entry_index, result.units);
    defer compiled.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), compiled.functions.len);
}

test "the bundled math stdlib imports by name with no matching file on disk" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry("import \"math.std.butter\"\nprint abs(-3)\n", "main.butter", ".");
    try std.testing.expectEqual(@as(usize, 1), entry.imports.len);
    try std.testing.expectEqualStrings("math.std.butter", entry.imports[0].path);
}

test "the bundled math stdlib imports the same way from any directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sub");

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry("import \"math.std.butter\"\nprint abs(-3)\n", "sub/main.butter", "sub");
    try std.testing.expectEqualStrings("math.std.butter", entry.imports[0].path);
}

test "two modules importing the bundled math stdlib both see one compiled copy of it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, std.testing.io, "b.butter", "import \"math.std.butter\"\nexport func fromB() -> int { return abs(-1) }\n");
    try writeFile(tmp.dir, std.testing.io, "c.butter", "import \"math.std.butter\"\nexport func fromC() -> int { return abs(-2) }\n");

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry(
        "import \"b.butter\"\nimport \"c.butter\"\nprint fromB() + fromC()\n",
        "main.butter",
        ".",
    );
    // main, b, c, math.std.butter — the stdlib module appears once despite
    // being imported from two different files.
    try std.testing.expectEqual(@as(usize, 4), loader.order.items.len);
    try std.testing.expect(entry.imports[0].imports[0] == entry.imports[1].imports[0]);
}

test "the bundled math stdlib's functions run correctly end to end" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry(
        \\import "math.std.butter"
        \\print abs(-5)
        \\print min(3, 7)
        \\print max(3, 7)
        \\print clamp(15, 0, 10)
        \\print floor(3.7)
        \\print ceil(3.2)
        \\print round(2.5)
        \\print sqrt(144)
        \\print pow(2, 10)
        \\print gcd(12, 18)
        \\print factorial(5)
        \\
    ,
        "main.butter",
        ".",
    );

    const modules = try toCompilerUnits(loader.allocator(), loader.order.items, entry);
    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileModules(modules.entry_index, modules.units);
    defer compiled.deinit(allocator);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var vm = vm_mod.Vm.init(allocator);
    try vm.run(&compiled, .{ .out = &writer });

    try std.testing.expectEqualStrings(
        "5\n3\n7\n10\n3\n4\n3\n12\n1024\n6\n120\n",
        writer.buffered(),
    );
}

test "the bundled collections stdlib imports by name with no matching file on disk" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry(
        "import \"collections.std.butter\"\nmap s := setNew()\nprint setAdd(s, \"a\")\n",
        "main.butter",
        ".",
    );
    try std.testing.expectEqual(@as(usize, 1), entry.imports.len);
    try std.testing.expectEqualStrings("collections.std.butter", entry.imports[0].path);
}

test "the bundled collections stdlib's Set/Stack/Queue run correctly end to end" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loader = Loader.init(allocator, std.testing.io, tmp.dir);
    defer loader.deinit();

    const entry = try loader.loadEntry(
        \\import "collections.std.butter"
        \\
        \\map a := setNew()
        \\setAdd(a, "x")
        \\setAdd(a, "y")
        \\map b := setNew()
        \\setAdd(b, "y")
        \\setAdd(b, "z")
        \\print setAdd(a, "x")
        \\print setHas(a, "x")
        \\print setSize(setUnion(a, b))
        \\print setSize(setIntersection(a, b))
        \\print setSize(setDifference(a, b))
        \\print setEquals(a, a)
        \\print setEquals(a, b)
        \\print setRemove(a, "x")
        \\print setSize(a)
        \\
        \\map st := stackNew()
        \\stackPush(st, "one")
        \\stackPush(st, "two")
        \\print stackPeek(st)
        \\print stackPop(st)
        \\print stackSize(st)
        \\
        \\map q := queueNew()
        \\queueEnqueue(q, "one")
        \\queueEnqueue(q, "two")
        \\print queuePeek(q)
        \\print queueDequeue(q)
        \\print queueSize(q)
        \\
    ,
        "main.butter",
        ".",
    );

    const modules = try toCompilerUnits(loader.allocator(), loader.order.items, entry);
    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileModules(modules.entry_index, modules.units);
    defer compiled.deinit(allocator);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var vm = vm_mod.Vm.init(allocator);
    try vm.run(&compiled, .{ .out = &writer });

    try std.testing.expectEqualStrings(
        "false\ntrue\n3\n1\n1\ntrue\nfalse\ntrue\n1\n" ++
            "two\ntwo\n1\n" ++
            "one\none\n1\n",
        writer.buffered(),
    );
}
