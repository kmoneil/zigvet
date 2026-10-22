const std = @import("std");
const mem = std.mem;

// A call that returns a view of an argument carries the argument's stack
// address out with it (#6).
fn label(id: u32) []const u8 {
    var buf: [32]u8 = undefined;
    return std.fmt.bufPrint(&buf, "item {d}", .{id}) catch unreachable;
}
fn cName(name: []const u8) []const u8 {
    var buf: [64:0]u8 = @splat(0);
    @memcpy(buf[0..name.len], name);
    return std.mem.sliceTo(&buf, 0);
}
fn bytesOf(x: u64) []const u8 {
    var v = x;
    v +%= 1;
    return std.mem.asBytes(&v);
}
fn trimmed(n: u8) []const u8 {
    var buf: [4]u8 = .{ ' ', n, n, ' ' };
    buf[0] = ' ';
    return mem.trim(u8, buf[0..], " ");
}
fn words(n: u8) []align(1) const u16 {
    var raw: [8]u8 = @splat(n);
    raw[0] = 0;
    return mem.bytesAsSlice(u16, &raw);
}
fn printed(id: u32) []const u8 {
    var buf: [32]u8 = undefined;
    return mem.print(&buf, "item {d}", .{id}) catch unreachable;
}

// Not reported: the argument is the caller's memory, or the result is only
// read here.
fn ofParameter(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " ");
}
fn intoCallers(out: []u8, id: u32) []const u8 {
    return std.fmt.bufPrint(out, "{d}", .{id}) catch unreachable;
}
fn readHere(n: u8) bool {
    var buf: [4]u8 = .{ ' ', n, n, ' ' };
    buf[3] = ' ';
    return std.mem.trim(u8, &buf, " ").len > 0;
}

comptime {
    _ = &label;
    _ = &cName;
    _ = &bytesOf;
    _ = &trimmed;
    _ = &words;
    _ = &printed;
    _ = &ofParameter;
    _ = &intoCallers;
    _ = &readHere;
}

// error
//
// :8:29: error: address of local 'buf' made here leaves label through return
// :13:28: error: address of local 'buf' made here leaves cName through return
// :18:28: error: address of local 'v' made here leaves bytesOf through return
// :23:25: error: slice of local 'buf' made here leaves trimmed through return
// :28:34: error: address of local 'raw' made here leaves words through return
// :32:22: error: address of local 'buf' made here leaves printed through return
