// A FixedBufferAllocator or BufferFirstAllocator keeps the buffer it is
// given, so what it hands out over the function's own memory, returned or
// stored through a parameter, is dead stack to the caller (#196). The
// first two are the issue's; an ArenaAllocator over one gets its first
// nodes from that buffer too.
const std = @import("std");

fn greeting(name: []const u8) ![]u8 {
    var buf: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    return std.fmt.allocPrint(fba.allocator(), "hello {s}", .{name});
}

fn copyName(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf: [64]u8 = undefined;
    var first: std.heap.BufferFirstAllocator = .init(&buf, gpa);
    return first.allocator().dupe(u8, name);
}

const Holder = struct { items: []u32 };

fn fill(h: *Holder) !void {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    h.items = try fba.allocator().alloc(u32, 8);
}

fn scratch(gpa: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    var first: std.heap.BufferFirstAllocator = .init(&buf, gpa);
    var arena: std.heap.ArenaAllocator = .init(first.allocator());
    const a = arena.allocator();
    return std.mem.join(a, "/", parts);
}

// Not reported: memory used and dropped inside the function, the point of
// the pattern; the result copied out with the caller's allocator; and an
// allocator over a buffer the caller passed in.
fn width(name: []const u8) !usize {
    var buf: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const s = try std.fmt.allocPrint(fba.allocator(), "hello {s}", .{name});
    return s.len;
}

fn copiedOut(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const s = try std.fmt.allocPrint(fba.allocator(), "hello {s}", .{name});
    return gpa.dupe(u8, s);
}

fn intoCallers(buf: []u8, name: []const u8) ![]u8 {
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    return fba.allocator().dupe(u8, name);
}

comptime {
    _ = &greeting;
    _ = &copyName;
    _ = &fill;
    _ = &scratch;
    _ = &width;
    _ = &copiedOut;
    _ = &intoCallers;
}

// error
//
// :10:52: error: memory from an allocator over local 'buf' made here leaves greeting through return
// :16:54: error: memory from an allocator over local 'buf' made here leaves copyName through return
// :24:50: error: memory from an allocator over local 'buf' made here leaves fill through field
// :30:54: error: memory from an allocator over local 'buf' made here leaves scratch through return
