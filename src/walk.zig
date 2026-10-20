//! Turns the path arguments into the list of files to check.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Appends what `arg`, relative to `base`, names to `files`: `arg` itself if
/// it is a file, whatever its extension, or every `.zig` file under it if it
/// is a directory, as `arg` joined with the path inside it. Directories that
/// are hidden or hold build output or fetched packages are not walked into.
/// The appended paths are allocated with `arena`.
pub fn collect(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    arg: []const u8,
    files: *std.ArrayList([]const u8),
) !void {
    const stat = try base.statFile(io, arg, .{});
    if (stat.kind != .directory) {
        try files.append(arena, arg);
        return;
    }
    var dir = try base.openDir(io, arg, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => if (!skipDir(entry.basename)) try walker.enter(io, entry),
        .file => if (std.mem.endsWith(u8, entry.basename, ".zig")) {
            try files.append(arena, try std.fs.path.join(arena, &.{ arg, entry.path }));
        },
        else => {},
    };
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
    try collect(arena, io, tmp.dir, "proj", &files);
    try collect(arena, io, tmp.dir, "proj/notes.txt", &files);
    try collect(arena, io, tmp.dir, "proj/a.zig", &files);
    sortUnique(&files);

    const expected = [_][]const u8{
        try std.fs.path.join(arena, &.{ "proj", "a.zig" }),
        "proj/notes.txt",
        try std.fs.path.join(arena, &.{ "proj", "sub", "b.zig" }),
    };
    try std.testing.expectEqual(expected.len, files.items.len);
    for (expected, files.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "collect: a trailing separator on the argument is not doubled" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });

    var files: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, tmp.dir, "src" ++ std.fs.path.sep_str, &files);
    try std.testing.expectEqual(1, files.items.len);
    try std.testing.expectEqualStrings("src" ++ std.fs.path.sep_str ++ "main.zig", files.items[0]);
}

test "collect: a missing path is an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var files: std.ArrayList([]const u8) = .empty;
    try std.testing.expectError(
        error.FileNotFound,
        collect(std.testing.allocator, std.testing.io, tmp.dir, "nope", &files),
    );
}
