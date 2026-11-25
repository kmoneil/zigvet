// `@call(.always_tail, ...)` with nothing that tests the backend (#219).
// LLVM makes the call a jump. Zig's own x86_64 backend, the Debug default
// on x86_64 Linux, makes no tail calls, so this file compiles on macOS and
// in every release build, and a Debug build on x86_64 Linux fails at each
// of them: "unable to perform tail call: compiler backend 'stage2_x86_64'
// does not support tail calls". In a library that is every consumer's
// Debug build. The functions are referenced at the bottom only where LLVM
// compiles them, since the cases are compiled for x86_64 Linux too.
const std = @import("std");
const builtin = @import("builtin");

fn rest(xs: []const u8, i: usize) usize {
    for (xs[i..], i..) |x, j| {
        if (x == 0) return j;
    }
    return xs.len;
}

// Four bytes at a time, then the rest a byte at a time, by a jump.
pub fn scan(xs: []const u8, start: usize) usize {
    var i = start;
    while (i + 4 <= xs.len) : (i += 4) {
        if (std.mem.findScalar(u8, xs[i..][0..4], 0)) |k| return i + k;
    }
    return @call(.always_tail, rest, .{ xs, i });
}

test scan {
    try std.testing.expectEqual(@as(usize, 5), scan(&.{ 1, 2, 3, 4, 5, 0 }, 0));
}

// A threaded interpreter: each handler jumps to the next one's.
const Vm = struct {
    code: []const u8,
    acc: i64 = 0,
};
const Handler = *const fn (vm: *Vm, ip: usize) void;
const handlers = [_]Handler{ halt, inc, dec };

fn halt(vm: *Vm, ip: usize) void {
    _ = vm;
    _ = ip;
}

fn inc(vm: *Vm, ip: usize) void {
    vm.acc += 1;
    return @call(.always_tail, handlers[vm.code[ip]], .{ vm, ip + 1 });
}

fn dec(vm: *Vm, ip: usize) void {
    vm.acc -= 1;
    return @call(std.lang.CallModifier.always_tail, handlers[vm.code[ip]], .{ vm, ip + 1 });
}

pub fn run(code: []const u8) i64 {
    var vm: Vm = .{ .code = code };
    handlers[code[0]](&vm, 1);
    return vm.acc;
}

test run {
    try std.testing.expectEqual(@as(i64, 1), run(&.{ 1, 1, 2, 0 }));
}

comptime {
    if (builtin.zig_backend == .stage2_llvm) {
        _ = &scan;
        _ = &run;
    }
}

// error
//
// :25:12: error: `@call(.always_tail, rest, ...)` is a tail call or a compile error, and Zig's own x86_64 backend, the Debug default on x86_64 Linux, has no tail calls: every Debug build there fails, while LLVM's, on macOS and in every release mode, pass
// :47:12: error: `@call(.always_tail, handlers[vm.code[ip]], ...)` is a tail call or a compile error, and Zig's own x86_64 backend, the Debug default on x86_64 Linux, has no tail calls: every Debug build there fails, while LLVM's, on macOS and in every release mode, pass
// :52:12: error: `@call(std.lang.CallModifier.always_tail, handlers[vm.code[ip]], ...)` is a tail call or a compile error, and Zig's own x86_64 backend, the Debug default on x86_64 Linux, has no tail calls: every Debug build there fails, while LLVM's, on macOS and in every release mode, pass
