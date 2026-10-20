const std = @import("std");

const Scope = enum {
    monitoring,
    logging,
    fn url(self: Scope) []const u8 {
        return @tagName(self);
    }
};
const monitoring_read = [_][]const u8{Scope.monitoring.url()};

fn literal() []const []const u8 {
    return &.{"https://www.googleapis.com/auth/monitoring.read"};
}
fn containerConst() []const []const u8 {
    return &monitoring_read;
}
fn saidComptime() []const []const u8 {
    return &.{comptime Scope.monitoring.url()};
}
fn empty() []const u8 {
    return &.{};
}
fn enumLiterals() []const Scope {
    return &.{ .monitoring, .logging };
}
fn bytes() []const u8 {
    return &.{ 0x30, 'a', 1 + 2 };
}
fn comptimeParameter(comptime n: u8) []const u8 {
    return &.{ n, n };
}
fn typeParameter(T: type) []const usize {
    return &.{ @sizeOf(T), @alignOf(T) };
}
fn comptimeLocal() []const u8 {
    const n = 4;
    return &.{ n, n };
}
fn switchOnComptime() []const u8 {
    return &.{switch (@import("builtin").os.tag) {
        .linux => 1,
        else => 2,
    }};
}
inline fn pair(comptime n: u8) [2]u8 {
    return .{ n, n };
}
fn inlineCall() []const u8 {
    return &pair(3);
}
fn printed(comptime n: u8) []const []const u8 {
    return &.{std.fmt.comptimePrint("bytes=0-{d}", .{n})};
}
fn maxInt() []const u8 {
    return &.{std.math.maxInt(u8)};
}

comptime {
    _ = &literal;
    _ = &containerConst;
    _ = &saidComptime;
    _ = &empty;
    _ = &enumLiterals;
    _ = &bytes;
    _ = &comptimeParameter;
    _ = &typeParameter;
    _ = &comptimeLocal;
    _ = &switchOnComptime;
    _ = &inlineCall;
    _ = &printed;
    _ = &maxInt;
}

// compile
