//! Runs every case in perf_bench.zig's `cases` list `runs_per_case` times,
//! keeps the fastest run of each (the one least distorted by scheduler/GC-
//! style noise — the standard way to read a microbenchmark), and prints the
//! result as JSON on stdout: machine-readable input for CI's run-over-run
//! regression check (perf_compare.zig), as opposed to performance_test.zig's
//! human-readable per-assertion stderr output.
//!
//!     zig build perf-report -Doptimize=ReleaseFast -- --output perf-current.json
//!
//! Debug builds work but aren't representative of real timings, same
//! caveat as `zig build test-performance`.

const std = @import("std");
const bench = @import("perf_bench.zig");

const runs_per_case = 5;

const usage =
    \\usage: perf_report --output <path>
    \\
    \\  --output <path>   write the JSON report here (required)
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);

    var output_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--output")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --output requires a path\n{s}", .{usage});
                std.process.exit(1);
            }
            output_path = args[i];
        } else {
            std.debug.print("error: unrecognized argument '{s}'\n{s}", .{ args[i], usage });
            std.process.exit(1);
        }
    }

    const path = output_path orelse {
        std.debug.print("error: --output is required\n{s}", .{usage});
        std.process.exit(1);
    };

    var out_buffer: [4096]u8 = undefined;
    var out_file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer out_file.close(init.io);
    var out_writer: std.Io.File.Writer = .init(out_file, init.io, &out_buffer);
    const w = &out_writer.interface;

    try w.writeAll("{\n");
    try w.print("  \"optimize\": \"{s}\",\n", .{@tagName(@import("builtin").mode)});
    try w.print("  \"runs_per_case\": {d},\n", .{runs_per_case});
    try w.writeAll("  \"cases\": {\n");

    inline for (bench.cases, 0..) |case, case_index| {
        const source = @embedFile("perf_cases/" ++ case.name ++ ".butter");

        var best: ?bench.Timing = null;
        for (0..runs_per_case) |_| {
            const timing = try bench.benchmark(gpa, init.io, source);
            if (best == null or (timing.compile_ns + timing.run_ns) < (best.?.compile_ns + best.?.run_ns)) {
                best = timing;
            }
        }

        const compile_ms = bench.msOf(best.?.compile_ns);
        const run_ms = bench.msOf(best.?.run_ns);
        const total_ms = compile_ms + run_ms;

        std.debug.print(
            "{s:<20} compile={d:>9.3}ms  run={d:>9.3}ms  total={d:>9.3}ms  (best of {d})\n",
            .{ case.name, compile_ms, run_ms, total_ms, runs_per_case },
        );

        try w.print(
            "    \"{s}\": {{ \"compile_ms\": {d:.3}, \"run_ms\": {d:.3}, \"total_ms\": {d:.3} }}{s}\n",
            .{ case.name, compile_ms, run_ms, total_ms, if (case_index + 1 < bench.cases.len) "," else "" },
        );
    }

    try w.writeAll("  }\n");
    try w.writeAll("}\n");
    try w.flush();
}
