// A std reader or writer holds the buffer it is given, so one made over
// the function's own memory and returned carries that address out with it
// (#125). `Sink` is from an app that opened an output file and kept the
// buffer inline, next to the writer that uses it.
const std = @import("std");
const Io = std.Io;
const File = Io.File;

const Sink = struct {
    file: File,
    writer: File.Writer,
    buf: [1 << 16]u8 = undefined,

    fn create(io: Io, path: []const u8) !Sink {
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        var s: Sink = .{ .file = file, .writer = undefined };
        s.writer = file.writer(io, &s.buf);
        return s;
    }
};

const Fixed = struct {
    buf: [64]u8 = undefined,
    w: Io.Writer = undefined,

    fn init() Fixed {
        var s: Fixed = .{};
        s.w = .fixed(&s.buf);
        return s;
    }
};

fn reader(bytes: []const u8) Io.Reader {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..bytes.len], bytes);
    return Io.Reader.fixed(buf[0..bytes.len]);
}
fn writer() Io.Writer {
    var buf: [64]u8 = undefined;
    const w: Io.Writer = .fixed(&buf);
    return w;
}
fn streaming(file: File, io: Io) struct { r: File.Reader } {
    var buf: [256]u8 = undefined;
    return .{ .r = File.readerStreaming(file, io, &buf) };
}
fn initialized(file: File, io: Io) File.Writer {
    var buf: [256]u8 = undefined;
    return std.Io.File.Writer.init(file, io, &buf);
}

// Not reported: a buffer the caller passes in, one on the heap, an `init`
// of a type other than a reader or writer, and the file's own method of
// that name, both of which copy what they are given.
fn over(buf: []u8) Io.Writer {
    return .fixed(buf);
}
fn onHeap(gpa: std.mem.Allocator) !*Fixed {
    const s = try gpa.create(Fixed);
    s.w = .fixed(&s.buf);
    return s;
}
fn keyed(seed: u8) std.crypto.auth.hmac.sha2.HmacSha256 {
    var key: [32]u8 = @splat(seed);
    key[0] = 0;
    return std.crypto.auth.hmac.sha2.HmacSha256.init(&key);
}

const Log = struct {
    bytes: [16]u8 = undefined,
    len: usize = 0,

    fn writer(log: Log, io: Io, buf: []const u8) Log {
        _ = io;
        var copy = log;
        @memcpy(copy.bytes[0..buf.len], buf);
        copy.len = buf.len;
        return copy;
    }
};
fn logged(log: Log, io: Io) Log {
    var line: [4]u8 = @splat('x');
    line[0] = 'y';
    return log.writer(io, &line);
}

comptime {
    _ = &Sink.create;
    _ = &Fixed.init;
    _ = &reader;
    _ = &writer;
    _ = &streaming;
    _ = &initialized;
    _ = &over;
    _ = &onHeap;
    _ = &keyed;
    _ = &logged;
}

// error
//
// :17:36: error: address of a field of local 's' made here leaves create through return
// :28:22: error: address of a field of local 's' made here leaves init through return
// :36:28: error: slice of local 'buf' made here leaves reader through return
// :40:33: error: address of local 'buf' made here leaves writer through return
// :45:51: error: address of local 'buf' made here leaves streaming through return
// :49:46: error: address of local 'buf' made here leaves initialized through return
