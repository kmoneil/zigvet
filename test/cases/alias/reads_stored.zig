// An anonymous initializer is written straight into the place it is
// assigned to, an element at a time in the order written (#16).
const P = struct { x: i32, y: i32 };
const D = struct { rate: [2]u32 };
const N = struct { a: P, b: i32 };

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
fn copyOf(p: P) P {
    return p;
}
fn whole(s: *P) void {
    s.* = .{ .x = 5, .y = copyOf(s.*).x };
}
fn nested(n: *N) void {
    n.* = .{ .a = .{ .x = n.a.y, .y = n.a.x }, .b = n.b };
}
fn typedInner(m: *N) void {
    m.* = .{ .b = 7, .a = P{ .x = m.b, .y = 0 } };
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
    _ = &whole;
    _ = &nested;
    _ = &typedInner;
    _ = &ordered;
}

// error
//
// :8:22: error: d.rate[0] read here, but the initializer is written straight into d.rate and has already stored d.rate[0]
// :11:29: error: p.x read here, but the initializer is written straight into p.* and has already stored p.x
// :14:20: error: a[0] read here, but the initializer is written straight into a.* and has already stored a[0]
// :14:26: error: a[1] read here, but the initializer is written straight into a.* and has already stored a[1]
// :17:29: error: u.y read here, but the initializer is written straight into u.* and has already stored u.y
// :23:34: error: s.* read here, but the initializer is written straight into s.* and has already stored s.x
// :26:39: error: n.a.x read here, but the initializer is written straight into n.* and has already stored n.a.x
// :29:35: error: m.b read here, but the initializer is written straight into m.* and has already stored m.b
// :33:43: error: ext[0] read here, but the initializer is written straight into ext and has already stored ext[0]
