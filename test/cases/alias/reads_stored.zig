// An anonymous initializer is written straight into the place it is
// assigned to, an element at a time in the order written (#16).
const P = struct { x: i32, y: i32 };
const D = struct { rate: [2]u32 };
const N = struct { a: P, b: i32 };
const Q = struct { z: i32, x: i32, y: i32 };
const History = struct { prev: u32, prev2: u32 };
const Meter = struct { history: History };

fn shift(d: *D, new: u32) void {
    d.rate = .{ new, d.rate[0] };
}
fn swap(p: *P) void {
    p.* = .{ .x = p.y, .y = p.x };
}
fn rotate(a: *[3]u8) void {
    a.* = .{ a[2], a[0], a[1] };
}
fn writtenOrder(u: *P) void {
    u.* = .{ .y = u.x, .x = u.y };
}
fn shiftNamed(m: *Meter, current: u32) void {
    m.history = .{ .prev = current, .prev2 = m.history.prev };
}
fn nested(n: *N) void {
    n.* = .{ .a = .{ .x = n.a.y, .y = n.a.x }, .b = n.b };
}
fn swapBesideSame(q: *Q) void {
    q.* = .{ .z = q.z, .x = q.y, .y = q.x };
}
fn ordered(r: [2]f32) [2]f32 {
    var ext = r;
    if (ext[1] < ext[0]) ext = .{ ext[1], ext[0] };
    return ext;
}

comptime {
    _ = &shift;
    _ = &swap;
    _ = &rotate;
    _ = &writtenOrder;
    _ = &shiftNamed;
    _ = &nested;
    _ = &swapBesideSame;
    _ = &ordered;
}

// error
//
// :11:22: error: d.rate[0] read here, but the initializer is written straight into d.rate and has already stored d.rate[0]
// :14:29: error: p.x read here, but the initializer is written straight into p.* and has already stored p.x
// :17:20: error: a[0] read here, but the initializer is written straight into a.* and has already stored a[0]
// :17:26: error: a[1] read here, but the initializer is written straight into a.* and has already stored a[1]
// :20:29: error: u.y read here, but the initializer is written straight into u.* and has already stored u.y
// :23:46: error: m.history.prev read here, but the initializer is written straight into m.history and has already stored m.history.prev
// :26:39: error: n.a.x read here, but the initializer is written straight into n.* and has already stored n.a.x
// :29:39: error: q.x read here, but the initializer is written straight into q.* and has already stored q.x
// :33:43: error: ext[0] read here, but the initializer is written straight into ext and has already stored ext[0]
