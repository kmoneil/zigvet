// In a function a task's loop calls, a handler that names error.Canceled
// and returns as though it handled it: the function returns to the loop,
// which goes on with the cancel spent, and whoever cancels the task waits
// for good (#66). A Pub/Sub client's janitor hung CI this way.
const std = @import("std");
const Io = std.Io;

const Janitor = struct {
    io: Io,
    dir: Io.Dir,

    fn loop(j: *Janitor) Io.Cancelable!void {
        while (true) {
            try j.io.sleep(.fromMilliseconds(500), .awake);
            j.flush();
        }
    }

    fn flush(j: *Janitor) void {
        _ = j.dir.statFile(j.io, "acks", .{}) catch |err| {
            if (err == error.Canceled) return;
            std.log.warn("acks: {t}", .{err});
        };
        j.dir.deleteFile(j.io, "acks") catch |err| switch (err) {
            error.Canceled => return,
            else => {},
        };
    }

    // Not reported: the error handed on, and the cancel armed again.
    fn handOn(j: *Janitor) Io.Cancelable!void {
        j.io.sleep(.fromMilliseconds(1), .awake) catch |err| switch (err) {
            error.Canceled => |e| return e,
        };
    }
    fn rearm(j: *Janitor) void {
        j.io.sleep(.fromMilliseconds(1), .awake) catch |err| {
            if (err == error.Canceled) {
                j.io.recancel();
                return;
            }
        };
    }
    fn loopToo(j: *Janitor) Io.Cancelable!void {
        while (true) {
            try j.handOn();
            j.rearm();
        }
    }
};

fn start(j: *Janitor) !void {
    var task = try j.io.concurrent(Janitor.loop, .{j});
    defer task.cancel(j.io) catch {};
    var other = try j.io.concurrent(Janitor.loopToo, .{j});
    defer other.cancel(j.io) catch {};
}

comptime {
    _ = &start;
}

// error
//
// :21:13: error: `if (err == error.Canceled) return` drops what j.dir.statFile returns, error.Canceled included, which is delivered once
// :25:13: error: `error.Canceled => return` drops what j.dir.deleteFile returns, error.Canceled included, which is delivered once
