// A union is given its tag, and an optional is marked not null, before any
// element of its initializer is evaluated, so even the first element reads
// what was stored (#152).
const std = @import("std");

const Expr = union(enum) { lit: f64, pair: *Pair };
const Pair = struct { left: Expr, right: Expr };
const Held = struct { e: Expr, n: u32 };

fn alloc(arena: std.mem.Allocator, value: Pair) !*Pair {
    const out = try arena.create(Pair);
    out.* = value;
    return out;
}

// The left-associative loop of a recursive-descent parser: the new node's
// left side is `left` with the tag `.pair` and its payload unwritten.
fn combine(arena: std.mem.Allocator, right: Expr) !Expr {
    var left: Expr = .{ .lit = 1 };
    left = .{ .pair = try alloc(arena, .{ .left = left, .right = right }) };
    return left;
}
fn tagRead(e: *Expr) void {
    e.* = .{ .lit = switch (e.*) {
        .lit => |v| v,
        .pair => 0,
    } };
}
fn otherField(e: *Expr) void {
    e.* = .{ .lit = e.pair.left.lit };
}
fn inStruct(arena: std.mem.Allocator, h: *Held) !void {
    h.* = .{ .e = .{ .pair = try alloc(arena, .{ .left = h.e, .right = h.e }) }, .n = 1 };
}
fn optional(span: *?[2]u32, t: u32) void {
    span.* = .{ if (span.*) |s| s[0] else t, t };
}

comptime {
    _ = &combine;
    _ = &tagRead;
    _ = &otherField;
    _ = &inStruct;
    _ = &optional;
}

// error
//
// :20:51: error: left read here, but the initializer is written straight into left and has already stored left's tag, .pair
// :24:29: error: e.* read here, but the initializer is written straight into e.* and has already stored e.*'s tag, .lit
// :30:21: error: e.pair.left.lit read here, but the initializer is written straight into e.* and has already stored e.*'s tag, .lit
// :33:58: error: h.e read here, but the initializer is written straight into h.* and has already stored h.e's tag, .pair
// :33:72: error: h.e read here, but the initializer is written straight into h.* and has already stored h.e's tag, .pair
// :36:21: error: span.* read here, but the initializer is written straight into span.* and has already stored span.* as not null
