// An initializer with two allocations (#237). When the second `dupe` fails
// the first is never freed: the errdefer below is armed only after the
// initializer, and nothing after it fails. checkAllAllocationFailures on
// `open` reports `allocated bytes: 1, freed bytes: 0`.
const std = @import("std");

pub const Pair = struct {
    gpa: std.mem.Allocator,
    a: []u8,
    b: []u8,

    pub fn close(p: *Pair) void {
        p.gpa.free(p.a);
        p.gpa.free(p.b);
    }
};

pub fn open(gpa: std.mem.Allocator) !Pair {
    var p: Pair = .{ .gpa = gpa, .a = try gpa.dupe(u8, "a"), .b = try gpa.dupe(u8, "b") };
    errdefer p.close();
    return p;
}

pub const Entry = struct { name: []u8, n: usize };

/// The initializer is an argument of a call that can fail: the name is
/// copied, then `append` runs out of memory.
pub fn add(gpa: std.mem.Allocator, list: *std.ArrayList(Entry), name: []const u8) !void {
    try list.append(gpa, .{ .name = try gpa.dupe(u8, name), .n = 1 });
}

// Not reported: each made first with its release armed, then the value
// built from the names; one allocation with nothing after it that fails;
// and an arena.
pub fn openFixed(gpa: std.mem.Allocator) !Pair {
    const a = try gpa.dupe(u8, "a");
    errdefer gpa.free(a);
    const b = try gpa.dupe(u8, "b");
    return .{ .gpa = gpa, .a = a, .b = b };
}
pub fn entry(gpa: std.mem.Allocator, name: []const u8) !Entry {
    return .{ .n = 1, .name = try gpa.dupe(u8, name) };
}
pub fn openArena(arena: std.mem.Allocator) !Pair {
    return .{ .gpa = arena, .a = try arena.dupe(u8, "a"), .b = try arena.dupe(u8, "b") };
}

comptime {
    _ = &open;
    _ = &add;
    _ = &openFixed;
    _ = &entry;
    _ = &openArena;
}

// error
//
// :19:39: error: what gpa.dupe makes here is in an initializer and has no name yet, so if gpa.dupe fails after it, nothing releases it
// :29:37: error: what gpa.dupe makes here is in an initializer and has no name yet, so if list.append fails after it, nothing releases it
