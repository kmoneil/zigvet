const std = @import("std");

// A build function that lists a directory to decide what to build, and
// never tells Zig's configure cache (#94): a file added to `test/` changes
// nothing the cache tracks, so `zig build test` reuses the last graph and
// passes without building the new test.
fn tests(b: *std.Build, step: *std.Build.Step) void {
    var dir = b.root.openDir(b.graph.io, "test", .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("test/{s}", .{entry.name})),
        }) });
        step.dependOn(&b.addRunArtifact(t).step);
    }
}

// Told of `test/` but walked: the dependency is not recursive, so a file
// added to `test/models/` is not seen.
fn walked(b: *std.Build, step: *std.Build.Step) !void {
    var dir = try b.root.openDir(b.graph.io, "test", .{ .iterate = true });
    defer dir.close(b.graph.io);
    b.dependOnDirectoryContents(b.path("test"));
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file) continue;
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("test/{s}", .{entry.path})),
        }) });
        step.dependOn(&b.addRunArtifact(t).step);
    }
}

// Not reported: the directory is told, and so is each one the walk enters,
// or the cache is turned off.
fn told(b: *std.Build, step: *std.Build.Step) void {
    b.dependOnDirectoryContents(b.path("examples"));
    var dir = b.root.openDir(b.graph.io, "examples", .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        const exe = b.addExecutable(.{ .name = entry.name, .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}", .{entry.name})),
        }) });
        step.dependOn(&exe.step);
    }
}
fn eachDirectory(b: *std.Build, step: *std.Build.Step) !void {
    b.dependOnDirectoryContents(b.path("test"));
    var dir = try b.root.openDir(b.graph.io, "test", .{ .iterate = true });
    defer dir.close(b.graph.io);
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| switch (entry.kind) {
        .directory => b.dependOnDirectoryContents(b.path(b.fmt("test/{s}", .{entry.path}))),
        .file => step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("test/{s}", .{entry.path})),
        }) })).step),
        else => {},
    };
}
fn poisoned(b: *std.Build) !usize {
    b.graph.poisonCache();
    var dir = try b.root.openDir(b.graph.io, "dist", .{ .iterate = true });
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(b.graph.io)) |_| n += 1;
    return n;
}

comptime {
    _ = &tests;
    _ = &walked;
    _ = &told;
    _ = &eachDirectory;
    _ = &poisoned;
}

// error
//
// :8:15: error: lists `"test"` to decide what to build, and nothing here tells Zig's configure cache, so a file added there is not seen until something else changes the build
// :23:19: error: walks `"test"`, and `dependOnDirectoryContents` is not recursive, so a file added to a directory under it is not seen until something else changes the build
