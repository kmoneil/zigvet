// A function handed to a wrapper around std.testing.fuzz is a fuzz target
// too (#136). A runner that also replays seeded inputs under a plain
// `zig build test` passes its context and the function it is given to the
// fuzz call through a target of its own, so the function that does the
// work is never the fuzz call's argument.
const std = @import("std");

pub fn run(
    context: anytype,
    comptime testOne: fn (@TypeOf(context), *std.testing.Smith) anyerror!void,
) anyerror!void {
    try std.testing.fuzz(context, struct {
        fn one(ctx: @TypeOf(context), smith: *std.testing.Smith) anyerror!void {
            try testOne(ctx, smith);
        }
    }.one, .{});
}

var seen: std.ArrayList([]const u8) = .empty;

fn keep(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    try seen.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, input));
}

// Not reported: memory given back before the input ends.
fn scratch(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [64]u8 = undefined;
    const copy = try std.heap.page_allocator.dupe(u8, buf[0..smith.slice(&buf)]);
    defer std.heap.page_allocator.free(copy);
}

test "fuzz" {
    try run({}, keep);
    try run({}, scratch);
}

comptime {
    _ = &keep;
    _ = &scratch;
}

// error
//
// :24:9: error: `seen.append` takes memory from `std.heap.page_allocator` that fuzz target 'keep' never gives back, so it piles up over every input, and the runner's leak check sees only std.testing.allocator
