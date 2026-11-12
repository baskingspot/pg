const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stdx_dep = b.dependency("stdx", .{ .target = target, .optimize = optimize });

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops here.
    const mod = b.addModule("pg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "stdx", .module = stdx_dep.module("stdx") }},
    });

    if (b.pkg_hash.len != 0) return;

    // testingx provides the test runner and the bench engine. It is lazy
    // because only the root build uses it; a consumer never fetches it. On the
    // first configure pass it is not fetched yet, `lazyDependency` returns
    // null, and the build runner fetches it and reruns this script.
    const testingx_dep = b.lazyDependency("testingx", .{ .target = target });
    const test_runner: ?std.Build.Step.Compile.TestRunner = if (testingx_dep) |dep|
        .{ .path = dep.path("src/runner.zig"), .mode = .simple }
    else
        null;

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = test_runner });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.addPassthruArgs();

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // The benchmark suite. testingx's engine builds it ReleaseFast by default.
    if (b.lazyImport(@This(), "testingx")) |testingx| {
        const testingx_module = testingx_dep orelse unreachable;
        const bench_dep = testingx_module.module("testingx");

        // The library at the optimization level the suite runs at. A Debug
        // copy under a ReleaseFast harness would time a build nobody ships.
        const bench_lib = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "stdx", .module = stdx_dep.module("stdx") }},
        });

        const run_bench = testingx.addBench(b, .{
            .module = bench_dep,
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .imports = &.{.{ .name = "pg", .module = bench_lib }},
        });
        run_bench.addPassthruArgs();

        const bench_step = b.step("bench", "Run benchmarks");
        bench_step.dependOn(&run_bench.step);
    }
}
