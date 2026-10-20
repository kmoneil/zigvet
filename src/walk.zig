//! Turns the path arguments into the list of files to check.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Appends what `arg`, relative to `base`, names to `files`: `arg` itself if
/// it is a file, whatever its extension, or every `.zig` file under it if it
/// is a directory, as `arg` joined with the path inside it. Directories that
/// are hidden or hold build output or fetched packages are not walked into.
///
/// Each path is cleaned the way `std.fs.path.resolveAlloc` does it, on the
/// text alone: `.`, `..` and repeated separators collapse, and on Windows
/// every separator becomes `\`. So one file reached two ways, `zigvet .
/// src/a.zig`, is one string, and is checked and reported once. The
/// appended paths are allocated with `arena`.
///
/// Nothing that is one of `excludes`, or inside one, is listed or walked
/// into. They must be cleaned the same way.
pub fn collect(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    arg: []const u8,
    excludes: []const []const u8,
    files: *std.ArrayList([]const u8),
) !void {
    const stat = try base.statFile(io, arg, .{});
    const root = try std.fs.path.resolveAlloc(arena, &.{arg});
    if (excluded(root, excludes)) return;
    if (stat.kind != .directory) {
        try files.append(arena, root);
        return;
    }
    var dir = try base.openDir(io, arg, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => if (!skipDir(entry.basename)) {
            const path = try std.fs.path.resolveAlloc(arena, &.{ arg, entry.path });
            if (!excluded(path, excludes)) try walker.enter(io, entry);
        },
        .file => if (std.mem.endsWith(u8, entry.basename, ".zig")) {
            const path = try std.fs.path.resolveAlloc(arena, &.{ arg, entry.path });
            if (!excluded(path, excludes)) try files.append(arena, path);
        },
        else => {},
    };
}

/// Whether `path` is one of `excludes`, or inside one.
fn excluded(path: []const u8, excludes: []const []const u8) bool {
    for (excludes) |exclude| {
        if (!std.mem.startsWith(u8, path, exclude)) continue;
        if (path.len == exclude.len or std.fs.path.isSep(path[exclude.len])) return true;
    }
    return false;
}

/// Sorts `files` and drops repeats, so output order is stable and a file
/// named twice is checked once.
pub fn sortUnique(files: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, files.items, {}, lessThan);
    var kept: usize = 0;
    for (files.items) |path| {
        if (kept > 0 and std.mem.eql(u8, files.items[kept - 1], path)) continue;
        files.items[kept] = path;
        kept += 1;
    }
    files.shrinkRetainingCapacity(kept);
}

fn skipDir(name: []const u8) bool {
    return name[0] == '.' or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-pkg") or
        std.mem.eql(u8, name, "zig-cache");
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "collect: .zig files under a directory, skipping build output and hidden dirs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "proj/a.zig",
        "proj/notes.txt",
        "proj/build.zig.zon",
        "proj/sub/b.zig",
        "proj/zig-out/c.zig",
        "proj/zig-pkg/d.zig",
        "proj/.zig-cache/e.zig",
        "proj/.git/f.zig",
    }) |sub_path| {
        if (std.fs.path.dirname(sub_path)) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "" });
    }

    var files: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, tmp.dir, "proj", &.{}, &files);
    try collect(arena, io, tmp.dir, "proj/notes.txt", &.{}, &files);
    sortUnique(&files);

    try expectPaths(arena, &.{ "proj/a.zig", "proj/notes.txt", "proj/sub/b.zig" }, files.items);
}

test "collect: one file reached several ways is listed once" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "proj/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/sub/b.zig", .data = "" });

    var files: std.ArrayList([]const u8) = .empty;
    // A leading `./`, a trailing separator, `/` where Windows uses `\`, and
    // a file both walked to and named.
    try collect(arena, io, tmp.dir, "./proj/", &.{}, &files);
    try collect(arena, io, tmp.dir, "proj/a.zig", &.{}, &files);
    try collect(arena, io, tmp.dir, "proj", &.{}, &files);
    sortUnique(&files);

    try expectPaths(arena, &.{ "proj/a.zig", "proj/sub/b.zig" }, files.items);
}

/// `expected` is written with `/`; each is compared in the native form.
fn expectPaths(arena: Allocator, expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqualStrings(try std.fs.path.resolveAlloc(arena, &.{want}), got);
    }
}

test "collect: a missing path is an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var files: std.ArrayList([]const u8) = .empty;
    try std.testing.expectError(
        error.FileNotFound,
        collect(std.testing.allocator, std.testing.io, tmp.dir, "nope", &.{}, &files),
    );
}

test "collect: an excluded directory is not walked into, an excluded file not listed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "proj/a.zig",
        "proj/_tmp/wt/a.zig",
        "proj/_tmpfile.zig",
        "proj/gen/b.zig",
        "proj/gen/c.zig",
    }) |sub_path| {
        if (std.fs.path.dirname(sub_path)) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "" });
    }

    const excludes = [_][]const u8{
        try std.fs.path.resolveAlloc(arena, &.{"proj/_tmp"}),
        try std.fs.path.resolveAlloc(arena, &.{"proj/gen/c.zig"}),
    };
    var files: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, tmp.dir, "proj", &excludes, &files);
    // Named outright, an excluded file is still skipped.
    try collect(arena, io, tmp.dir, "proj/_tmp/wt/a.zig", &excludes, &files);
    sortUnique(&files);

    // `_tmpfile.zig` shares `_tmp`'s first letters but is not inside it.
    try expectPaths(arena, &.{ "proj/_tmpfile.zig", "proj/a.zig", "proj/gen/b.zig" }, files.items);
}
