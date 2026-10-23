// A pointer into a list's items kept across a call that can move them
// (#55): `append` reallocates when the list is full, and `first` is left
// pointing at freed memory. A test of it with 100 appends passes; with
// 10,000 it reads 1 where it wrote 7.
const std = @import("std");

fn setFirst(gpa: std.mem.Allocator, list: *std.ArrayList(u32), n: usize) !void {
    const first = &list.items[0];
    for (0..n) |i| try list.append(gpa, @intCast(i));
    first.* = 7;
}

// A `for` over the items takes the slice once, so growing the list in its
// body leaves it walking the old memory.
fn doubled(gpa: std.mem.Allocator, list: *std.ArrayList(u32)) !void {
    for (list.items) |x| {
        if (x % 2 == 0) try list.append(gpa, x * 2);
    }
}

fn counted(gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u32, u32), a: u32, b: u32) !void {
    const count = try map.getOrPut(gpa, a);
    if (!count.found_existing) count.value_ptr.* = 0;
    try map.put(gpa, b, 0);
    count.value_ptr.* += 1;
}

// Not reported: room reserved first, so the append cannot move anything,
// and an index taken again after the growth.
fn setFirstReserved(gpa: std.mem.Allocator, list: *std.ArrayList(u32), n: usize) !void {
    try list.ensureUnusedCapacity(gpa, n);
    const first = &list.items[0];
    for (0..n) |i| list.appendAssumeCapacity(@intCast(i));
    first.* = 7;
}
fn setFirstAfter(gpa: std.mem.Allocator, list: *std.ArrayList(u32), n: usize) !void {
    for (0..n) |i| try list.append(gpa, @intCast(i));
    const first = &list.items[0];
    first.* = 7;
}

comptime {
    _ = &setFirst;
    _ = &doubled;
    _ = &counted;
    _ = &setFirstReserved;
    _ = &setFirstAfter;
}

// error
//
// :9:24: error: `list.append` can move `list.items`, and 'first', taken before it, still points at the old memory where it is used after
// :17:29: error: `list.append` can move `list.items`, and the `for` around it walks on through the old memory on its next turn
// :24:9: error: `map.put` can move `map`'s entries, and 'count', taken before it, still points at the old memory where it is used after
