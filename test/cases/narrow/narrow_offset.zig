// A u16 offset plus a constant as an index, computed in u16, in a function
// that treats the offset as one into a slice longer than 64 KB (#197).
// `tagged` and `contours` are the issue's, from a font parser; `classAt`
// is its third bug, a kern class table read past a check in subtraction
// form. Each panics with `integer overflow` at an offset near 0xFFFF.
const std = @import("std");

pub fn tagged(sub: []const u8, offset: u16) ?u32 {
    if (offset == 0 or @as(usize, offset) + 6 > sub.len) return null;
    if (std.mem.readInt(u16, sub[offset + 4 ..][0..2], .big) != 0x8000) return null;
    return std.mem.readInt(u32, sub[offset..][0..4], .big);
}

pub fn contours(points: []const u8, ends: []const u16, out: []usize) void {
    var start: usize = 0;
    for (ends, 0..) |end, i| {
        out[i] = points[start .. end + 1].len;
        start = @as(usize, end) + 1;
    }
}

pub fn classAt(sub: []const u8, off: u16) ?u16 {
    if (off > sub.len or sub.len - off < 4) return null;
    return std.mem.readInt(u16, sub[off + 2 ..][0..2], .big);
}

// Not reported: the fixed forms, an index bounded by a constant, and a
// narrow index nothing in the function says is an offset into a slice.
pub fn taggedFixed(sub: []const u8, offset: usize) ?u32 {
    if (offset == 0 or offset + 6 > sub.len) return null;
    if (std.mem.readInt(u16, sub[offset + 4 ..][0..2], .big) != 0x8000) return null;
    return std.mem.readInt(u32, sub[offset..][0..4], .big);
}

pub fn classAtFixed(sub: []const u8, off: u16) ?u16 {
    if (off > sub.len or sub.len - off < 4) return null;
    return std.mem.readInt(u16, sub[@as(usize, off) + 2 ..][0..2], .big);
}

fn heading(t: []const u8, level: u8) ?u8 {
    if (level == 0 or level > 6 or level >= t.len) return null;
    return t[level + 1];
}

fn digit(table: *const [200]u8, value: u8) u8 {
    return table[value * 2];
}

comptime {
    _ = &tagged;
    _ = &contours;
    _ = &classAt;
    _ = &taggedFixed;
    _ = &classAtFixed;
    _ = &heading;
    _ = &digit;
}

// error
//
// :10:34: error: `offset + 4` is computed in u16, `offset`'s type, and overflows from `offset` = 65532, before it is widened to the `usize` the index takes
// :17:34: error: `end + 1` is computed in u16, `end`'s type, and overflows from `end` = 65535, before it is widened to the `usize` the index takes
// :24:37: error: `off + 2` is computed in u16, `off`'s type, and overflows from `off` = 65534, before it is widened to the `usize` the index takes
