// `{d}` prints a float in full decimal, never in scientific notation, so an
// f64 can need 327 bytes. Into a smaller buffer, a large or tiny value makes
// bufPrint fail, and `catch unreachable` says it cannot (#35). The first
// two are the shapes a zig-charts audit fixed.
const std = @import("std");

const Cell = union(enum) { number: f64, text: []const u8 };

fn printNumber(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: f64) !void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try out.appendSlice(gpa, s);
}

fn cellWidth(cell: Cell) usize {
    switch (cell) {
        .number => |v| {
            var buf: [32]u8 = undefined;
            const printed = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            return printed.len;
        },
        .text => |t| return t.len,
    }
}

fn percent(p: f64) usize {
    var buf: [std.fmt.float.min_buffer_size]u8 = undefined;
    return (std.fmt.bufPrint(&buf, "{d:.2}%", .{p}) catch unreachable).len;
}

// Not reported: bounded first, printed with {e}, the error handled, an
// integer, or a buffer large enough.
fn bounded(x: f64) usize {
    var buf: [64]u8 = undefined;
    const size = @abs(x);
    const text = if (size != 0 and (size >= 1e21 or size < 1e-6))
        std.fmt.bufPrint(&buf, "{e}", .{x}) catch unreachable
    else
        std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
    return text.len;
}
fn scientific(v: f64) usize {
    var buf: [24]u8 = undefined;
    return (std.fmt.bufPrint(&buf, "{e}", .{v}) catch unreachable).len;
}
fn handled(v: f64) usize {
    var buf: [48]u8 = undefined;
    const s: []const u8 = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?";
    return s.len;
}
fn count(n: u64) usize {
    var buf: [20]u8 = undefined;
    return (std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable).len;
}
fn roomy(v: f64) usize {
    var buf: [327]u8 = undefined;
    return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len;
}

comptime {
    _ = &printNumber;
    _ = &cellWidth;
    _ = &percent;
    _ = &bounded;
    _ = &scientific;
    _ = &handled;
    _ = &count;
    _ = &roomy;
}

// error
//
// :11:47: error: `{d}` of f64 'v' can need 327 bytes, but &buf holds 48, and `catch unreachable` says std.fmt.bufPrint cannot fail
// :19:61: error: `{d}` of f64 'v' can need 327 bytes, but &buf holds 32, and `catch unreachable` says std.fmt.bufPrint cannot fail
// :28:49: error: `{d:.2}` of f64 'p' can need 313 bytes, but &buf holds 53, and `catch unreachable` says std.fmt.bufPrint cannot fail
