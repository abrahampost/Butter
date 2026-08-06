//! Shared benchmark harness for the timed .butter programs under
//! perf_cases/. Two consumers:
//!
//!   - performance_test.zig: one `test { }` block per case, each
//!     documenting *why* that case exists and asserting a generous upper
//!     bound (`zig build test-performance`).
//!   - perf_report.zig: runs every case in `cases` below and prints
//!     machine-readable JSON, for CI's run-over-run regression check
//!     (`zig build perf-report`, tests/perf_compare.zig).
//!
//! `cases` (name + threshold) is intentionally a second list alongside the
//! individual `test { }` blocks, not generated from them — those blocks'
//! names are documentation of *what each benchmark stresses*, which a data
//! table can't carry. Keep both in sync when adding a case (see "To add a
//! case" in tests/README.md).

const std = @import("std");
const butter = @import("butter");

pub const Timing = struct {
    compile_ns: i96,
    run_ns: i96,
};

/// Compiles and runs `source`, discarding its printed output, and returns
/// how long each phase took. Mirrors integration_test.zig's `run`, split
/// into its compile and execute halves so each can be timed separately.
/// `io` is `std.testing.io` from performance_test.zig (only valid in a test
/// binary) or a real `Io` from perf_report.zig's `std.process.Init`.
pub fn benchmark(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !Timing {
    const t0 = std.Io.Clock.now(.awake, io);

    var loader = butter.module.Loader.init(allocator, io, std.Io.Dir.cwd());
    defer loader.deinit();

    const entry = try loader.loadEntry(source, "<bench>", ".");
    const modules = try butter.module.toCompilerUnits(loader.allocator(), loader.order.items, entry);

    var compiler = butter.compiler.Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileModules(modules.entry_index, modules.units);
    defer compiled.deinit(allocator);

    const t1 = std.Io.Clock.now(.awake, io);

    // A Discarding writer so a benchmark that prints a lot (or a little)
    // isn't measuring output-buffering cost instead of VM execution cost.
    var discard_buffer: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buffer);

    var vm = butter.vm.Vm.init(allocator);
    try vm.run(&compiled, .{ .out = &discarding.writer });

    const t2 = std.Io.Clock.now(.awake, io);

    return .{
        .compile_ns = t0.durationTo(t1).nanoseconds,
        .run_ns = t1.durationTo(t2).nanoseconds,
    };
}

pub fn msOf(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

pub const Case = struct {
    name: []const u8,
    max_total_ms: f64,
};

pub const cases = [_]Case{
    .{ .name = "loop_sum", .max_total_ms = 5000.0 },
    .{ .name = "fib_recursive", .max_total_ms = 5000.0 },
    .{ .name = "bubble_sort", .max_total_ms = 5000.0 },
    .{ .name = "list_push", .max_total_ms = 5000.0 },
    .{ .name = "map_ops", .max_total_ms = 5000.0 },
    .{ .name = "string_concat", .max_total_ms = 5000.0 },
    .{ .name = "function_calls", .max_total_ms = 5000.0 },
    .{ .name = "struct_methods", .max_total_ms = 5000.0 },
    .{ .name = "string_format", .max_total_ms = 5000.0 },
    .{ .name = "higher_order_calls", .max_total_ms = 5000.0 },
};
