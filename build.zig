const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zigvet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // `zig build run -- <path>...`
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run zigvet on the given paths").dependOn(&run.step);

    // zigvet over its own source: the same step the README tells a
    // consuming repo to add.
    const lint = b.addRunArtifact(exe);
    lint.setCwd(b.path("."));
    lint.addArgs(&.{"src"});
    b.step("lint", "Run zigvet over src/").dependOn(&lint.step);

    // The tests include the case corpus under test/cases/, which runs the
    // compiler over each case and reads the cases at run time: it needs the
    // compiler's path, the repository root as its working directory, and to
    // run every time rather than be cached on the test binary alone.
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", test_options);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    run_tests.setCwd(b.path("."));
    run_tests.has_side_effects = true;
    b.step("test", "Run unit tests and the case corpus").dependOn(&run_tests.step);
}
