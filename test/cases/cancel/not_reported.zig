// Not reported: code no task runs, and in a task, what is outside a loop,
// in a defer, or handled.
const std = @import("std");
const Io = std.Io;

fn notATask(io: Io) void {
    while (true) {
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}
fn task(io: Io, dir: Io.Dir) Io.Cancelable!void {
    io.sleep(.fromMilliseconds(1), .awake) catch {};
    while (true) {
        defer io.sleep(.fromMilliseconds(1), .awake) catch {};
        io.sleep(.fromMilliseconds(1), .awake) catch |err| return err;
        _ = dir.statFile(io, "x", .{}) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => {},
        };
    }
}
fn start(io: Io, dir: Io.Dir) !void {
    var t = try io.concurrent(task, .{ io, dir });
    defer t.cancel(io) catch {};
}

comptime {
    _ = &notATask;
    _ = &start;
}

// compile
