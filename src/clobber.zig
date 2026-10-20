//! The escape rule's cheap companion, for a project's own tests: exported
//! as the `zigvet` module, so a test calls `zigvet.clobberStack()`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Writes 0xAA over the 16 KB of stack below the caller's frame, where the
/// frame of a function it just called was. Call it between a call and the
/// first read of what the call returned: a pointer or slice into the
/// callee's dead frame then reads wrong in that very test, rather than
/// passing until some later call happens to reuse the memory.
///
/// It finds the bug only in a function a test calls, and is dependable only
/// in a Debug build, where a read of a dead frame goes to the frame as it
/// was left. The escape rule finds the shapes it knows in any function.
pub noinline fn clobberStack() void {
    var buf: [16 * 1024]u8 = undefined;
    @memset(&buf, 0xAA);
    std.mem.doNotOptimizeAway(&buf);
}

const Scope = enum {
    monitoring,
    cloud_platform,

    fn url(scope: Scope) []const u8 {
        return switch (scope) {
            .monitoring => "https://www.googleapis.com/auth/monitoring.read",
            .cloud_platform => "https://www.googleapis.com/auth/cloud-platform",
        };
    }
};

/// gcp-desktop-app's `scopesFor` as of 18 October 2026, the bug that
/// prompted zigvet: `url()` is a call, so the array is built in this frame.
noinline fn scopesForDangling(scope: Scope, asked: []const []const u8) []const []const u8 {
    // zigvet: allow escape the bug these tests show clobberStack catching
    return if (scope == .monitoring) &.{Scope.monitoring.url()} else asked;
}

/// The fix: a container-level constant is evaluated at compile time.
noinline fn scopesForFixed(scope: Scope, asked: []const []const u8) []const []const u8 {
    return if (scope == .monitoring) &monitoring_read else asked;
}
const monitoring_read = [_][]const u8{Scope.monitoring.url()};

test "clobberStack makes a slice into a returned frame read wrong" {
    if (builtin.mode != .debug) return error.SkipZigTest;
    const asked = [_][]const u8{Scope.cloud_platform.url()};
    const got = scopesForDangling(.monitoring, &asked);
    clobberStack();
    // The element itself, not the bytes it points to: clobbered, its
    // pointer is 0xAAAA... and reading through it would fault.
    const want = Scope.monitoring.url();
    try testing.expect(got[0].ptr != want.ptr or got[0].len != want.len);
}

test "clobberStack leaves static memory alone" {
    const asked = [_][]const u8{Scope.cloud_platform.url()};
    const got = scopesForFixed(.monitoring, &asked);
    clobberStack();
    try testing.expectEqualStrings(Scope.monitoring.url(), got[0]);
}
