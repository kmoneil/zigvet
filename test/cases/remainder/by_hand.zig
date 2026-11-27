// A remainder taken by hand from a floor division of a signed integer
// (#239). `secondsOfDay(minInt(i64))` panics with `integer overflow` at
// the `*`: the product is below the minimum, where `@mod(t, 86400)` is
// the same value and cannot overflow. `civil` is the issue's, from a date
// formatter: the same in two statements, on a timestamp parsed from input.
const std = @import("std");

pub fn secondsOfDay(t: i64) i64 {
    return t - @divFloor(t, 86400) * 86400;
}

pub const Civil = struct { days: i64, rest: u64 };

pub fn civil(us: i64) Civil {
    const per_day = std.time.us_per_day;
    const days = @divFloor(us, per_day);
    const rest: u64 = @intCast(us - days * per_day);
    return .{ .days = days, .rest = rest };
}

// Not reported: the fix; the truncating form, which cannot overflow; an
// unsigned dividend; and a local the function made from a quotient, the
// `z` of Howard Hinnant's civil_from_days, which is nowhere near the
// minimum.
pub fn secondsOfDayFixed(t: i64) i64 {
    return @mod(t, 86400);
}
pub fn truncated(t: i64) i64 {
    return t - @divTrunc(t, 86400) * 86400;
}
pub fn unsigned(t: u64) u64 {
    return t - @divFloor(t, 86400) * 86400;
}
pub fn dayOfEra(us: i64) u64 {
    const z = @divFloor(us, std.time.us_per_day) + 719468;
    const era = @divFloor(z, 146097);
    return @intCast(z - era * 146097);
}

test "the hand-written remainder and @mod agree where it does not overflow" {
    for ([_]i64{ -86401, -86400, -1, 0, 1, 86399, 86400, 1731705121 }) |t| {
        try std.testing.expectEqual(secondsOfDayFixed(t), secondsOfDay(t));
        try std.testing.expectEqual(@as(u64, @intCast(@mod(t, std.time.us_per_day))), civil(t).rest);
    }
    _ = &truncated;
    _ = &unsigned;
    _ = &dayOfEra;
}

// error
//
// :9:12: error: `t - @divFloor(t, 86400) * 86400` is `@mod(t, 86400)` by hand, and its product overflows for `t` near its type's minimum, where `@mod` gives the answer: a panic in Debug and ReleaseSafe, undefined behavior in ReleaseFast
// :17:32: error: `us - days * per_day` is `@mod(us, per_day)` by hand, and its product overflows for `us` near its type's minimum, where `@mod` gives the answer: a panic in Debug and ReleaseSafe, undefined behavior in ReleaseFast
