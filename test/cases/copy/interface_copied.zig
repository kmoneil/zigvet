// A writer interface copied out of the struct its methods find with
// @fieldParentPtr (#56): `Allocating`'s drain looks for `aw` around `w`,
// and reads the stack next to the copy instead. A test of it crashes in
// `ensureTotalCapacity` with a `vtable` read from the stack.
const std = @import("std");

fn hello(gpa: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var w = aw.writer;
    try w.writeAll("hello");
    return aw.toOwnedSlice();
}

fn greet(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    const fw = std.Io.File.stdout().writerStreaming(io, &buf);
    var out = fw.interface;
    try out.print("hello\n", .{});
    try out.flush();
}

// Not reported: the interface through a pointer, and a method called on
// it where it is.
fn helloByPointer(gpa: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("hello");
    return aw.toOwnedSlice();
}
fn greetInPlace(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    try fw.interface.print("hello\n", .{});
    try fw.interface.flush();
}

comptime {
    _ = &hello;
    _ = &greet;
    _ = &helloByPointer;
    _ = &greetInPlace;
}

// error
//
// :10:13: error: copies `aw.writer`, whose methods find `aw` from its address: the copy's first flush or refill reads what sits next to it as `aw`
// :18:15: error: copies `fw.interface`, whose methods find `fw` from its address: the copy's first flush or refill reads what sits next to it as `fw`
