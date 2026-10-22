// A place freed, then given new memory by something that can fail first.
// When it fails, the place still holds what was freed, and whoever frees it
// next frees it twice (#39). `resample` is a Kafka client's shape, `rename`
// a chart library's and `reset` std.compress.lzma's in Zig 0.17.0.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Rows = struct {
    gpa: Allocator,
    items: []u32 = &.{},
    name: ?[]u8 = null,

    fn resize(self: *Rows, n: usize) !void {
        self.gpa.free(self.items);
        self.items = try self.gpa.alloc(u32, n);
    }

    fn rename(self: *Rows, name: []const u8) !void {
        if (self.name) |old| self.gpa.free(old);
        self.name = try self.gpa.dupe(u8, name);
    }
};

const History = struct { partitions: u32, ends: []i64 };

fn resample(gpa: Allocator, history: *History, partitions: u32) !void {
    gpa.free(history.ends);
    history.* = .{ .partitions = partitions, .ends = try gpa.alloc(i64, partitions) };
}

const Decode = struct {
    probs: std.ArrayList(u16),

    fn reset(self: *Decode, gpa: Allocator, n: usize) !void {
        self.probs.deinit(gpa);
        self.probs = try .initCapacity(gpa, n);
    }
};

// Not reported: the new value made first, the place reset first, and a
// struct held by value, which the failing function throws away.
fn resizeSafely(self: *Rows, n: usize) !void {
    const items = try self.gpa.alloc(u32, n);
    self.gpa.free(self.items);
    self.items = items;
}
fn resizeReset(self: *Rows, n: usize) !void {
    self.gpa.free(self.items);
    self.items = &.{};
    self.items = try self.gpa.alloc(u32, n);
}
fn build(gpa: Allocator, n: usize) !Rows {
    var rows: Rows = .{ .gpa = gpa, .items = try gpa.alloc(u32, 1) };
    gpa.free(rows.items);
    rows.items = try gpa.alloc(u32, n);
    return rows;
}

comptime {
    _ = &Rows.resize;
    _ = &Rows.rename;
    _ = &resample;
    _ = &Decode.reset;
    _ = &resizeSafely;
    _ = &resizeReset;
    _ = &build;
}

// error
//
// :14:9: error: `self.items` freed here still holds the freed memory if self.gpa.alloc fails before it is refilled
// :19:30: error: `self.name` freed here still holds the freed memory if self.gpa.dupe fails before it is refilled
// :27:5: error: `history.ends` freed here still holds the freed memory if gpa.alloc fails before it is refilled
// :35:9: error: `self.probs` freed here still holds the freed memory if .initCapacity fails before it is refilled
