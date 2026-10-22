// One allocation freed by two errdefers: `keep` frees `bytes` itself when
// it fails, and so does `save`'s errdefer, so a failed append frees it
// twice (#40). `save` is a Kafka client's profile store, `split` a desktop
// app's pane navigation.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Store = struct {
    gpa: Allocator,
    kept: std.ArrayList([]u8) = .empty,

    /// Takes `bytes`, even when it fails.
    fn keep(self: *Store, bytes: []u8) !void {
        errdefer self.gpa.free(bytes);
        try self.kept.append(self.gpa, bytes);
    }

    fn save(self: *Store, text: []const u8) !void {
        const bytes = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(bytes);
        try self.keep(bytes);
    }

    // Not reported: handed over with no errdefer of its own.
    fn saveOnce(self: *Store, text: []const u8) !void {
        try self.keep(try self.gpa.dupe(u8, text));
    }
};

const Pane = struct { view: []u8 };

const Nav = struct {
    panes: std.ArrayList(Pane) = .empty,

    fn addPane(nav: *Nav, gpa: Allocator, view: []u8) !void {
        errdefer gpa.free(view);
        try nav.panes.append(gpa, .{ .view = view });
    }

    fn split(nav: *Nav, gpa: Allocator, from: []const u8) !void {
        const view = try gpa.dupe(u8, from);
        errdefer gpa.free(view);
        try nav.addPane(gpa, view);
    }

    // Not reported: a callee that leaves the view to its caller.
    fn borrow(nav: *Nav, gpa: Allocator, view: []u8) !void {
        try nav.panes.append(gpa, .{ .view = view });
    }

    fn splitBorrowed(nav: *Nav, gpa: Allocator, from: []const u8) !void {
        const view = try gpa.dupe(u8, from);
        errdefer gpa.free(view);
        try nav.borrow(gpa, view);
    }
};

comptime {
    _ = &Store.save;
    _ = &Store.saveOnce;
    _ = &Nav.split;
    _ = &Nav.splitBorrowed;
}

// error
//
// :21:13: error: self.keep frees 'bytes' itself when it fails, and an errdefer here frees it again
// :43:13: error: nav.addPane frees 'view' itself when it fails, and an errdefer here frees it again
