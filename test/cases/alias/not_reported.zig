// Reads that do not see what the initializer already stored, or that read
// back what it stored on purpose.
const std = @import("std");
const P = struct { x: i32, y: i32 };
const D = struct { rate: [2]u32 };
const N = struct { a: P, b: i32 };
const Node = struct { value: u32, self: *Node, next: *u32 };
const Token = struct { loc: struct { start: usize, end: usize } };
const Replica = struct { inner: P, view: i32, options: u32 };
const Buffer = struct { arena: std.heap.ArenaAllocator, allocator: std.mem.Allocator };

fn ownSlot(lo: *P, q: P) void {
    lo.* = .{ .x = @min(lo.x, q.x), .y = @min(lo.y, q.y) };
}
fn eachOwn(at: *[2]i32, s: [2]i32) void {
    at.* = .{ at[0] + s[0], at[1] + s[1] };
}
fn typed(q: *P) void {
    q.* = P{ .x = q.y, .y = q.x };
}
fn typedArray(b: *[3]u8) void {
    b.* = [_]u8{ b[2], b[0], b[1] };
}
fn typedOuter(t: *D) void {
    t.* = D{ .rate = .{ 7, t.rate[0] } };
}
fn unknownIndex(w: *[2]u8, i: usize) void {
    w.* = .{ 5, w[i] };
}
fn compileTime(p: *P) void {
    p.* = .{ .x = 1, .y = @sizeOf(@TypeOf(p.*)) };
}
fn pointerAndAddress(n: *Node) void {
    n.* = .{ .value = 1, .self = n, .next = &n.value };
}
fn otherPlace(p: *P, q: *const P) void {
    p.* = .{ .x = q.y, .y = q.x };
}
fn returned(p: *P, fail: bool) i32 {
    p.* = .{ .x = 1, .y = if (fail) return p.x else 2 };
    return 0;
}

// A slot stored with what it holds already reads the same afterwards
// (ZLS's token locations, TigerBeetle's replica init).
fn sameValue(t: *Token) void {
    t.loc = .{ .start = t.loc.start, .end = t.loc.start + 1 };
}
fn keepField(r: *Replica, options: u32) void {
    r.* = .{ .inner = r.inner, .view = r.inner.x, .options = options };
}

// A whole struct given its fields by name, none read from what it held,
// is being made afresh, and reading back a field it has just set is how
// that is written on purpose (flow, Ghostty, TigerBeetle). These read the
// new value too.
fn chain(b: *Buffer, gpa: std.mem.Allocator) void {
    b.* = .{ .arena = .init(gpa), .allocator = b.arena.allocator() };
}
fn copyOf(p: P) P {
    return p;
}
fn fresh(s: *P) void {
    s.* = .{ .x = 5, .y = copyOf(s.*).x };
}
fn freshTyped(m: *N) void {
    m.* = .{ .b = 7, .a = P{ .x = m.b, .y = 0 } };
}

comptime {
    _ = &ownSlot;
    _ = &eachOwn;
    _ = &typed;
    _ = &typedArray;
    _ = &typedOuter;
    _ = &unknownIndex;
    _ = &compileTime;
    _ = &pointerAndAddress;
    _ = &otherPlace;
    _ = &returned;
    _ = &sameValue;
    _ = &keepField;
    _ = &chain;
    _ = &fresh;
    _ = &freshTyped;
}

// compile
