// A u8 or u16 counter stepped while it is less than the .len of the slice
// it walks (#204). `headingLevel` is the issue's, from a Markdown renderer:
// a line of 256 '#'s panics with `integer overflow` at `level += 1`, as
// `level < line.len` still holds at 255. `prettyPrint` walks a screen's
// cells, width times height of them, with a u16: a terminal of more than
// 65535 cells overflows it.
const std = @import("std");

pub fn headingLevel(line: []const u8) ?u8 {
    var level: u8 = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    return level;
}

const Cell = struct { width: u16 };

pub fn prettyPrint(cells: []const Cell, out: []u16) void {
    var i: u16 = 0;
    while (i < cells.len) {
        out[i] = cells[i].width;
        i += cells[i].width;
    }
}

// Not reported: the fixed form, a counter bounded by a constant as well,
// one over an array's length, and one that counts a slice's items without
// walking it.
pub fn headingLevelFixed(line: []const u8) ?u8 {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    return @intCast(level);
}

pub fn prefix(s: []const u8) u8 {
    var i: u8 = 0;
    while (i < 16 and i < s.len and s[i] != ' ') i += 1;
    return i;
}

pub fn sum(block: *const [16]u8) u32 {
    var total: u32 = 0;
    var i: u8 = 0;
    while (i < block.len) : (i += 1) total += block[i];
    return total;
}

pub fn logAll(replicas: []const u32, log: *const fn (u8) void) void {
    var replica: u8 = 0;
    while (replica < replicas.len) : (replica += 1) log(replica);
}

comptime {
    _ = &headingLevel;
    _ = &prettyPrint;
    _ = &headingLevelFixed;
    _ = &prefix;
    _ = &sum;
    _ = &logAll;
}

// error
//
// :11:53: error: `level` is a u8, and `line.len` can be more than 255: `level < line.len` still holds at 255, so `level += 1` overflows
// :22:9: error: `i` is a u16, and `cells.len` can be more than 65535: `i < cells.len` still holds at 65535, so `i += cells[i].width` overflows
