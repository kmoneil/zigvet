// A container-level optional asked whether it is null by value, when what
// it holds has a lock in it (#170). In Debug, `registry == null` copies
// all of `registry` before it reads the tag: a plain read of the mutex,
// racing the cmpxchg of every thread that locks it. ThreadSanitizer
// reports it on x86_64 Linux. The first is the shape of a lazily started
// registry, asked on every call from every thread.
const std = @import("std");

const Registry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    hits: usize = 0,
};

var registry: ?Registry = null;

fn state(gpa: std.mem.Allocator, io: std.Io) *Registry {
    if (registry == null) registry = .{ .gpa = gpa, .io = io };
    return &registry.?;
}

fn hits() usize {
    if (registry) |r| return r.hits;
    return 0;
}

// Not reported: through a pointer, which reads only the tag; `.?`, which
// reads in place; a threadlocal, which no other thread reaches; and a
// payload with no atomics or lock, where the copy only costs.
fn fixed(gpa: std.mem.Allocator, io: std.Io) *Registry {
    if (registry) |*r| return r;
    registry = .{ .gpa = gpa, .io = io };
    return &registry.?;
}

fn lock(io: std.Io) !void {
    try registry.?.mutex.lock(io);
}

threadlocal var scratch: ?Registry = null;

fn mine() bool {
    return scratch == null;
}

const Config = struct { name: []const u8, port: u16 };
var config: ?Config = null;

fn configured() bool {
    return config != null;
}

comptime {
    _ = &state;
    _ = &hits;
    _ = &fixed;
    _ = &lock;
    _ = &mine;
    _ = &configured;
}

// error
//
// :19:9: error: `registry == null` copies all of `registry` to read whether it is null, and `mutex` (`std.Io.Mutex`) with it: in Debug that copy is a plain read, a data race with the atomic writes other threads make to it
// :24:9: error: `if (registry) |r|` copies all of `registry` to read whether it is null, and `mutex` (`std.Io.Mutex`) with it: in Debug that copy is a plain read, a data race with the atomic writes other threads make to it
