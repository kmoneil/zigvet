const std = @import("std");

// A build function that asks whether a path is there to decide what to
// build, and never tells Zig's configure cache (#240): a `locales/` made
// after the first run changes nothing the cache tracks, so `zig build`
// reuses the last graph and the step is missing until build.zig changes.
fn locales(b: *std.Build) void {
    if (b.root.access(b.graph.io, "locales", .{})) |_| {
        _ = b.step("locales", "Compile the locales");
    } else |_| {}
}

// Told of `test/`, which says nothing of `db/`: the step that fails for
// want of `db/seeds.zig` stays in the graph after the file is written.
fn seeds(b: *std.Build, step: *std.Build.Step) void {
    b.dependOnDirectoryContents(b.path("test"));
    if (b.root.access(b.graph.io, "db/seeds.zig", .{})) |_| {
        step.dependOn(&b.addInstallFile(b.path("db/seeds.zig"), "seeds.zig").step);
    } else |_| step.dependOn(&b.addFail("there is no db/seeds.zig").step);
}

// A helper that answers for any path: its `catch` takes the failure as
// the answer, and every caller builds on it.
fn dirExists(b: *std.Build, path: []const u8) bool {
    var dir = b.root.openDir(b.graph.io, path, .{}) catch return false;
    dir.close(b.graph.io);
    return true;
}

// Not reported: told of the directory the path would be in, which is
// always there, where a dependency on the path itself fails the configure
// until it is made; the cache turned off; and a path the build cannot go
// on without, since a configure that fails is not cached.
fn told(b: *std.Build) void {
    b.dependOnDirectoryContents(b.path("."));
    if (b.root.access(b.graph.io, "locales", .{})) |_| {
        _ = b.step("locales", "Compile the locales");
    } else |_| {}
}
fn parent(b: *std.Build, step: *std.Build.Step) void {
    b.dependOnDirectoryContents(b.path("db"));
    b.root.access(b.graph.io, "db/seeds.zig", .{}) catch return;
    step.dependOn(&b.addInstallFile(b.path("db/seeds.zig"), "seeds.zig").step);
}
fn poisoned(b: *std.Build) bool {
    b.graph.poisonCache();
    b.root.access(b.graph.io, "locales", .{}) catch return false;
    return true;
}
fn required(b: *std.Build) void {
    b.root.access(b.graph.io, "icon.png", .{}) catch |err| std.debug.panic("icon.png: {t}", .{err});
}

comptime {
    _ = &locales;
    _ = &seeds;
    _ = &dirExists;
    _ = &told;
    _ = &parent;
    _ = &poisoned;
    _ = &required;
}

// error
//
// :8:9: error: asks whether `"locales"` is there to decide what to build, and nothing here tells Zig's configure cache, so one made or removed later is not seen until something else changes the build
// :17:9: error: asks whether `"db/seeds.zig"` is there to decide what to build, and nothing here tells Zig's configure cache, so one made or removed later is not seen until something else changes the build
// :25:15: error: asks whether `path` is there to decide what to build, and nothing here tells Zig's configure cache, so one made or removed later is not seen until something else changes the build
