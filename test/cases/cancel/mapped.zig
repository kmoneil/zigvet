// A wait whose every error is returned as another (#238). error.Canceled
// is the one error a sleep has, so a canceled task says it timed out, and
// a caller that would stop on error.Canceled goes on, or retries.
const std = @import("std");
const Io = std.Io;

fn pause(io: Io) error{Timeout}!void {
    io.sleep(.fromSeconds(5), .awake) catch return error.Timeout;
}

/// A lookup's wait for its answer: late and canceled read the same.
fn answered(io: Io, done: *Io.Event, left: Io.Timeout) error{Timeout}!void {
    done.waitTimeout(io, left) catch return error.Timeout;
}

/// A retry's backoff, its cancel returned as a made-up error.
fn backoff(io: Io) error{Unreachable}!void {
    io.sleep(.fromMilliseconds(100), .awake) catch |err| switch (err) {
        else => return error.Unreachable,
    };
}

// Not reported: error.Canceled let through, by `try` or by name.
fn tried(io: Io) Io.Cancelable!void {
    try io.sleep(.fromSeconds(5), .awake);
}
fn named(io: Io, done: *Io.Event, left: Io.Timeout) (Io.Cancelable || error{Timeout})!void {
    done.waitTimeout(io, left) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.Timeout => return error.Timeout,
    };
}

comptime {
    _ = &pause;
    _ = &answered;
    _ = &backoff;
    _ = &tried;
    _ = &named;
}

// error
//
// :8:39: error: whatever io.sleep returns comes back as error.Timeout, error.Canceled included, so whoever canceled the task is told something else happened, and a caller that stops on error.Canceled carries on
// :13:32: error: whatever done.waitTimeout returns comes back as error.Timeout, error.Canceled included, so whoever canceled the task is told something else happened, and a caller that stops on error.Canceled carries on
// :18:46: error: whatever io.sleep returns comes back as error.Unreachable, error.Canceled included, so whoever canceled the task is told something else happened, and a caller that stops on error.Canceled carries on
