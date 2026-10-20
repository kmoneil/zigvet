// Reads that do not see what the initializer already stored.
const P = struct { x: i32, y: i32 };
const D = struct { rate: [2]u32 };
const Node = struct { value: u32, self: *Node, next: *u32 };

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
}

// compile
