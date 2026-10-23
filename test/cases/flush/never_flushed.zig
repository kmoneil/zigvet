// A buffered file or stream writer written to and never flushed (#58):
// the line stays in `buf` and goes with `fw` when `greet` returns. `zig
// run` of it exits 0 and prints nothing. `fail` is a terminal emulator's
// command that prints why it failed, to a buffered stderr, and returns 1
// with the message still in the buffer.
const std = @import("std");

fn greet(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    try fw.interface.print("hello from greet\n", .{});
}

fn fail(io: std.Io) !u8 {
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const stderr = &stderr_writer.interface;
    try stderr.print("+toggle-quick-terminal is not supported on this platform.\n", .{});
    return 1;
}

// Not reported: flushed, through the interface or the writer's own
// `flush`, and an unbuffered writer, which writes straight through.
fn greetFlushed(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    try fw.interface.print("hello from greet\n", .{});
    try fw.interface.flush();
}
fn failFlushed(io: std.Io) !u8 {
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    try stderr_writer.interface.print("not supported\n", .{});
    try stderr_writer.flush();
    return 1;
}
fn greetUnbuffered(io: std.Io) !void {
    var fw = std.Io.File.stdout().writerStreaming(io, &.{});
    try fw.interface.print("hello from greet\n", .{});
}

comptime {
    _ = &greet;
    _ = &fail;
    _ = &greetFlushed;
    _ = &failFlushed;
    _ = &greetUnbuffered;
}

// error
//
// :10:9: error: 'fw' keeps what is written through it in `&buf` until it is flushed, and nothing here flushes it or hands it on, so the last of it is never written
// :16:9: error: 'stderr_writer' keeps what is written through it in `&buf` until it is flushed, and nothing here flushes it or hands it on, so the last of it is never written
