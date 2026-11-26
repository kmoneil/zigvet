// An errdefer frees a local, and is still armed after a call has handed
// it to a value whose own errdefer'd release frees it (#225): when the
// step after both fails, `url` is freed twice. The shape a script
// loader's classic and module paths both had.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Pending = struct {
    gpa: Allocator,
    url: []u8,

    /// Takes `url`: destroy frees it.
    fn make(gpa: Allocator, url: []u8) !*Pending {
        const p = try gpa.create(Pending);
        p.* = .{ .gpa = gpa, .url = url };
        return p;
    }

    fn destroy(p: *Pending) void {
        p.gpa.free(p.url);
        p.gpa.destroy(p);
    }
};

fn prepare(gpa: Allocator, href: []const u8) !*Pending {
    const url = try gpa.dupe(u8, href);
    errdefer gpa.free(url);
    const p = try Pending.make(gpa, url);
    errdefer p.destroy();
    gpa.free(try gpa.alloc(u8, 1));
    return p;
}

// Not reported: the first errdefer scoped to the hand-over.
fn prepareScoped(gpa: Allocator, href: []const u8) !*Pending {
    const url = try gpa.dupe(u8, href);
    const p = blk: {
        errdefer gpa.free(url);
        break :blk try Pending.make(gpa, url);
    };
    errdefer p.destroy();
    gpa.free(try gpa.alloc(u8, 1));
    return p;
}

comptime {
    _ = &prepare;
    _ = &prepareScoped;
}

// error
//
// :27:5: error: `url` freed here if gpa.alloc fails, and again by the errdefer's p.destroy, since Pending.make stored it in what p.destroy frees
