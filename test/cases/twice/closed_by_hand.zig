// A defer's release also written out by hand (#212): the defer runs however
// its block is left, so every run releases twice. The first is the issue's,
// a test that closes its listener by hand, to see the next connection
// refused, under the defer that closes it: the second close of a descriptor
// closes whatever another thread was given that number in between.
// `replace` closes a file before the rename, as Windows needs, and `longUpper`
// frees before an early return.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

test "a connection is refused once the listener is closed" {
    const io = std.testing.io;
    const any: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{});
    defer server.deinit(io);
    const address = server.socket.address;
    const stream = try address.connect(io, .{ .mode = .stream });
    stream.close(io);
    server.deinit(io);
    try std.testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
}

fn replace(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    const file = try dir.createFile(io, "new", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
    file.close(io);
    try dir.rename("new", dir, name, io);
}

fn longUpper(gpa: Allocator, lines: []const []const u8) !?usize {
    for (lines, 0..) |line, i| {
        const upper = try std.ascii.allocUpperString(gpa, line);
        defer gpa.free(upper);
        if (upper.len > 80) {
            gpa.free(upper);
            return i;
        }
    }
    return null;
}

// Not reported: a defer that the release by hand turns off; a name given
// something new after it, which is what the defer then frees; a release
// before an exit, which runs no defer; a close that stores to what it
// closes, so the second closes nothing; and a queue's close, which std
// documents as idempotent.
fn replaceOnce(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    const file = try dir.createFile(io, "new", .{});
    var open = true;
    defer if (open) file.close(io);
    try file.writeStreamingAll(io, data);
    file.close(io);
    open = false;
    try dir.rename("new", dir, name, io);
}

fn longest(gpa: Allocator, lines: []const []const u8) !usize {
    var best = try gpa.dupe(u8, "");
    defer gpa.free(best);
    for (lines) |line| {
        if (line.len <= best.len) continue;
        const next = try gpa.dupe(u8, line);
        gpa.free(best);
        best = next;
    }
    return best.len;
}

fn usage(gpa: Allocator, args: []const []const u8) !usize {
    const joined = try std.mem.join(gpa, " ", args);
    defer gpa.free(joined);
    if (args.len == 0) {
        gpa.free(joined);
        std.process.exit(2);
    }
    return joined.len;
}

const Client = struct {
    stream: ?Io.net.Stream = null,

    fn close(self: *Client, io: Io) void {
        if (self.stream) |stream| stream.close(io);
        self.stream = null;
    }
};

fn hangUp(io: Io, client: *Client) void {
    defer client.close(io);
    client.close(io);
}

const Worker = struct {
    queue: Io.Queue(u32),

    fn run(self: *Worker, io: Io) !void {
        defer self.queue.close(io);
        try self.queue.putOne(io, 1);
        self.queue.close(io);
    }
};

comptime {
    _ = &replace;
    _ = &longUpper;
    _ = &replaceOnce;
    _ = &longest;
    _ = &usage;
    _ = &hangUp;
    _ = &Worker.run;
}

// error
//
// :20:5: error: `server.deinit(io)` here, and the defer above it does the same again when its block ends
// :28:5: error: `file.close(io)` here, and the defer above it does the same again when its block ends
// :37:13: error: `gpa.free(upper)` here, and the defer above it does the same again when its block ends
