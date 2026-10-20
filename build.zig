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

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
