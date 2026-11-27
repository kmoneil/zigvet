// A full-width parseInt result in a plain `-` before anything bounds it
// (#235). `fresh` is the issue's, a webhook's freshness check that runs
// before the signature is checked, so `timestamp` is whatever the sender
// wrote: "-9223372036854775808" panics with `integer overflow` at the `-`.
const std = @import("std");

const tolerance_s = 5 * 60;

pub fn fresh(timestamp: []const u8, now_s: i64) bool {
    const at = std.fmt.parseInt(i64, timestamp, 10) catch return false;
    return @abs(now_s - at) <= tolerance_s;
}

/// A page number from a query string: `page - 1` panics for the minimum.
pub fn offset(query: []const u8, per_page: i64) !i64 {
    const page = try std.fmt.parseInt(i64, query, 10);
    return (page - 1) *| per_page;
}

// Not reported: compared against bounds first; a narrower type, widened;
// an operator that says what happens; and text of four characters, which
// cannot spell a value near either end.
pub fn freshFixed(timestamp: []const u8, now_s: i64) bool {
    const at = std.fmt.parseInt(i64, timestamp, 10) catch return false;
    if (at < now_s -| tolerance_s or at > now_s +| tolerance_s) return false;
    return true;
}
pub fn narrower(timestamp: []const u8, now_s: i64) bool {
    const at = std.fmt.parseInt(i32, timestamp, 10) catch return false;
    return @abs(now_s - at) <= tolerance_s;
}
pub fn saturating(timestamp: []const u8, now_s: i64) bool {
    const at = std.fmt.parseInt(i64, timestamp, 10) catch return false;
    return @abs(now_s -| at) <= tolerance_s;
}
pub fn yearBefore(date: []const u8) !i64 {
    const year = try std.fmt.parseInt(i64, date[0..4], 10);
    return year - 1;
}

test "a fresh timestamp, a stale one, and the fixed check at both ends" {
    try std.testing.expect(fresh("1731705121", 1731705121));
    try std.testing.expect(!fresh("1731700000", 1731705121));
    try std.testing.expect(!freshFixed("-9223372036854775808", 1731705121));
    try std.testing.expect(!freshFixed("9223372036854775807", 1731705121));
    try std.testing.expectEqual(20, try offset("2", 20));
    try std.testing.expect(narrower("1731705121", 1731705121));
    try std.testing.expect(!saturating("-9223372036854775808", 1731705121));
    try std.testing.expectEqual(2025, try yearBefore("2026-11-27"));
}

// error
//
// :11:17: error: `now_s - at` overflows for `at` at either end of i64, and `at` is `parseInt`'s, any value the text holds, with nothing bounding it first: a panic in Debug and ReleaseSafe, a wrapped result in ReleaseFast, for whoever writes the text
// :17:13: error: `page - 1` overflows for `page` at either end of i64, and `page` is `parseInt`'s, any value the text holds, with nothing bounding it first: a panic in Debug and ReleaseSafe, a wrapped result in ReleaseFast, for whoever writes the text
