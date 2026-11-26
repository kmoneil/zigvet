// A std hash map's capacity() counts buckets, and the map fills only 80%
// of them before an insert must grow (#226): `room` grows only once
// `count` reaches the buckets, so with 32 buckets the 26th
// putAssumeCapacity takes `available` below zero.
const std = @import("std");

const Set = struct {
    map: std.AutoHashMapUnmanaged(u32, void) = .empty,
    count: u32 = 0,

    /// Room for one more key, made here where running out can be
    /// reported, so the insert after it cannot fail.
    fn room(s: *Set, gpa: std.mem.Allocator) !void {
        if (s.map.capacity() <= s.count) try s.map.ensureTotalCapacity(gpa, 2 * s.count + 16);
        s.count += 1;
    }

    fn add(s: *Set, gpa: std.mem.Allocator, k: u32) !void {
        try s.room(gpa);
        s.map.putAssumeCapacity(k, {});
    }

    // Not reported: room asked for in items.
    fn addCounted(s: *Set, gpa: std.mem.Allocator, k: u32) !void {
        try s.map.ensureUnusedCapacity(gpa, 1);
        s.map.putAssumeCapacity(k, {});
    }

    // Not reported: an array hash map counts items.
    fn addArray(m: *std.AutoArrayHashMapUnmanaged(u32, void), gpa: std.mem.Allocator, k: u32) !void {
        if (m.capacity() <= m.count()) try m.ensureTotalCapacity(gpa, 2 * m.count() + 16);
        m.putAssumeCapacity(k, {});
    }
};

comptime {
    _ = &Set.add;
    _ = &Set.addCounted;
    _ = &Set.addArray;
}

// error
//
// :14:13: error: `s.map.capacity()` counts buckets, and a hash map fills only its max load of them, 80% by default, before an insert must grow: tested as room for items, it says there is room when there is none, and putAssumeCapacity takes the map's `available` below zero, a panic in Debug and undefined behavior in ReleaseFast
