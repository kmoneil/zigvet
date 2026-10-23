// A failure before a call that might reset the place (#60), a failure
// written `orelse return error.X`, and a free through the file's own
// function (#64): each leaves the place holding what was freed. `restart`
// is a terminal's restart in a public editor, and `localFor` a UI
// framework's component state, freed through `destroyLocal` and refilled
// past a `rawAlloc` that can come back empty.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Local = struct { bytes: []u8 };

const Rows = struct {
    gpa: Allocator,
    items: []u32 = &.{},
    wide: usize = 0,
    one: Local = .{ .bytes = &.{} },
    locals: std.AutoHashMapUnmanaged(u64, Local) = .empty,

    fn width(self: *const Rows) usize {
        return self.wide;
    }

    fn destroyLocal(self: *Rows, local: Local) void {
        self.gpa.free(local.bytes);
    }

    fn restart(self: *Rows, n: usize) !void {
        self.gpa.free(self.items);
        const spare = try self.gpa.alloc(u8, 1);
        defer self.gpa.free(spare);
        const w = self.width();
        self.items = try self.gpa.alloc(u32, n + w);
    }

    fn renew(self: *Rows) !void {
        self.gpa.free(self.one.bytes);
        const bytes = self.gpa.rawAlloc(16, .@"16", @returnAddress()) orelse return error.OutOfMemory;
        self.one = .{ .bytes = bytes[0..16] };
    }

    fn replace(self: *Rows) !void {
        self.destroyLocal(self.one);
        self.one = .{ .bytes = try self.gpa.alloc(u8, 16) };
    }

    fn localFor(self: *Rows, key: u64) !*Local {
        const entry = try self.locals.getOrPut(self.gpa, key);
        if (entry.found_existing) self.destroyLocal(entry.value_ptr.*);
        const bytes = self.gpa.rawAlloc(16, .@"16", @returnAddress()) orelse {
            if (!entry.found_existing) self.locals.removeByPtr(entry.key_ptr);
            return error.OutOfMemory;
        };
        entry.value_ptr.* = .{ .bytes = bytes[0..16] };
        return entry.value_ptr;
    }
};

// Not reported: the call that might reset the place made before anything
// can fail, an `orelse` that empties the place before it returns, and the
// place handed over by pointer, which the function can reset.
fn resizeAfterCall(self: *Rows, n: usize) !void {
    self.gpa.free(self.items);
    const w = self.width();
    self.items = try self.gpa.alloc(u32, n + w);
}
fn renewOrEmpty(self: *Rows) void {
    self.gpa.free(self.one.bytes);
    const bytes = self.gpa.rawAlloc(16, .@"16", @returnAddress()) orelse {
        self.one = .{ .bytes = &.{} };
        return;
    };
    self.one = .{ .bytes = bytes[0..16] };
}
fn destroyAt(self: *Rows, local: *Local) void {
    self.gpa.free(local.bytes);
    local.* = .{ .bytes = &.{} };
}
fn replaceThrough(self: *Rows) !void {
    destroyAt(self, &self.one);
    self.one = .{ .bytes = try self.gpa.alloc(u8, 16) };
}

comptime {
    _ = &Rows.restart;
    _ = &Rows.renew;
    _ = &Rows.replace;
    _ = &Rows.localFor;
    _ = &resizeAfterCall;
    _ = &renewOrEmpty;
    _ = &replaceThrough;
}

// error
//
// :28:9: error: `self.items` freed here still holds the freed memory if self.gpa.alloc fails before it is refilled
// :36:9: error: `self.one.bytes` freed here still holds the freed memory if self.gpa.rawAlloc fails before it is refilled
// :42:9: error: `self.one` freed here still holds the freed memory if self.gpa.alloc fails before it is refilled
// :48:35: error: `entry.value_ptr.*` freed here still holds the freed memory if self.gpa.rawAlloc fails before it is refilled
