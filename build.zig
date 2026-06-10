const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("toml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "toml",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    const run_test_cmd = b.addRunArtifact(tests);
    run_test_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_test_cmd.step);

    const suite_step = b.step("test-suite", "Run upstream TOML test suite");
    setupTestSuite(b, optimize, target, suite_step);
}

fn setupTestSuite(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    step: *std.Build.Step,
) void {
    const suite_exe = b.addExecutable(.{
        .name = "test-suite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_suite.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    const suite_manifest = b.option(
        []const u8,
        "test-manifest",
        "Path to TOML test manifest (default: tests/files-toml-1.0.0)",
    ) orelse "tests/files-toml-1.0.0";
    const suite_root = b.option(
        []const u8,
        "test-root",
        "Path to TOML tests root directory (default: tests)",
    ) orelse "tests";

    const suite_filter = b.option(
        []const u8,
        "test-filter",
        "Substring filter applied to manifest entries (optional)",
    );
    const suite_case = b.option(
        []const u8,
        "test-case",
        "Run a single test (path)",
    );
    const suite_show = b.option(bool, "test-show", "Show extra failure info") orelse false;
    const suite_max_failures = b.option(
        usize,
        "test-max-failures",
        "Max failures to print (0 = unlimited)",
    );

    const run_suite_cmd = b.addRunArtifact(suite_exe);
    run_suite_cmd.addArgs(
        &.{ "--manifest", suite_manifest, "--tests-root", suite_root },
    );

    if (suite_filter) |f| run_suite_cmd.addArgs(&.{ "--filter", f });
    if (suite_case) |c| run_suite_cmd.addArgs(&.{ "--test", c });
    if (suite_show) run_suite_cmd.addArg("--show");
    if (suite_max_failures) |n| run_suite_cmd.addArgs(
        &.{ "--max-failures", b.fmt("{}", .{n}) },
    );

    step.dependOn(&run_suite_cmd.step);
}
