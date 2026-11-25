// A directory opened without `.iterate = true`, then synced through its
// handle (#208). On Linux, Zig opens it with O_PATH, and fsync of an O_PATH
// descriptor is EBADF: a panic in Debug and error.Unexpected otherwise,
// where macOS, which has no O_PATH, passes. The first is the issue's: a
// blob store that syncs the directory a new file was renamed into, and
// failed every write of a new file on Linux while its tests passed on
// macOS.
const std = @import("std");
const Io = std.Io;

fn syncSub(io: Io, dir: Io.Dir, sub: []const u8) !void {
    const d = try dir.openDir(io, sub, .{});
    defer d.close(io);
    const as_file: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}

// The sync is in a function of the file, and the directory is opened by
// the one that calls it.
fn syncDir(io: Io, dir: Io.Dir) !void {
    const as_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}
fn put(io: Io, root: Io.Dir, slot: []const u8) !void {
    var staging = try root.createDirPathOpen(io, "staging", .{});
    {
        defer staging.close(io);
        try staging.writeFile(io, .{ .sub_path = "manifest", .data = slot });
        try syncDir(io, staging);
    }
    try root.rename("staging", root, slot, io);
    var slots = try root.openDir(io, "slots", .{});
    defer slots.close(io);
    try syncDir(io, slots);
}

// Not reported: opened for iterating, which Linux opens without O_PATH; a
// file of the directory's handle that is only asked what `fstat` answers;
// and a directory handed to a function at a parameter it does not sync.
fn syncSubIterable(io: Io, dir: Io.Dir, sub: []const u8) !void {
    const d = try dir.openDir(io, sub, .{ .iterate = true });
    defer d.close(io);
    const as_file: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}
fn putIterable(io: Io, root: Io.Dir) !void {
    var slots = try root.createDirPathOpen(io, "slots", .{ .open_options = .{ .iterate = true } });
    defer slots.close(io);
    try syncDir(io, slots);
}
fn modified(io: Io, dir: Io.Dir, sub: []const u8) !Io.Timestamp {
    const d = try dir.openDir(io, sub, .{});
    defer d.close(io);
    const as_file: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
    return (try as_file.stat(io)).mtime;
}
fn moveInto(io: Io, from: Io.Dir, to: Io.Dir, name: []const u8) !void {
    try from.rename(name, to, name, io);
    try syncDir(io, from);
}
fn move(io: Io, root: Io.Dir, name: []const u8) !void {
    var from = try root.openDir(io, "incoming", .{ .iterate = true });
    defer from.close(io);
    var to = try root.openDir(io, "kept", .{});
    defer to.close(io);
    try moveInto(io, from, to, name);
}

comptime {
    _ = &syncSub;
    _ = &put;
    _ = &syncSubIterable;
    _ = &putIterable;
    _ = &modified;
    _ = &move;
}

// error
//
// :12:19: error: `d` is opened without `.iterate = true`, which on Linux is an O_PATH descriptor, and `as_file.sync(io)` below syncs it: that is EBADF there, a panic in Debug and error.Unexpected otherwise, while macOS, which has no O_PATH, passes
// :25:23: error: `staging` is opened without `.iterate = true`, which on Linux is an O_PATH descriptor, and 'syncDir', which `syncDir(io, staging)` below hands it to, syncs it (`as_file.sync(io)`): that is EBADF there, a panic in Debug and error.Unexpected otherwise, while macOS, which has no O_PATH, passes
// :32:21: error: `slots` is opened without `.iterate = true`, which on Linux is an O_PATH descriptor, and 'syncDir', which `syncDir(io, slots)` below hands it to, syncs it (`as_file.sync(io)`): that is EBADF there, a panic in Debug and error.Unexpected otherwise, while macOS, which has no O_PATH, passes
