const std = @import("std");

const Holder = struct {
    current: ?*const u8 = null,
    items: []const u8 = &.{},

    fn whileHandling(self: *Holder, n: u8) void {
        self.current = &n;
        defer self.current = null;
    }

    fn whileBuilding(self: *Holder, n: u8) void {
        const previous = self.items;
        self.items = &.{n};
        defer {
            self.items = previous;
        }
    }
};

threadlocal var current_frame: ?*const [4]u8 = null;

fn worker(n: u8) void {
    var frame: [4]u8 = .{ n, n, n, n };
    current_frame = &frame;
    std.mem.doNotOptimizeAway(&frame);
}

fn readTopics(value: u8) bool {
    const topics: []const u8 = &.{value};
    return std.mem.eql(u8, topics, "a");
}

fn passedToCall(n: u8) bool {
    return std.mem.eql(u8, &.{n}, "a");
}

fn returnsCopy(n: u8) [2]u8 {
    const pair = [_]u8{ n, n };
    return pair;
}

fn throughPointerField(self: struct { inner: *[4]u8 }) []const u8 {
    return &self.inner.*;
}

comptime {
    _ = &Holder.whileHandling;
    _ = &Holder.whileBuilding;
    _ = &worker;
    _ = &readTopics;
    _ = &passedToCall;
    _ = &returnsCopy;
    _ = &throughPointerField;
}

// compile
