// `@call(.always_tail, ...)` asked for only where the backend makes a tail
// call (#219): the fix, a modifier held in a constant that tests the
// backend, and the other ways code shows it has thought of it. None is
// reported.
const std = @import("std");
const builtin = @import("builtin");

const tail: std.lang.CallModifier = if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto;

fn rest(xs: []const u8, i: usize) usize {
    for (xs[i..], i..) |x, j| {
        if (x == 0) return j;
    }
    return xs.len;
}

pub fn scan(xs: []const u8, start: usize) usize {
    var i = start;
    while (i + 4 <= xs.len) : (i += 4) {
        if (std.mem.findScalar(u8, xs[i..][0..4], 0)) |k| return i + k;
    }
    return @call(tail, rest, .{ xs, i });
}

// In a branch on the backend.
pub fn scanIf(xs: []const u8, start: usize) usize {
    if (builtin.zig_backend == .stage2_llvm) return @call(.always_tail, rest, .{ xs, start });
    return rest(xs, start);
}

pub fn scanSwitch(xs: []const u8, start: usize) usize {
    switch (builtin.zig_backend) {
        .stage2_llvm => return @call(.always_tail, rest, .{ xs, start }),
        else => return rest(xs, start),
    }
}

// Refused, as an interpreter that needs its jumps does: the error is the
// author's, and it says why.
pub fn step(xs: []const u8, start: usize) usize {
    if (builtin.zig_backend == .stage2_x86_64) {
        @compileError("this scanner needs a backend with tail calls");
    }
    return @call(.always_tail, rest, .{ xs, start });
}

// Chosen once, and named nowhere else.
pub const find = if (builtin.zig_backend == .stage2_llvm) findTail else rest;

fn findTail(xs: []const u8, start: usize) usize {
    return @call(.always_tail, rest, .{ xs, start });
}

test find {
    try std.testing.expectEqual(@as(usize, 2), find(&.{ 1, 2, 0 }, 0));
    try std.testing.expectEqual(@as(usize, 2), scan(&.{ 1, 2, 0 }, 0));
}

comptime {
    _ = &scan;
    _ = &scanIf;
    _ = &scanSwitch;
    _ = &find;
    if (builtin.zig_backend == .stage2_llvm) _ = &step;
}

// compile
