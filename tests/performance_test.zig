//! Performance tests for the Butter language: each case here is a
//! .butter program (tests/perf_cases/<name>.butter) chosen to lean on one
//! "common action" a real program does a lot of — a tight arithmetic
//! loop, recursive calls, array sorting, list/map growth, string
//! concatenation, function-call overhead — run end to end through the
//! same loader -> compiler -> VM pipeline tests/integration_test.zig
//! uses, but timed instead of output-checked.
//!
//! Each test reports two numbers in milliseconds:
//!   - compile: lexing + parsing + import resolution + bytecode codegen
//!   - run:     executing the compiled bytecode in the VM
//! printed to stderr so they're visible in `zig build test-performance`
//! output. This is a baseline to optimize against, not a correctness
//! check, so each test only asserts a generous upper bound (catches a
//! catastrophic regression, e.g. an accidental O(n) -> O(n^2) change,
//! without being flaky on a slower CI machine) rather than a tight one.
//!
//! Debug builds (the default for `zig build test-performance`) are much
//! slower than release ones and not representative of real-world
//! performance — run with `-Doptimize=ReleaseFast` for numbers worth
//! comparing against other language implementations.
//!
//! For run-over-run regression tracking (as opposed to this file's
//! per-case absolute thresholds), see perf_report.zig and
//! perf_compare.zig, which CI runs on every push/PR (`zig build
//! perf-report` + `zig build perf-compare`) to flag a case that got
//! meaningfully slower than the last run on the same branch.

const std = @import("std");
const bench = @import("perf_bench.zig");

/// Runs tests/perf_cases/<name>.butter, prints its compile/run/total
/// timings in milliseconds, and asserts the total stays under
/// `max_total_ms` — a loose regression guard, not a performance target.
fn expectCasePerformance(comptime name: []const u8, max_total_ms: f64) !void {
    const allocator = std.testing.allocator;
    const source = @embedFile("perf_cases/" ++ name ++ ".butter");

    const timing = try bench.benchmark(allocator, std.testing.io, source);
    const compile_ms = bench.msOf(timing.compile_ns);
    const run_ms = bench.msOf(timing.run_ns);
    const total_ms = compile_ms + run_ms;

    std.debug.print(
        "{s:<20} compile={d:>9.3}ms  run={d:>9.3}ms  total={d:>9.3}ms\n",
        .{ name, compile_ms, run_ms, total_ms },
    );

    try std.testing.expect(total_ms < max_total_ms);
}

test "loop_sum: a tight 4,000,000-iteration arithmetic loop" {
    try expectCasePerformance("loop_sum", 5000.0);
}

test "fib_recursive: fib(27) via naive recursion (~832k calls)" {
    try expectCasePerformance("fib_recursive", 5000.0);
}

test "bubble_sort: O(n^2) sort of a 600-element array" {
    try expectCasePerformance("bubble_sort", 5000.0);
}

test "list_push: growing a list to 80,000 elements, then summing it" {
    try expectCasePerformance("list_push", 5000.0);
}

test "map_ops: 8,000 map inserts followed by 8,000 has() lookups" {
    try expectCasePerformance("map_ops", 5000.0);
}

test "string_concat: 3,000 rounds of O(n) string concatenation" {
    try expectCasePerformance("string_concat", 5000.0);
}

test "function_calls: 2,000,000 calls to a trivial non-recursive function" {
    try expectCasePerformance("function_calls", 5000.0);
}

test "struct_methods: 300,000 heap struct allocations + method calls" {
    try expectCasePerformance("struct_methods", 5000.0);
}

test "string_format: 30,000 rounds of multi-expression string interpolation" {
    try expectCasePerformance("string_format", 5000.0);
}

test "higher_order_calls: 2,000,000 indirect calls through a func-typed parameter" {
    try expectCasePerformance("higher_order_calls", 5000.0);
}
