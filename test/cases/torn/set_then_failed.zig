// An optional built in place by an initializer that can fail, which deinit
// frees (#67): the optional reads as set before its fields are made, so a
// failure leaves deinit freeing what was never allocated. `begin` is a UI
// framework's composition start, as an agent wrote it.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Pending = struct { start: usize, removed: []u8, before: []u32 };

const Editor = struct {
    gpa: Allocator,
    selections: []const u32 = &.{},
    pending: ?Pending = null,

    fn begin(self: *Editor, removed: []u8) !void {
        errdefer self.gpa.free(removed);
        self.pending = .{
            .start = 0,
            .removed = removed,
            .before = try self.gpa.dupe(u32, self.selections),
        };
    }

    // Not reported: what can fail made first.
    fn beginSafely(self: *Editor, removed: []u8) !void {
        errdefer self.gpa.free(removed);
        const before = try self.gpa.dupe(u32, self.selections);
        self.pending = .{ .start = 0, .removed = removed, .before = before };
    }

    fn deinit(self: *Editor) void {
        if (self.pending) |p| {
            self.gpa.free(p.removed);
            self.gpa.free(p.before);
        }
    }
};

comptime {
    _ = &Editor.begin;
    _ = &Editor.beginSafely;
    _ = &Editor.deinit;
}

// error
//
// :17:9: error: self.pending is built in place, so if self.gpa.dupe fails it is left set over what was never made, and deinit frees it
