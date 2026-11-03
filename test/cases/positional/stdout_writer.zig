// A positional writer on stdout or stderr (#8). Redirected to a regular
// file it writes from byte 0 at a position of its own, so under
// `prog > log 2>&1` the two overwrite each other: `result line 1`,
// `warning: something` and `result line 2` come out as
// `warning: sometresult line 2`. The first is the shape of Zig 0.17.0's
// own `zig init` template.
const std = @import("std");
const Io = std.Io;

fn template(io: Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.print("result line 1\n", .{});
    try stdout_writer.flush();
}

fn warn(io: Io) !void {
    var buf: [256]u8 = undefined;
    var err = std.Io.File.stderr().writer(io, &buf);
    try err.interface.print("warning: something\n", .{});
    try err.interface.flush();
}

// Not reported: the streaming writers, and a file the program opens and
// is the only writer of.
fn streaming(io: Io) !void {
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    try out.interface.print("result line 1\n", .{});
    try out.interface.flush();
}
fn initStreaming(io: Io) !void {
    var buf: [256]u8 = undefined;
    var out: Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    try out.interface.print("result line 1\n", .{});
    try out.interface.flush();
}
fn toFile(io: Io, file: Io.File) !void {
    var buf: [256]u8 = undefined;
    var out = file.writer(io, &buf);
    try out.interface.print("result line 1\n", .{});
    try out.interface.flush();
}

comptime {
    _ = &template;
    _ = &warn;
    _ = &streaming;
    _ = &initStreaming;
    _ = &toFile;
}

// error
//
// :12:46: error: `.init(...)` makes a positional writer on stdout: redirected to a file, it writes from byte 0 at a position of its own, over what else is written there (`> log 2>&1`, a shell's `echo`, `>>` on macOS)
// :20:15: error: `std.Io.File.stderr().writer(...)` makes a positional writer on stderr: redirected to a file, it writes from byte 0 at a position of its own, over what else is written there (`> log 2>&1`, a shell's `echo`, `>>` on macOS)
