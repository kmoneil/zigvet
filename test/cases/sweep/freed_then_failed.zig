// A loop frees what a list holds, can fail part way, and empties the list
// only after it (#65): a failure on a later turn leaves the list holding
// what earlier turns freed. `flush` is an editor's delayed message queue.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Queue = struct {
    gpa: Allocator,
    held: std.ArrayList([]u8) = .empty,
    sent: usize = 0,

    fn send(q: *Queue, m: []const u8) !void {
        if (m.len == 0) return error.Empty;
        q.sent += 1;
    }

    fn flush(q: *Queue) !void {
        for (q.held.items) |m| {
            try q.send(m);
            q.gpa.free(m);
        }
        q.held.clearRetainingCapacity();
    }

    // Not reported: each taken out of the list as it is freed.
    fn drain(q: *Queue) !void {
        while (q.held.pop()) |m| {
            defer q.gpa.free(m);
            try q.send(m);
        }
    }
};

comptime {
    _ = &Queue.flush;
    _ = &Queue.drain;
}

// error
//
// :20:13: error: freed here, but if q.send fails on a later turn, q.held still holds what earlier turns freed, since only `q.held.clearRetainingCapacity()` after the loop empties it
