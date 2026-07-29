//! CLI front-end for the `butter` lexer/parser/compiler/VM: lexes,
//! parses, compiles to bytecode, and runs a Butter program — or prints a
//! diagnostic if any stage fails.
//!
//!     butter path/to/program.butter
//!     butter --stdin < path/to/program.butter
//!     butter --disassemble path/to/program.butter
//!     butter --disassemble --stdin < path/to/program.butter

const std = @import("std");
const butter = @import("butter");

const usage =
    \\usage: butter [--disassemble] (<file> | --stdin)
    \\
    \\  <file>          run the Butter source file at this path
    \\  --stdin         read the Butter source program from standard input
    \\  --disassemble   print compiled bytecode instead of running it
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

    var disassemble = false;
    var use_stdin = false;
    var file_path: ?[]const u8 = null;

    for (args[1..]) |arg| {
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

    const source = if (use_stdin) blk: {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader: std.Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
        break :blk stdin_reader.interface.allocRemaining(gpa, .unlimited) catch |err| {
            printUsageAndExit("error: failed to read standard input: {s}", .{@errorName(err)});
        };
    } else std.Io.Dir.cwd().readFileAlloc(init.io, file_path.?, gpa, .unlimited) catch |err| {
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
            std.debug.print("import error in '{s}': {s}\n", .{ diag.path, diag.message });
            std.process.exit(1);
        },
    };

    const modules = try butter.module.toCompilerUnits(loader.allocator(), loader.order.items, entry_module);

    var compiler = butter.compiler.Compiler.init(gpa);
    var chunk = compiler.compileModules(modules.entry_index, modules.units) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            const diag = compiler.diagnostic.?;
            std.debug.print("compile error: {s}: '{s}'\n", .{ diag.message, diag.name });
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

    var vm = butter.vm.Vm.init();
    vm.run(&chunk, stdout_writer) catch |err| {
        try stdout_writer.flush();
        std.debug.print("runtime error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    try stdout_writer.flush();
}
