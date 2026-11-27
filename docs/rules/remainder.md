---
title: remainder
parent: Rules
---

# remainder

A remainder taken by hand from a floor division of a signed integer the
function is handed.

```zig
/// Seconds into the day.
fn secondsOfDay(t: i64) i64 {
    return t - @divFloor(t, 86400) * 86400;
}
```

For a `t` near its type's minimum that is no multiple of the divisor,
`@divFloor(t, 86400) * 86400` is below the minimum, and the `*`
overflows: a panic in Debug and ReleaseSafe, undefined behavior in
ReleaseFast and ReleaseSmall. `secondsOfDay(std.math.minInt(i64))` is
enough. Calendar code writes this to split a timestamp into days and a
time of day, and a timestamp is often parsed from input (a date a user
typed, a header, a file), so the minimum is one request away.

It is usually two statements, and reads the same:

```zig
const days = @divFloor(us, std.time.us_per_day);
const rest: u64 = @intCast(us - days * std.time.us_per_day);
```

The fix is `@mod(t, 86400)`, the same value wherever the hand-written one
does not overflow, and one that cannot overflow.

## What remainder reports

`a - q * d` or `a - d * q`, with plain `-` and `*`, where `q` is
`@divFloor(a, d)`, written in place or as a local's initializer, and `a`
and `d` are the same tokens in both. `a` has to be a parameter of the
function, or a place reached from one (`s.at`, `at.*`), declared a signed
integer by what the file shows of its type, with nothing assigned to it
or to the local between the division and the subtraction.

A parameter is what the function cannot bound: its caller picks it. A
local is what the function computed, and its range is the computation's,
which the syntax does not show.

Not reported:

- a dividend that is a local, such as the `z` and `y` of Howard Hinnant's
  date algorithms (`const z = days + 719468;`, then
  `z - @divFloor(z, 146097) * 146097`), made from a day count that is
  itself a quotient, or from a year widened from an `i32`;
- `@divTrunc`: `a - @divTrunc(a, d) * d` is `@rem(a, d)` by hand, and its
  product is never further from zero than `a`, so it cannot overflow;
- an unsigned `a`, a float, or one whose type the file does not show;
- `-%` and `*%`, which say what happens;
- a container-level initializer, which is evaluated at compile time.

## The report

```
path:line:col: remainder: `<a> - <q> * <d>` is `@mod(<a>, <d>)` by hand, and its product overflows for `<a>` near its type's minimum, where `@mod` gives the answer: a panic in Debug and ReleaseSafe, undefined behavior in ReleaseFast
    hint: write `@mod(<a>, <d>)`, the same value wherever this one does not overflow
```

The line and column are the subtraction's.

## Found in real code

remainder was written for the date formatting of an application framework
([#239](https://github.com/kmoneil/zigvet/issues/239)), the two
statements above, on a timestamp an app may take from a request. Over
eleven application repos it reports that one and one other, both real: a
charting library's conversion of milliseconds since the epoch to a date
and a time of day.

Over Zig 0.17.1's standard library and compiler sources and fourteen
well-known public Zig projects it reports nothing. Taking a local as the
dividend too, whatever its type, adds sixteen reports over the same code,
and nothing its authors would call a bug: thirteen are the `z` and `y` of
Hinnant's algorithms, made from a day count or a year that a timestamp's
range or a date's digits already bound, one is a reading of the wall
clock, and two are pixel offsets in a terminal editor.

[All rules](index.md)
