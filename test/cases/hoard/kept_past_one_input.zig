// In fuzz mode the test runner gives each input a fresh
// std.testing.allocator and exits 1 if that input leaks from it. Memory
// from any other allocator is not checked, and a target that keeps it
// grows with every input, while the leak check passes (#132). The first is
// the issue's shape: every input's copy kept in a global for the run.
const std = @import("std");

var seen: std.ArrayList([]const u8) = .empty;

fn parse(input: []const u8) ?usize {
    return if (input.len > 0) input.len else null;
}

fn one(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    try seen.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, input));
    _ = parse(input);
}

const Context = struct { gpa: std.mem.Allocator };

fn scratch(ctx: Context, smith: *std.testing.Smith) anyerror!void {
    var buf: [64]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const copy = try ctx.gpa.dupe(u8, input);
    _ = parse(copy);
}

// Not reported: memory the runner checks, memory given back before the
// input ends, and the test block, which runs once.
fn checked(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [64]u8 = undefined;
    const copy = try std.testing.allocator.dupe(u8, buf[0..smith.slice(&buf)]);
    defer std.testing.allocator.free(copy);
    _ = parse(copy);
}

fn freed(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var buf: [64]u8 = undefined;
    const copy = try arena.allocator().dupe(u8, buf[0..smith.slice(&buf)]);
    _ = parse(copy);
}

test "fuzz" {
    const once = try std.heap.page_allocator.alloc(u8, 16);
    defer std.heap.page_allocator.free(once);
    try std.testing.fuzz({}, one, .{});
    try std.testing.fuzz(Context{ .gpa = std.heap.page_allocator }, scratch, .{});
    try std.testing.fuzz({}, checked, .{});
    try std.testing.fuzz({}, freed, .{});
}

// `checked` is left to the test block: std.testing.allocator exists only
// in a test build.
comptime {
    _ = &one;
    _ = &scratch;
    _ = &freed;
}

// error
//
// :17:9: error: `seen.append` takes memory from `std.heap.page_allocator` that fuzz target 'one' never gives back, so it piles up over every input, and the runner's leak check sees only std.testing.allocator
// :26:22: error: `ctx.gpa.dupe` takes memory from `ctx.gpa` that fuzz target 'scratch' never gives back, so it piles up over every input, and the runner's leak check sees only std.testing.allocator
