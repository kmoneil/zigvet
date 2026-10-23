// A local wiped with @memset as the last thing done with it (#62): a dead
// store release builds drop, so the secret stays on the stack. `signIn` is
// a Kafka client's OAuth exchange as an agent wrote it.
const std = @import("std");

extern fn use(p: [*]const u8, n: usize) u32;

fn signIn(p: [*]const u8, n: usize) u32 {
    var secret: [64]u8 = undefined;
    defer @memset(&secret, 0);
    const k = @min(n, 64);
    @memcpy(secret[0..k], p[0..k]);
    return use(&secret, k);
}

// Not reported: secureZero, which release builds keep, and a buffer
// zeroed before it is used.
fn signInSecurely(p: [*]const u8, n: usize) u32 {
    var secret: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    const k = @min(n, 64);
    @memcpy(secret[0..k], p[0..k]);
    return use(&secret, k);
}
fn zeroed(n: usize) u32 {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    return use(&buf, @min(n, 64));
}

comptime {
    _ = &signIn;
    _ = &signInSecurely;
    _ = &zeroed;
}

// error
//
// :10:11: error: nothing reads 'secret' after this `@memset`, so release builds drop it and what it held stays in memory
