//! Compares a perf_report.zig JSON report against a previous one and flags
//! any case whose `total_ms` grew by more than `--margin` percent — CI's
//! run-over-run regression check, as opposed to performance_test.zig's
//! fixed per-case thresholds (which only catch a catastrophic regression,
//! not a real-but-smaller one against where the branch actually started).
//!
//!     zig build perf-compare -- --current perf-current.json \
//!         --baseline perf-baseline.json --margin 25 --summary summary.md
//!
//! If `--baseline` is omitted, or names a file that doesn't exist (e.g. the
//! very first run on a fresh cache), this just prints the current report
//! with no comparison and exits 0 — there's nothing to regress against yet.
//!
//! Comparing against the immediately preceding run on shared CI runners is
//! noisier than a dedicated benchmark machine, which is why `--margin`
//! defaults loose (25%) rather than tight — same philosophy as the generous
//! absolute thresholds in performance_test.zig, applied to a relative
//! comparison instead.

const std = @import("std");

const usage =
    \\usage: perf_compare --current <path> [--baseline <path>] [--margin <percent>] [--summary <path>]
    \\
    \\  --current <path>   JSON report from this run (required, see perf_report.zig)
    \\  --baseline <path>  JSON report from a previous run to compare against;
    \\                     if omitted, or the file doesn't exist, this just
    \\                     prints the current report with no comparison
    \\  --margin <percent> flag a case whose total_ms grew by more than this
    \\                     percent versus baseline (default: 25)
    \\  --summary <path>   also append a Markdown table here (e.g.
    \\                     $GITHUB_STEP_SUMMARY)
    \\
;

fn readReport(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?std.json.Parsed(std.json.Value) {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn caseTotalMs(report: std.json.Value, name: []const u8) ?f64 {
    const cases = report.object.get("cases") orelse return null;
    const entry = cases.object.get(name) orelse return null;
    const total = entry.object.get("total_ms") orelse return null;
    return total.float;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);

    var current_path: ?[]const u8 = null;
    var baseline_path: ?[]const u8 = null;
    var summary_path: ?[]const u8 = null;
    var margin_percent: f64 = 25.0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const is_flag_needing_value = std.mem.eql(u8, arg, "--current") or
            std.mem.eql(u8, arg, "--baseline") or
            std.mem.eql(u8, arg, "--summary") or
            std.mem.eql(u8, arg, "--margin");
        if (is_flag_needing_value and i + 1 >= args.len) {
            std.debug.print("error: {s} requires a value\n{s}", .{ arg, usage });
            std.process.exit(1);
        }

        if (std.mem.eql(u8, arg, "--current")) {
            i += 1;
            current_path = args[i];
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            i += 1;
            baseline_path = args[i];
        } else if (std.mem.eql(u8, arg, "--summary")) {
            i += 1;
            summary_path = args[i];
        } else if (std.mem.eql(u8, arg, "--margin")) {
            i += 1;
            margin_percent = std.fmt.parseFloat(f64, args[i]) catch {
                std.debug.print("error: --margin must be a number\n{s}", .{usage});
                std.process.exit(1);
            };
        } else {
            std.debug.print("error: unrecognized argument '{s}'\n{s}", .{ arg, usage });
            std.process.exit(1);
        }
    }

    const path = current_path orelse {
        std.debug.print("error: --current is required\n{s}", .{usage});
        std.process.exit(1);
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const current_parsed = (try readReport(gpa, init.io, path)) orelse {
        std.debug.print("error: --current report '{s}' not found\n", .{path});
        std.process.exit(1);
    };
    const current = current_parsed.value;

    const baseline_parsed = if (baseline_path) |bp| try readReport(gpa, init.io, bp) else null;

    // Opened with `read = true, truncate = false` and seeked to the current
    // end so this appends: GITHUB_STEP_SUMMARY may already have content from
    // earlier steps in the same job, which a plain createFile would erase.
    var summary_writer: ?std.Io.File.Writer = null;
    var summary_buffer: [4096]u8 = undefined;
    if (summary_path) |sp| {
        const summary_file = try std.Io.Dir.cwd().createFile(init.io, sp, .{ .read = true, .truncate = false });
        const stat = try summary_file.stat(init.io);
        summary_writer = .init(summary_file, init.io, &summary_buffer);
        try summary_writer.?.seekTo(stat.size);
    }

    if (baseline_parsed == null) {
        try out.writeAll("no baseline to compare against yet — this run establishes one\n\n");
        if (summary_writer) |*sw| {
            try sw.interface.writeAll("## Performance report\n\nNo baseline yet — this run establishes one.\n\n");
        }
    }

    const cases = current.object.get("cases") orelse {
        std.debug.print("error: '{s}' has no \"cases\" object\n", .{path});
        std.process.exit(1);
    };

    try out.print("{s:<20} {s:>12} {s:>12} {s:>9}\n", .{ "case", "baseline_ms", "current_ms", "delta" });
    if (summary_writer) |*sw| {
        try sw.interface.writeAll("| case | baseline (ms) | current (ms) | delta |\n");
        try sw.interface.writeAll("|---|---:|---:|---:|\n");
    }

    var any_regression = false;
    var regression_count: u32 = 0;
    var it = cases.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const current_total = entry.value_ptr.object.get("total_ms").?.float;

        const baseline_total: ?f64 = if (baseline_parsed) |bp| caseTotalMs(bp.value, name) else null;

        if (baseline_total) |baseline_ms| {
            const delta_percent = (current_total - baseline_ms) / baseline_ms * 100.0;
            const regressed = delta_percent > margin_percent;
            if (regressed) {
                any_regression = true;
                regression_count += 1;
            }

            const flag = if (regressed) " ⚠️ REGRESSION" else "";
            const sign: []const u8 = if (delta_percent >= 0) "+" else "";
            try out.print("{s:<20} {d:>12.3} {d:>12.3} {s}{d:.1}%{s}\n", .{ name, baseline_ms, current_total, sign, delta_percent, flag });
            if (summary_writer) |*sw| {
                try sw.interface.print("| {s} | {d:.3} | {d:.3} | {s}{d:.1}%{s} |\n", .{ name, baseline_ms, current_total, sign, delta_percent, flag });
            }
            if (regressed) {
                try out.print("::warning title=Performance regression in {s}::{s} total time grew {d:.1}% (baseline {d:.3}ms -> current {d:.3}ms, margin {d:.1}%)\n", .{ name, name, delta_percent, baseline_ms, current_total, margin_percent });
            }
        } else {
            try out.print("{s:<20} {s:>12} {d:>12.3} {s:>9}\n", .{ name, "-", current_total, "new" });
            if (summary_writer) |*sw| {
                try sw.interface.print("| {s} | - | {d:.3} | new |\n", .{ name, current_total });
            }
        }
    }

    if (summary_writer) |*sw| {
        if (any_regression) {
            try sw.interface.print("\n**{d} case(s) regressed by more than {d:.1}%.**\n", .{ regression_count, margin_percent });
        }
        try sw.interface.flush();
    }

    try out.flush();

    if (any_regression) {
        std.debug.print("\nperformance regression detected (margin: {d:.1}%)\n", .{margin_percent});
        std.process.exit(1);
    }
}
