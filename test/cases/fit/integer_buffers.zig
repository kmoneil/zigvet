// `{d}` prints a u64 in at most 20 bytes, but a u128 in 39 and an i128 in
// 40. A buffer sized for an i64 is too small for a wider one, and when the
// caller picks the type, as through anytype, nothing says it is not
// wider (#128). The first is the shape ekur's rate limit had, keyed by the
// app's own user type.
const std = @import("std");

pub const RateLimit = struct {
    pub fn call(ctx: anytype) usize {
        var buf: [24]u8 = undefined;
        return keyOf(ctx, &buf).len;
    }

    fn keyOf(ctx: anytype, buf: *[24]u8) []const u8 {
        if (ctx.current_user) |u| return std.fmt.bufPrint(buf, "u{d}", .{u.id}) catch unreachable;
        return "i";
    }
};

fn wide(id: u128) usize {
    var buf: [24]u8 = undefined;
    return (std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable).len;
}

// Not reported: a private function given only types the file writes, a
// buffer the longest i128 fits in, or an integer type that fits.
fn writeInt(n: anytype) usize {
    var buf: [24]u8 = undefined;
    return (std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable).len;
}
fn writeCount(count: u64) usize {
    return writeInt(count);
}
pub fn roomy(user: anytype) usize {
    var buf: [40]u8 = undefined;
    return (std.fmt.bufPrint(&buf, "{d}", .{user.id}) catch unreachable).len;
}
fn small(n: u32) usize {
    var buf: [10]u8 = undefined;
    return (std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable).len;
}

const User = struct { id: u128 };
const Ctx = struct { current_user: ?User };

fn withWideIds(ctx: Ctx) usize {
    return RateLimit.call(ctx) + roomy(ctx.current_user.?);
}

comptime {
    _ = &withWideIds;
    _ = &wide;
    _ = &writeCount;
    _ = &small;
}

// error
//
// :15:74: error: `{d}` of 'u.id', whose type the caller picks, can need 40 bytes as an i128, 41 with the rest of the format, but buf holds 24, and `catch unreachable` says std.fmt.bufPrint cannot fail
// :22:45: error: `{d}` of u128 'id' can need 39 bytes, but &buf holds 24, and `catch unreachable` says std.fmt.bufPrint cannot fail
