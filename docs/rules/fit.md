---
title: fit
parent: Rules
---

# fit

A number printed in decimal into a buffer too small for it, with the
error asserted away.

```zig
fn printNumber(gpa: Allocator, out: *std.ArrayList(u8), v: f64) !void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
}
```

`{d}` on a float never switches to scientific notation: 1e40 prints as 41
digits, the largest f64 as 309, and its smallest subnormal, negative, as
327 bytes. So for `v = 1e60` bufPrint returns error.NoSpaceLeft, and
`catch unreachable`, which says it cannot, turns that into a panic in
Debug and ReleaseSafe and undefined behavior in ReleaseFast and
ReleaseSmall, with no diagnostic in any mode. 48 bytes reads as a fair
size because it is one for the integers most code prints: a u64 is at
most 20 digits. A chart library shipped this, reachable from any number in
its data.

The fix is one of: print with `{e}`, which needs at most 24 bytes for an
f64; size the buffer for the worst case; or handle the error, with `try`
or a fallback such as `catch "?"` into a `[]const u8`.

An integer goes wrong the same way when its type is wider than the buffer
was sized for, and in generic code the caller picks it. A web framework's
rate limit keyed its buckets by the app's own user type:

```zig
fn keyOf(ctx: anytype, buf: *[24]u8) []const u8 {
    if (ctx.current_user) |u| return std.fmt.bufPrint(buf, "u{d}", .{u.id}) catch unreachable;
    // ...
}
```

24 bytes holds any i64, but a u128 prints as 39 digits and an i128 as 40
bytes, so an app whose ids are u128 would crash a worker on every
logged-in request. The fix is a buffer of 40 bytes, with a comptime check
that the type is an integer of at most 128 bits, or handling the error.

## What fit reports

`std.mem.print` or `printSentinel`, or `std.fmt.bufPrint` or
`bufPrintSentinel`, which 0.17.0 keeps for them, under `catch unreachable`,
printing with `{d}`, `{}` or `{any}` (fill, width, precision and `{?d}`
included) into a buffer smaller than the most that can print: for an
f16, f32 or f64, 11, 48 and 327 bytes, or with a precision of n digits, 6,
40 and 310 bytes and then a point and n; for an integer, the digits of its
largest magnitude and a sign if it has one, such as 20 bytes for a u64,
i64, usize or isize and 39 for a u128; and for a value whose type the
caller picks, 40 bytes, the longest i128. The buffer's length has to be in
the syntax: `&buf` or `buf[0..]` with `buf: [N]u8`, or `buf` with
`buf: *[N]u8`, where N is a literal, a container-level constant, or
`std.fmt.float.min_buffer_size` (53, which is too small). So does the
value's type: a parameter, local, capture or container-level variable
declared `f16`, `f32`, `f64` or an integer type, or such a field of a
struct the file declares, found the way [escape](escape.md) finds types. Or the caller
picks it: an anytype parameter, a field of one, what an `if`, `while`,
`for` or `switch` captures from one, or a local made from one with no type
written, in a function that is pub, is named other than to call it, or is
passed such a value by a call in the file.

The file cannot say which types its callers pass, so a value whose type
the caller picks is reported even when every caller, in other files,
passes an i64. A buffer of 40 bytes costs 16 more and settles it; or say so
with `// zigvet: allow fit every caller passes an i64 id`.

Not reported: a value bounded before it is printed, where any comparison
of it (`<`, `<=`, `>`, `>=`), or `@min`, `@max` or `clamp` of it, or of a
local made from it, earlier in the function counts as a bound, since a
bound can take many shapes; one made from an integer with
`@floatFromInt`, which prints no longer than the integer; a constant whose
value is a literal; an anytype parameter of a private function every call
to which, in the file, passes a type the file decides (`writeInt(count)`
with `count: u64`); and a value whose type is not written and the caller
does not pick (an untyped local, a type declared in another file, a
`comptime T: type` parameter's), or is an f80 or f128.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and nine
application repos, fit reports no float. Over zig-charts as it was before
an audit fixed three of these, it finds two; the third prints a field of a
type declared in another file.

Integers came in 0.17.0. Over the standard library, eleven application
repos and fourteen well-known public Zig projects, they added four
reports: one real, a web framework's rate limit keyed by the app's own
user id ([#128](https://github.com/kmoneil/zigvet/issues/128)), and three
false positives, each an integer whose type or bound is written in another
file.

[All rules](index.md)
