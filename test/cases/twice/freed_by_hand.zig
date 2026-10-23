// An errdefer's free written out by hand on a path that then fails (#61):
// the errdefer runs too, and frees it again. `open` is a Kafka client's
// librdkafka binding as an agent wrote it; `rebuild` a compiler's docs
// model, freeing by hand before a step that can fail.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Conn = struct { fd: i32 };

fn open(gpa: Allocator, fd: i32) !*Conn {
    const conn = try gpa.create(Conn);
    errdefer gpa.destroy(conn);
    if (fd < 0) {
        gpa.destroy(conn);
        return error.BadConfig;
    }
    conn.* = .{ .fd = fd };
    return conn;
}

fn rebuild(gpa: Allocator, parts: []const []const u8) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(gpa);
    for (parts) |part| try joined.appendSlice(gpa, part);
    joined.deinit(gpa);
    return try gpa.dupe(u8, "rebuilt");
}

// Not reported: the hand-written free followed by a plain return, which
// the errdefer does not run on.
fn openOrNull(gpa: Allocator, fd: i32) !?*Conn {
    const conn = try gpa.create(Conn);
    errdefer gpa.destroy(conn);
    if (fd < 0) {
        gpa.destroy(conn);
        return null;
    }
    conn.* = .{ .fd = fd };
    return conn;
}

comptime {
    _ = &open;
    _ = &rebuild;
    _ = &openOrNull;
}

// error
//
// :14:9: error: `gpa.destroy(conn)` here, and the errdefer above it does the same again if it returns error.BadConfig
// :25:5: error: `joined.deinit(gpa)` here, and the errdefer above it does the same again if gpa.dupe fails
