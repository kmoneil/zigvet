// A dupe of a slice known to be empty, in the arguments of a call that can
// fail, or first in an initializer (#251). `Allocator.dupe` is `alloc` and
// a copy, and an allocation of 0 bytes returns without calling the
// allocator: nothing is made to release, and the dupe cannot fail.
// std.testing.checkAllAllocationFailures on `seed` passes; on the same
// function with `"x"` in place of `""` it reports `allocated bytes: 1,
// freed bytes: 0`. `seed` is a directory walker's, whose queue starts with
// the root's relative path.
const std = @import("std");

pub fn seed(gpa: std.mem.Allocator, queue: *std.ArrayList([]u8)) !void {
    try queue.append(gpa, try gpa.dupe(u8, ""));
}

pub fn none(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) !void {
    try list.append(gpa, try gpa.dupe(u8, &.{}));
}

pub fn array(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) !void {
    try list.append(gpa, try gpa.dupe(u8, &[_]u8{}));
}

const Ref = struct { module: []u8, name: []u8 };

pub fn root(gpa: std.mem.Allocator, list: *std.ArrayList(Ref), name: []const u8) !void {
    const copy = try gpa.dupe(u8, name);
    errdefer gpa.free(copy);
    try list.append(gpa, .{ .module = try gpa.dupe(u8, ""), .name = copy });
}

comptime {
    _ = &seed;
    _ = &none;
    _ = &array;
    _ = &root;
}

// compile
