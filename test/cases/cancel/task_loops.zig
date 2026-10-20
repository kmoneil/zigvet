// In a task's loop, a dropped error from an Io call swallows the one
// error.Canceled the task is sent, so it runs on (#17).
const std = @import("std");
const Io = std.Io;

fn worker(io: Io) void {
    while (true) {
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}
fn list(io: Io, dir: Io.Dir, names: []const []const u8) void {
    for (names) |name| {
        _ = dir.statFile(io, name, .{}) catch continue;
    }
}
fn serve(io: Io, dir: Io.Dir, names: []const []const u8) void {
    while (true) list(io, dir, names);
}
fn start(io: Io, dir: Io.Dir, names: []const []const u8) !void {
    var w = try io.concurrent(worker, .{io});
    defer w.cancel(io);
    var s = try io.concurrent(serve, .{ io, dir, names });
    defer s.cancel(io);
}

comptime {
    _ = &start;
}

// error
//
// :8:48: error: `catch {}` drops what io.sleep returns, error.Canceled included, which is delivered once
// :13:41: error: `catch continue` drops what dir.statFile returns, error.Canceled included, which is delivered once
