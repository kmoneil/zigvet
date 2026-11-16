// A method whose doc says the slice it returns stays valid until `deinit`,
// and another method that grows the list it is a slice of (#189): the
// first append that reallocates frees what every earlier call returned.
// Each method is right alone; the pair is the bug. A test that interns a
// few strings passes; 64 longer ones read freed memory.
const std = @import("std");

const Table = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,

    const Span = struct { start: usize, len: usize };

    pub fn intern(t: *Table, s: []const u8) !usize {
        const start = t.bytes.items.len;
        try t.bytes.appendSlice(t.gpa, s);
        try t.spans.append(t.gpa, .{ .start = start, .len = s.len });
        return t.spans.items.len - 1;
    }

    /// The string `id` names, empty for 0. Valid until `deinit`.
    pub fn get(t: *const Table, id: usize) []const u8 {
        return switch (id) {
            0 => "",
            else => |i| t.spanOf(t.spans.items[i - 1]),
        };
    }

    fn spanOf(t: *const Table, s: Span) []const u8 {
        return t.bytes.items[s.start..][0..s.len];
    }

    // Not reported: the doc says what ends it.
    /// The bytes of every string. Valid until the next `intern`.
    pub fn all(t: *const Table) []const u8 {
        return t.bytes.items;
    }
};

// Not reported: only the type itself grows the list, in a phase it runs
// once, and the promise may rest on that phase being over.
const Checker = struct {
    found: std.ArrayList(u32) = .empty,

    pub fn check(c: *Checker, gpa: std.mem.Allocator) !void {
        try c.record(gpa, 1);
    }

    fn record(c: *Checker, gpa: std.mem.Allocator, x: u32) !void {
        try c.found.append(gpa, x);
    }

    /// What checking found, valid until `deinit`.
    pub fn results(c: *const Checker) []const u32 {
        return c.found.items;
    }
};

comptime {
    _ = &Table.intern;
    _ = &Table.get;
    _ = &Table.all;
    _ = &Checker.check;
    _ = &Checker.results;
}

// error
//
// :26:25: error: 'get' returns a slice of `t.bytes.items` and its doc says it stays valid, but `t.bytes.appendSlice` in 'intern' can move them, and what it returned then points at freed memory
