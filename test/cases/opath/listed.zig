// A directory opened without `.iterate = true`, then listed or given new
// permissions (#208). Linux opens it with O_PATH, a descriptor that names
// the directory and cannot read or change it: `getdents64`, `fchmod` and
// `fchown` of one are EBADF, a panic in Debug and error.Unexpected
// otherwise, where macOS, which has no O_PATH, passes. std says so of
// `Dir.setPermissions` and `Dir.setOwner`, and of `openDir` for `iterate`.
const std = @import("std");
const Io = std.Io;

fn count(io: Io, dir: Io.Dir, sub: []const u8) !usize {
    var d = try dir.openDir(io, sub, .{});
    defer d.close(io);
    var n: usize = 0;
    var it = d.iterate();
    while (try it.next(io)) |_| n += 1;
    return n;
}

fn sources(io: Io, gpa: std.mem.Allocator, path: []const u8) !usize {
    var d = try Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false });
    defer d.close(io);
    var walker = try d.walk(gpa);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.basename, ".zig")) n += 1;
    }
    return n;
}

// The error is dropped, so in a release build on Linux the cache keeps
// the mode it was made with and nothing says so.
fn private(io: Io, path: []const u8) !Io.Dir {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, path);
    var dir = try cwd.openDir(io, path, .{});
    dir.setPermissions(io, .fromMode(0o700)) catch {};
    return dir;
}

fn handOver(io: Io, dir: Io.Dir, uid: Io.File.Uid) !void {
    var spool = try dir.createDirPathOpen(io, "spool", .{ .open_options = .{ .follow_symlinks = false } });
    defer spool.close(io);
    try spool.setOwner(io, uid, null);
}

// A test's own directory: `tmpDir` takes the same options.
test "nothing is left behind" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "kept", .data = "" });
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| try std.testing.expectEqualStrings("kept", entry.name);
}

// Not reported: opened for iterating; options the caller picks; and a
// directory used only for what is under it and for `fstat`, which an
// O_PATH descriptor allows.
fn countIterable(io: Io, dir: Io.Dir, sub: []const u8) !usize {
    var d = try dir.openDir(io, sub, .{ .iterate = true });
    defer d.close(io);
    var n: usize = 0;
    var it = d.iterate();
    while (try it.next(io)) |_| n += 1;
    return n;
}
fn countDeep(io: Io, dir: Io.Dir, sub: []const u8, deep: bool) !usize {
    var d = try dir.openDir(io, sub, .{ .iterate = deep });
    defer d.close(io);
    if (!deep) return 0;
    var n: usize = 0;
    var it = d.iterate();
    while (try it.next(io)) |_| n += 1;
    return n;
}
fn countWith(io: Io, dir: Io.Dir, sub: []const u8, options: Io.Dir.OpenOptions) !usize {
    var d = try dir.openDir(io, sub, options);
    defer d.close(io);
    var n: usize = 0;
    var it = d.iterate();
    while (try it.next(io)) |_| n += 1;
    return n;
}
fn readOne(io: Io, dir: Io.Dir, sub: []const u8, buffer: []u8) ![]u8 {
    var d = try dir.openDir(io, sub, .{});
    defer d.close(io);
    _ = try d.stat(io);
    try d.access(io, "manifest", .{});
    return d.readFile(io, "manifest", buffer);
}
test "a directory a test lists" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var it = tmp.dir.iterate();
    try std.testing.expectEqual(null, try it.next(io));
}

comptime {
    _ = &count;
    _ = &sources;
    _ = &private;
    _ = &handOver;
    _ = &countIterable;
    _ = &countDeep;
    _ = &countWith;
    _ = &readOne;
}

// error
//
// :11:17: error: `d` is opened without `.iterate = true`, which on Linux is an O_PATH descriptor, and `d.iterate()` below lists it: that is EBADF there, a panic in Debug and error.Unexpected otherwise, while macOS, which has no O_PATH, passes
// :20:17: error: `d` is opened without `.iterate = true`, which on Linux is an O_PATH descriptor, and `d.walk(gpa)` below lists it: that is EBADF there, a panic in Debug and error.Unexpected otherwise, while macOS, which has no O_PATH, passes
// :36:19: error: `dir` is opened without `.iterate = true`, which on Linux is an O_PATH descriptor, and `dir.setPermissions(io, .fromMode(0o700))` below sets its permissions: that is EBADF there, a panic in Debug and error.Unexpected otherwise, while macOS, which has no O_PATH, passes
// :42:21: error: `spool` is opened without `.iterate = true`, which on Linux is an O_PATH descriptor, and `spool.setOwner(io, uid, null)` below sets its owner: that is EBADF there, a panic in Debug and error.Unexpected otherwise, while macOS, which has no O_PATH, passes
// :50:15: error: `tmp.dir` is opened without `.iterate = true`, which on Linux is an O_PATH descriptor, and `tmp.dir.iterate()` below lists it: that is EBADF there, a panic in Debug and error.Unexpected otherwise, while macOS, which has no O_PATH, passes
