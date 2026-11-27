// An allocation made in the arguments of a call that can fail (#236). The
// copy is made before `append` runs, and when `append` fails nothing has a
// name for it: std.testing.checkAllAllocationFailures on `keep` reports
// `allocated bytes: 5, freed bytes: 0`. With a thread for the copy, the
// thread is left neither joined nor detached.
const std = @import("std");

pub fn keep(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), s: []const u8) !void {
    try list.append(gpa, try gpa.dupe(u8, s));
}

fn work(n: *std.atomic.Value(usize)) void {
    _ = n.fetchAdd(1, .monotonic);
}

pub fn start(gpa: std.mem.Allocator, threads: *std.ArrayList(std.Thread), n: *std.atomic.Value(usize)) !void {
    try threads.append(gpa, try std.Thread.spawn(.{}, work, .{n}));
}

// Not reported: the copy bound first, its release armed; room made first,
// so the call cannot fail; and an arena, which frees the copy with the
// rest.
pub fn keepBound(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), s: []const u8) !void {
    const copy = try gpa.dupe(u8, s);
    errdefer gpa.free(copy);
    try list.append(gpa, copy);
}
pub fn keepRoom(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), s: []const u8) !void {
    try list.ensureUnusedCapacity(gpa, 1);
    list.appendAssumeCapacity(try gpa.dupe(u8, s));
}
pub fn keepArena(arena: std.mem.Allocator, list: *std.ArrayList([]u8), s: []const u8) !void {
    try list.append(arena, try arena.dupe(u8, s));
}

comptime {
    _ = &keep;
    _ = &start;
    _ = &keepBound;
    _ = &keepRoom;
    _ = &keepArena;
}

// error
//
// :9:26: error: what gpa.dupe makes here has no name, so if list.append fails after it, nothing releases it
// :17:29: error: what std.Thread.spawn makes here has no name, so if threads.append fails after it, nothing releases it
