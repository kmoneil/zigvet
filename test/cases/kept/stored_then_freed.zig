// An errdefer frees what the function has already stored where its caller
// keeps it, then something fails (#63): the store's owner frees it again.
// `put` is the shape a Pub/Sub client's fake met twice, `restart` a
// terminal's in a public editor.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Store = struct {
    gpa: Allocator,
    names: std.ArrayList([]u8) = .empty,
    sizes: std.ArrayList(usize) = .empty,
    last: ?[]u8 = null,

    fn put(self: *Store, name: []const u8) !void {
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.names.append(self.gpa, owned);
        try self.sizes.append(self.gpa, name.len);
    }

    fn remember(self: *Store, name: []const u8) !void {
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        self.last = owned;
        if (owned.len == 0) return error.Empty;
    }

    // Not reported: the store made the last step that can fail, and a
    // store an errdefer takes back out.
    fn putLast(self: *Store, name: []const u8) !void {
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.names.ensureUnusedCapacity(self.gpa, 1);
        try self.sizes.append(self.gpa, name.len);
        self.names.appendAssumeCapacity(owned);
    }

    fn putUndone(self: *Store, name: []const u8) !void {
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.names.append(self.gpa, owned);
        errdefer _ = self.names.pop();
        try self.sizes.append(self.gpa, name.len);
    }
};

comptime {
    _ = &Store.put;
    _ = &Store.remember;
    _ = &Store.putLast;
    _ = &Store.putUndone;
}

// error
//
// :16:9: error: `owned` freed here if self.sizes.append fails, but self.names already holds it
// :23:9: error: `owned` freed here if it returns error.Empty, but self.last already holds it
