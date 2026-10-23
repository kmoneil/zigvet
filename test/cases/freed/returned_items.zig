// A function returns what its own defer frees (#54): the defer runs after
// the return value is made and before the caller gets it, so `joined`
// always hands back freed memory. A test of it reads `UUUU` where it
// wrote `abcd`.
const std = @import("std");

fn joined(gpa: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, a);
    try list.appendSlice(gpa, b);
    return list.items;
}

fn rendered(gpa: std.mem.Allocator, n: u32) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.print("{d}", .{n});
    return aw.written();
}

// Not reported: the memory handed over, so the defer frees nothing, and a
// copy made before the defer runs.
fn joinedOwned(gpa: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, a);
    try list.appendSlice(gpa, b);
    return list.toOwnedSlice(gpa);
}
fn renderedCopy(gpa: std.mem.Allocator, n: u32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.print("{d}", .{n});
    return gpa.dupe(u8, aw.written());
}

comptime {
    _ = &joined;
    _ = &rendered;
    _ = &joinedOwned;
    _ = &renderedCopy;
}

// error
//
// :12:12: error: returns `list.items`, which `defer list.deinit(gpa)` above frees before the caller gets it
// :19:12: error: returns `aw.written()`, which `defer aw.deinit()` above frees before the caller gets it
