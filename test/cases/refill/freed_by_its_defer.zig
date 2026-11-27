// A local freed, then given new memory by something that can fail first,
// that a defer of its own function frees again on the way out: when the
// `try` fails, the defer frees what was freed a line before (#252).
// `resample` is a reservoir sampler's shape, whose list frees its elements
// in a defer.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Sampled = struct { id: u64, line: []u8 };

fn rename(gpa: Allocator, text: []const u8) !void {
    var name: []u8 = try gpa.dupe(u8, "x");
    defer gpa.free(name);
    gpa.free(name);
    name = try gpa.dupe(u8, text);
}

fn resample(gpa: Allocator, text: []const u8) !void {
    var sample: std.ArrayList(Sampled) = .empty;
    defer {
        for (sample.items) |s| gpa.free(s.line);
        sample.deinit(gpa);
    }
    const first = try gpa.dupe(u8, "x");
    errdefer gpa.free(first);
    try sample.append(gpa, .{ .id = 0, .line = first });
    gpa.free(sample.items[0].line);
    sample.items[0] = .{ .id = 1, .line = try gpa.dupe(u8, text) };
}

fn retitle(gpa: Allocator, text: []const u8) ![]u8 {
    var title: []u8 = try gpa.dupe(u8, "x");
    errdefer gpa.free(title);
    gpa.free(title);
    title = try gpa.dupe(u8, text);
    return title;
}

// Not reported: nothing reads the local after the failure, and a defer
// that frees only the list, not what its elements hold.
fn noDefer(gpa: Allocator, text: []const u8) !void {
    var name: []u8 = try gpa.dupe(u8, "x");
    gpa.free(name);
    name = try gpa.dupe(u8, text);
    gpa.free(name);
}

fn listOnly(gpa: Allocator, text: []const u8) !void {
    var sample: std.ArrayList(Sampled) = .empty;
    defer sample.deinit(gpa);
    try sample.ensureTotalCapacity(gpa, 1);
    sample.appendAssumeCapacity(.{ .id = 0, .line = try gpa.dupe(u8, "x") });
    gpa.free(sample.items[0].line);
    sample.items[0] = .{ .id = 1, .line = try gpa.dupe(u8, text) };
    gpa.free(sample.items[0].line);
}

comptime {
    _ = &rename;
    _ = &resample;
    _ = &retitle;
    _ = &noDefer;
    _ = &listOnly;
}

// error
//
// :14:5: error: `name` freed here still holds the freed memory if gpa.dupe fails before it is refilled
// :27:5: error: `sample.items[0].line` freed here still holds the freed memory if gpa.dupe fails before it is refilled
// :34:5: error: `title` freed here still holds the freed memory if gpa.dupe fails before it is refilled
