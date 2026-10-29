// A prepared statement finalized by hand, with a step between that can
// fail: when `bind` fails, the error leaves `insert` before the
// `finalize`, and what `prepare` allocated is never freed. It is a web
// framework's batched insert, which binds every row before it steps.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Stmt = struct {
    buf: []u8,
    gpa: Allocator,

    fn finalize(s: *Stmt) void {
        s.gpa.free(s.buf);
    }

    fn bind(s: *Stmt, v: u8) !void {
        if (v == 0) return error.Bad;
        s.buf[0] = v;
    }
};

fn prepare(gpa: Allocator) !Stmt {
    return .{ .buf = try gpa.alloc(u8, 1), .gpa = gpa };
}

fn insert(gpa: Allocator, rows: []const u8) !void {
    var stmt = try prepare(gpa);
    for (rows) |v| try stmt.bind(v);
    stmt.finalize();
}

// Not reported: finalized in a `defer`, so a failed bind finalizes it too.
fn insertDeferred(gpa: Allocator, rows: []const u8) !void {
    var stmt = try prepare(gpa);
    defer stmt.finalize();
    for (rows) |v| try stmt.bind(v);
}

comptime {
    _ = &insert;
    _ = &insertDeferred;
}

// error
//
// :28:20: error: if stmt.bind fails here, the function returns before `stmt.finalize()` below, and 'stmt' is never released
