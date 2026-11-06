// A positional reader on stdin (#177). Redirected from a regular file it
// reads from byte 0 at a position of its own and never moves the file's
// offset, so `{ read -r header; prog; } < input` reads the header line
// again, and what reads after it starts where the program did. The first
// is zig-charts' `zc render -`, which refused its input as malformed JSON.
const std = @import("std");
const Io = std.Io;

fn render(io: Io, gpa: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().reader(io, &buf);
    return r.interface.allocRemaining(gpa, .limited(1 << 20));
}

fn lines(io: Io) !usize {
    var buf: [256]u8 = undefined;
    var in: Io.File.Reader = .init(.stdin(), io, &buf);
    var n: usize = 0;
    while (try in.interface.takeDelimiter('\n')) |_| n += 1;
    return n;
}

// Not reported: the streaming readers, a file the program opens and is the
// only reader of, and a reader over Io.failing, which fails every read.
fn streaming(io: Io, gpa: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().readerStreaming(io, &buf);
    return r.interface.allocRemaining(gpa, .limited(1 << 20));
}
fn initStreaming(io: Io) !usize {
    var buf: [256]u8 = undefined;
    var in: Io.File.Reader = .initStreaming(.stdin(), io, &buf);
    var n: usize = 0;
    while (try in.interface.takeDelimiter('\n')) |_| n += 1;
    return n;
}
fn fromFile(io: Io, file: Io.File, gpa: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    return r.interface.allocRemaining(gpa, .limited(1 << 20));
}
fn failing() !void {
    var buf: [256]u8 = undefined;
    var in: Io.File.Reader = .init(.stdin(), .failing, &buf);
    try std.testing.expectError(error.ReadFailed, in.interface.takeByte());
}

comptime {
    _ = &render;
    _ = &lines;
    _ = &streaming;
    _ = &initStreaming;
    _ = &fromFile;
    _ = &failing;
}

// error
//
// :11:13: error: `std.Io.File.stdin().reader(...)` makes a positional reader on stdin: redirected from a file, it reads from byte 0 at a position of its own, so what was read from the file before it is read again (`{ read -r header; prog; } < input`)
// :17:30: error: `.init(...)` makes a positional reader on stdin: redirected from a file, it reads from byte 0 at a position of its own, so what was read from the file before it is read again (`{ read -r header; prog; } < input`)
