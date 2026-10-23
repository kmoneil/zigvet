// A function that frees what it is handed itself when it fails, by hand
// rather than in an errdefer: when the append fails, `push` releases its
// copy of the frame, components and all, and returns the error, and
// `begin`'s errdefer frees the components a second time. It is a
// compiler's equality and hash lowering, which pushes its frames this way.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Frame = struct {
    components: []u32,
    remaining: usize,
};

fn release(gpa: Allocator, frame: *Frame) void {
    gpa.free(frame.components);
}

fn push(gpa: Allocator, frames: *std.ArrayList(Frame), frame: Frame) !void {
    var pushed = frame;
    frames.append(gpa, pushed) catch |err| {
        release(gpa, &pushed);
        return err;
    };
}

fn begin(gpa: Allocator, frames: *std.ArrayList(Frame), n: usize) !void {
    const components = try gpa.alloc(u32, n);
    errdefer gpa.free(components);
    if (n > 64) return error.TooMany;
    return try push(gpa, frames, .{ .components = components, .remaining = n });
}

// Not reported: the errdefer's scope ends before the frame is handed to
// `push`, which frees it on its own failure.
fn beginHanded(gpa: Allocator, frames: *std.ArrayList(Frame), n: usize) !void {
    const components = made: {
        const owned = try gpa.alloc(u32, n);
        errdefer gpa.free(owned);
        if (n > 64) return error.TooMany;
        break :made owned;
    };
    return try push(gpa, frames, .{ .components = components, .remaining = n });
}

comptime {
    _ = &begin;
    _ = &beginHanded;
}

// error
//
// :30:16: error: push frees 'components' itself when it fails, and an errdefer here frees it again
