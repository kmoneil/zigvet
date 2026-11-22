// A test for unsigned wraparound after a plain `+`, which panics on
// overflow rather than wrapping, so the test is never true (#198). `take`
// is the issue's, from a WOFF2 decoder: on wasm32,
// `take(buf, &off, 0xFFFFFFFF)` panics with `integer overflow` instead of
// returning null.
const std = @import("std");

fn take(src: []const u8, off: *usize, n: u32) ?[]const u8 {
    const end = off.* + n;
    if (end < off.* or end > src.len) return null;
    const s = src[off.*..end];
    off.* = end;
    return s;
}

const Header = struct { total_compressed_size: u32 };

fn compressed(data: []const u8, start: usize, hdr: Header) ![]const u8 {
    const comp_end = start + hdr.total_compressed_size;
    if (comp_end > data.len or comp_end < start) return error.Invalid;
    return data[start..comp_end];
}

fn fits(len: usize, extra: usize) bool {
    return len + extra < len;
}

// Not reported: a sum that wraps or saturates, a signed or a float
// operand, whose sign the test asks about, what the syntax does not type,
// the fixed form, and an operand changed between.
fn wrapping(a: u32, b: u32) bool {
    return a +% b < a;
}

fn moved(pos: isize, delta: isize) bool {
    const next = pos + delta;
    return next < pos;
}

fn later(x: f64, y: f64) bool {
    return x + y < x;
}

fn fixed(src: []const u8, off: *usize, n: u32) ?[]const u8 {
    const end = std.math.add(usize, off.*, n) catch return null;
    if (end > src.len) return null;
    defer off.* = end;
    return src[off.*..end];
}

fn advanced(src: []const u8, start: usize, n: usize) usize {
    var at = start;
    const end = at + n;
    at = src.len;
    return if (end < at) end else at;
}

comptime {
    _ = &take;
    _ = &compressed;
    _ = &fits;
    _ = &wrapping;
    _ = &moved;
    _ = &later;
    _ = &fixed;
    _ = &advanced;
}

// error
//
// :10:9: error: `end < off.*` tests whether `off.* + n` wrapped, but `+` does not wrap: an overflow panics in Debug and ReleaseSafe and is undefined in ReleaseFast, so the test is never true
// :20:32: error: `comp_end < start` tests whether `start + hdr.total_compressed_size` wrapped, but `+` does not wrap: an overflow panics in Debug and ReleaseSafe and is undefined in ReleaseFast, so the test is never true
// :25:12: error: `len + extra < len` tests whether `len + extra` wrapped, but `+` does not wrap: an overflow panics in Debug and ReleaseSafe and is undefined in ReleaseFast, so the test is never true
