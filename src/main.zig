//! CLI front-end for the `butter` lexer/parser/compiler/VM: lexes,
//! parses, compiles to bytecode, and runs a Butter program — or prints a
//! diagnostic if any stage fails.
//!
//!     butter path/to/program.butter
//!     butter --stdin < path/to/program.butter
//!     butter --disassemble path/to/program.butter
//!     butter --disassemble --stdin < path/to/program.butter
//!     butter path/to/program.butter -- foo bar   (program sees `args` == ["foo", "bar"])

const std = @import("std");
const butter = @import("butter");

const usage =
    \\usage: butter [--disassemble] (<file> | --stdin) [-- <program-args>...]
    \\
    \\  <file>            run the Butter source file at this path
    \\  --stdin           read the Butter source program from standard input
    \\  --disassemble     print compiled bytecode instead of running it
    \\  -- <program-args> everything after '--' is passed to the running
    \\                    program as its own `args`, not parsed as CLI flags
    \\
;

fn printUsageAndExit(comptime message: []const u8, args: anytype) noreturn {
    std.debug.print(message, args);
    std.debug.print("\n{s}", .{usage});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);

    // The process's own environment, flattened into the plain slice
    // `Vm.Host` takes (see its `env` field). Snapshotted once here rather
    // than read per lookup, so a program's view of it can't shift mid-run.
    const env_vars = try gpa.alloc(butter.vm.Host.EnvVar, init.environ_map.count());
    for (init.environ_map.keys(), init.environ_map.values(), 0..) |name, value, i| {
        env_vars[i] = .{ .name = name, .value = value };
    }

    var disassemble = false;
    var use_stdin = false;
    var file_path: ?[]const u8 = null;
    var program_args: []const []const u8 = &.{};

    // Everything from a bare '--' onward belongs to the running program
    // (its own `args`), not to this CLI — so it's never matched against
    // '--disassemble'/'--stdin' or treated as the source file/an extra
    // argument below.
    var cli_args = args[1..];
    for (cli_args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            program_args = cli_args[i + 1 ..];
            cli_args = cli_args[0..i];
            break;
        }
    }

    for (cli_args) |arg| {
        if (std.mem.eql(u8, arg, "--disassemble")) {
            disassemble = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            use_stdin = true;
        } else if (file_path != null) {
            printUsageAndExit("error: unexpected extra argument '{s}'", .{arg});
        } else {
            file_path = arg;
        }
    }

    if (use_stdin and file_path != null) {
        printUsageAndExit("error: pass either a file or --stdin, not both", .{});
    }
    if (!use_stdin and file_path == null) {
        printUsageAndExit("error: expected a source file or --stdin", .{});
    }

    // One stdin reader for the whole process, shared between reading the
    // source program (--stdin) and the running program's own `read(stdin,
    // ...)`. With --stdin the source read consumes all of it, so the
    // program then sees standard input already at its end — the two uses
    // can't both have it.
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);

    const source = if (use_stdin)
        stdin_reader.interface.allocRemaining(gpa, .unlimited) catch |err| {
            printUsageAndExit("error: failed to read standard input: {s}", .{@errorName(err)});
        }
    else
        std.Io.Dir.cwd().readFileAlloc(init.io, file_path.?, gpa, .unlimited) catch |err| {
            printUsageAndExit("error: failed to read '{s}': {s}", .{ file_path.?, @errorName(err) });
        };

    // Relative `import`s resolve against the entry file's own directory
    // (or the current directory, for --stdin, which has no file of its
    // own to be relative to) — see GRAMMAR.bnf design note h.
    var entry_key: []const u8 = "<stdin>";
    var entry_dir: []const u8 = ".";
    if (!use_stdin) {
        entry_key = try std.fs.path.resolve(gpa, &.{file_path.?});
        entry_dir = std.fs.path.dirname(file_path.?) orelse ".";
    }

    var loader = butter.module.Loader.init(gpa, init.io, std.Io.Dir.cwd());
    defer loader.deinit();

    const entry_module = loader.loadEntry(source, entry_key, entry_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            const diag = loader.diagnostic.?;
            // A lex/parse failure carries the line it happened on — that's
            // a syntax problem IN this file (worded like any other compile
            // error, entry file or import alike). A `line`-less diagnostic
            // is a genuine module-resolution problem (file not found,
            // circular import, disallowed top-level code in an import) —
            // there's no one line in `path` to blame, so it keeps the
            // "import error" wording instead.
            if (diag.line) |line| {
                std.debug.print("compile error in '{s}' at line {d}: {s}\n", .{ diag.path, line, diag.message });
            } else {
                std.debug.print("import error in '{s}': {s}\n", .{ diag.path, diag.message });
            }
            std.process.exit(1);
        },
    };

    const modules = try butter.module.toCompilerUnits(loader.allocator(), loader.order.items, entry_module);

    var compiler = butter.compiler.Compiler.init(gpa);
    var chunk = compiler.compileModules(modules.entry_index, modules.units) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            const diag = compiler.diagnostic.?;
            std.debug.print("compile error in '{s}' at line {d}: {s}: '{s}'\n", .{ diag.path, diag.line, diag.message, diag.name });
            std.process.exit(1);
        },
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    if (disassemble) {
        try chunk.disassemble(stdout_writer);
        try stdout_writer.flush();
        return;
    }

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    var vm = butter.vm.Vm.init(gpa);
    vm.run(&chunk, .{
        .out = stdout_writer,
        .err = stderr_writer,
        .in = &stdin_reader.interface,
        // A program run from the CLI gets filesystem access, with relative
        // paths in `open` resolved against the current directory — not the
        // source file's own directory, unlike `import` (which is resolved at
        // compile time, and whose base is the importing file). An embedder
        // that wants a sandboxed program simply passes no `fs` at all.
        .fs = .{ .io = init.io, .dir = std.Io.Dir.cwd() },
        .args = program_args,
        // A program run from the CLI inherits this process's environment
        // whole, the same way it inherits the current directory for `open`.
        .env = env_vars,
    }) catch |err| {
        // Flush whatever the program managed to produce before the error,
        // so a partial run's output isn't swallowed by the diagnostic.
        stdout_writer.flush() catch {};
        stderr_writer.flush() catch {};
        if (vm.diagnostic) |diag| {
            if (diag.path.len > 0) {
                std.debug.print("runtime error: {s} '{s}': {s}\n", .{ diag.operation, diag.path, diag.cause });
            } else {
                std.debug.print("runtime error: {s}: {s}\n", .{ diag.operation, diag.cause });
            }
        } else {
            std.debug.print("runtime error: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
    try stdout_writer.flush();
    try stderr_writer.flush();

    // `exit(n)` (GRAMMAR.bnf design note 3q) sets this before `vm.run`
    // returns; a program that never calls it falls off the end via HALT,
    // leaving it null, which is exit code 0 — the same convention every
    // shell uses for "ran to completion without calling exit itself".
    if (vm.exit_code) |code| std.process.exit(code);
}
