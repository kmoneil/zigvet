const std = @import("std");
const zon = @import("build.zig.zon");

// No dependencies, by design: std.zig.Ast, the compiler's own parser, is the
// only parser. Held here so that adding one is a decision made in this file
// rather than a line that slips into build.zig.zon.
comptime {
    if (@typeInfo(@TypeOf(zon.dependencies)).@"struct".field_names.len != 0) {
        @compileError("zigvet has no dependencies, by design: build.zig.zon's .dependencies must stay empty");
    }
}

/// What a GitHub release carries: one binary per platform the tests run on,
/// named as kmoneil's other tools name theirs.
const release_targets = [_]struct { query: std.Target.Query, name: []const u8 }{
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux }, .name = "zigvet-linux-amd64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux }, .name = "zigvet-linux-arm64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "zigvet-darwin-amd64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "zigvet-darwin-arm64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .name = "zigvet-windows-amd64.exe" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .windows }, .name = "zigvet-windows-arm64.exe" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `zigvet --version` prints build.zig.zon's version; the release
    // workflow refuses a tag that does not match it.
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{ .name = "zigvet", .root_module = zigvetModule(b, target, optimize, options) });
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
    const test_module = zigvetModule(b, target, optimize, options);
    test_module.addOptions("test_options", test_options);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    run_tests.setCwd(b.path("."));
    run_tests.has_side_effects = true;
    b.step("test", "Run unit tests and the case corpus").dependOn(&run_tests.step);

    // `zig build release`: every release binary, ReleaseSafe so the checks
    // that make a crash a report rather than a wrong answer stay in, into
    // zig-out/release/. CI builds it on every change, so a release never
    // finds a target that does not build.
    const release = b.step("release", "Build the release binaries into zig-out/release/");
    for (release_targets) |release_target| {
        const release_exe = b.addExecutable(.{
            .name = "zigvet",
            .root_module = zigvetModule(b, b.resolveTargetQuery(release_target.query), .ReleaseSafe, options),
        });
        const install = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
            .dest_sub_path = release_target.name,
            .pdb_dir = .disabled,
        });
        release.dependOn(&install.step);
    }
}

fn zigvetModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", options);
    return module;
}
