const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("butter", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "butter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "butter", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the butter CLI");
    run_step.dependOn(&run_cmd.step);

    const lsp_exe = b.addExecutable(.{
        .name = "butter-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "butter", .module = mod },
            },
        }),
    });
    b.installArtifact(lsp_exe);

    const lsp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "butter", .module = mod },
            },
        }),
    });
    const run_lsp_tests = b.addRunArtifact(lsp_tests);

    const lsp_test_step = b.step("test-lsp", "Run the language server's unit tests (src/lsp/*.zig)");
    lsp_test_step.dependOn(&run_lsp_tests.step);

    const lsp_smoke_options = b.addOptions();
    lsp_smoke_options.addOptionPath("lsp_exe_path", lsp_exe.getEmittedBin());

    const lsp_smoke_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/lsp_smoke_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = lsp_smoke_options.createModule() },
            },
        }),
    });
    const run_lsp_smoke_test = b.addRunArtifact(lsp_smoke_test);

    const lsp_smoke_test_step = b.step("test-lsp-smoke", "Drive the built butter-lsp binary over real stdio JSON-RPC");
    lsp_smoke_test_step.dependOn(&run_lsp_smoke_test.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const unit_test_step = b.step("test-unit", "Run the lexer/parser/compiler/VM unit tests embedded in src/*.zig");
    unit_test_step.dependOn(&run_mod_tests.step);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "butter", .module = mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const integration_test_step = b.step("test-integration", "Run the .butter program integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    const performance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/performance_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "butter", .module = mod },
            },
        }),
    });
    const run_performance_tests = b.addRunArtifact(performance_tests);
    run_performance_tests.has_side_effects = true; // always rerun; timings shouldn't be cached

    const performance_test_step = b.step("test-performance", "Run the timed .butter program performance benchmarks (add -Doptimize=ReleaseFast for representative numbers)");
    performance_test_step.dependOn(&run_performance_tests.step);

    const perf_report_exe = b.addExecutable(.{
        .name = "perf_report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/perf_report.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "butter", .module = mod },
            },
        }),
    });
    const run_perf_report = b.addRunArtifact(perf_report_exe);
    run_perf_report.has_side_effects = true; // always rerun; timings shouldn't be cached
    if (b.args) |args| run_perf_report.addArgs(args);

    const perf_report_step = b.step("perf-report", "Run every performance benchmark and print a JSON report (add -Doptimize=ReleaseFast for representative numbers; pass -- --output <path>)");
    perf_report_step.dependOn(&run_perf_report.step);

    const perf_compare_exe = b.addExecutable(.{
        .name = "perf_compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/perf_compare.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_perf_compare = b.addRunArtifact(perf_compare_exe);
    run_perf_compare.has_side_effects = true;
    if (b.args) |args| run_perf_compare.addArgs(args);

    const perf_compare_step = b.step("perf-compare", "Compare a perf-report JSON file against a previous one and flag regressions (pass -- --current <path> --baseline <path>)");
    perf_compare_step.dependOn(&run_perf_compare.step);

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "butter", .module = mod },
            },
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);

    const fuzz_test_step = b.step("test-fuzz", "Run the lexer/parser fuzz target (add --fuzz to actually fuzz instead of just smoke-testing)");
    fuzz_test_step.dependOn(&run_fuzz_tests.step);

    const test_step = b.step("test", "Run the full test suite (unit + integration + fuzz smoke test + LSP)");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
    test_step.dependOn(&run_lsp_tests.step);

    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "tests", "build.zig" },
        .check = true,
    });
    const fmt_check_step = b.step("fmt-check", "Check formatting of src/, tests/, and build.zig (zig fmt --check)");
    fmt_check_step.dependOn(&fmt_check.step);

    const release_targets = [_]struct { query: std.Target.Query, name: []const u8 }{
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }, .name = "x86_64-linux-gnu" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu }, .name = "aarch64-linux-gnu" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "x86_64-macos" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "aarch64-macos" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }, .name = "x86_64-windows-gnu" },
    };

    const release_step = b.step("release", "Build stripped ReleaseFast binaries for common target triples into zig-out/release/<triple>/");
    for (release_targets) |release_target| {
        const release_target_resolved = b.resolveTargetQuery(release_target.query);

        const release_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = release_target_resolved,
            .optimize = .ReleaseFast,
        });

        const release_exe = b.addExecutable(.{
            .name = "butter",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = release_target_resolved,
                .optimize = .ReleaseFast,
                .strip = true,
                .imports = &.{
                    .{ .name = "butter", .module = release_mod },
                },
            }),
        });

        const install_release_exe = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{ "release", release_target.name }) } },
        });
        release_step.dependOn(&install_release_exe.step);
    }
}
