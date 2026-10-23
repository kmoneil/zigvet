// An address held by an element or a field of a local made with an
// initializer, read out and returned (#59). `picked` is an app's fuzz
// helper, which made input-method events whose clauses outlived it.
const std = @import("std");

const Clause = struct { start: usize, end: usize, target: bool };
const Compose = struct { text: []const u8, clauses: []const Clause };

fn picked(piece: []const u8, some: bool) Compose {
    const whole = [_][]const Clause{
        &.{},
        &.{.{ .start = 0, .end = piece.len, .target = true }},
    };
    return .{ .text = piece, .clauses = whole[@intFromBool(some)] };
}

fn field(n: usize) []const Clause {
    const s = .{ .all = &[_]Clause{.{ .start = 0, .end = n, .target = false }} };
    return s.all;
}

// Not reported: the element the index names is static, and an element
// that holds what the caller passed in.
fn none(piece: []const u8) []const Clause {
    const whole = [_][]const Clause{
        &.{},
        &.{.{ .start = 0, .end = piece.len, .target = true }},
    };
    return whole[0];
}
fn given(kept: []const Clause, n: usize) []const Clause {
    const whole = [_][]const Clause{ kept, kept[0..n] };
    return whole[1];
}

comptime {
    _ = &picked;
    _ = &field;
    _ = &none;
    _ = &given;
}

// error
//
// :12:9: error: anonymous array made here leaves picked through return
// :18:25: error: array literal made here leaves field through return
