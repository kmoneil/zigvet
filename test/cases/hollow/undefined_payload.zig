// An optional of a slice keeps its null in the slice's pointer, so a
// payload of `undefined` leaves it neither null nor set, and the `.?` after
// it branches on undefined (#232): Debug's 0xaa fill reads as set, while
// ReleaseSafe drops the store and reads null, and the copy is lost.
const std = @import("std");

fn copySlice(a: std.mem.Allocator, src: *const []const u8, dst: *[]const u8) !void {
    const out = try a.alloc(u8, src.len);
    @memcpy(out, src.*);
    dst.* = out;
}

fn copyOptional(a: std.mem.Allocator, src: *const ?[]const u8, dst: *?[]const u8) !void {
    if (src.*) |*payload| {
        dst.* = @as([]const u8, undefined);
        try copySlice(a, payload, &dst.*.?);
    } else {
        dst.* = null;
    }
}

// Not reported: a defined value first, then the payload written through it.
fn copyOptionalFixed(a: std.mem.Allocator, src: *const ?[]const u8, dst: *?[]const u8) !void {
    if (src.*) |*payload| {
        dst.* = payload.*;
        try copySlice(a, payload, &dst.*.?);
    } else {
        dst.* = null;
    }
}

// Not reported: an integer's optional keeps a flag of its own.
fn setCount(dst: *?u32, n: u32) void {
    dst.* = @as(u32, undefined);
    dst.*.? = n;
}

// A generic copy: for an optional of a pointer, the same bug.
fn copyInto(comptime T: type, src: *const T, dst: *T) void {
    switch (@typeInfo(T)) {
        .optional => |o| if (src.*) |*payload| {
            dst.* = @as(o.child, undefined);
            copyInto(o.child, payload, &dst.*.?);
        } else {
            dst.* = null;
        },
        else => dst.* = src.*,
    }
}

// Not reported: the generic copy reads a pointer aside.
fn copyIntoFixed(comptime T: type, src: *const T, dst: *T) void {
    switch (@typeInfo(T)) {
        .optional => |o| if (src.*) |*payload| {
            if (comptime @typeInfo(o.child) == .pointer) {
                var v: o.child = undefined;
                copyIntoFixed(o.child, payload, &v);
                dst.* = v;
                return;
            }
            dst.* = @as(o.child, undefined);
            copyIntoFixed(o.child, payload, &dst.*.?);
        } else {
            dst.* = null;
        },
        else => dst.* = src.*,
    }
}

fn copyName(src: *const ?[]const u8, dst: *?[]const u8) void {
    copyInto(?[]const u8, src, dst);
}

fn copyCount(src: *const ??u32, dst: *??u32) void {
    copyIntoFixed(??u32, src, dst);
}

comptime {
    _ = &copyOptional;
    _ = &copyOptionalFixed;
    _ = &setCount;
    _ = &copyName;
    _ = &copyCount;
}

// error
//
// :15:9: error: `dst.*` is given `@as([]const u8, undefined)`, then unwrapped by `dst.*.?`: an optional of a pointer, a slice or an error set keeps its null in the payload's own bits, which this leaves undefined: Debug's 0xaa fill reads as set, and a release build may drop the store and read as null what the bytes held before
// :42:13: error: `dst.*` is given `@as(o.child, undefined)`, then unwrapped by `dst.*.?`: when `o.child` is a pointer, a slice or an error set, its optional keeps its null in the payload's own bits, which this leaves undefined: Debug's 0xaa fill reads as set, and a release build may drop the store and read as null what the bytes held before
