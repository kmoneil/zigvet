// A receiver made by `gpa.create(W)`, with no type written, takes the type
// `create` is given, so `w.finish` is found as it is for `w: *W` (#224): a
// constructor that makes a parser and hands it to a method that deinits
// it before more steps that can fail.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Parser = struct {
    gpa: Allocator,
    buf: []u8,

    fn deinit(p: *Parser) void {
        p.gpa.free(p.buf);
        p.* = undefined;
    }
};

const W = struct {
    gpa: Allocator,

    fn make(gpa: Allocator) !*W {
        const w = try gpa.create(W);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa };
        var p: Parser = .{ .gpa = gpa, .buf = try gpa.alloc(u8, 16) };
        errdefer p.deinit();
        try w.finish(&p);
        return w;
    }

    /// Frees `p`, then does work that can fail.
    fn finish(w: *W, p: *Parser) !void {
        p.deinit();
        w.gpa.free(try w.gpa.alloc(u8, 1));
    }
};

comptime {
    _ = &W.make;
}

// error
//
// :27:13: error: w.finish frees 'p' itself when it fails, and an errdefer here frees it again
