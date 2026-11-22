---
title: narrow
parent: Rules
---

# narrow

A narrow unsigned integer plus or times a constant, as a slice's bound or
an index, computed in its own narrow type.

```zig
/// The u32 at offset in sub, when the u16 at offset + 4 is 0x8000.
pub fn tagged(sub: []const u8, offset: u16) ?u32 {
    if (offset == 0 or @as(usize, offset) + 6 > sub.len) return null;
    if (std.mem.readInt(u16, sub[offset + 4 ..][0..2], .big) != 0x8000) return null;
    return std.mem.readInt(u32, sub[offset..][0..4], .big);
}
```

Zig computes `x + 4` in `x`'s own type and widens only the result to the
`usize` a slice takes. The bounds check is widened and passes for
`offset` 0xFFFC to 0xFFFF in a slice of 64 KB or more; the index on the
next line is not: `offset + 4` overflows `u16`, a panic in Debug and
ReleaseSafe and the wrong bytes in ReleaseFast and ReleaseSmall. A
fuzzer seldom builds a slice that long with an offset that high.

The fix is to widen before the arithmetic, `@as(usize, offset) + 4`, or
to take the offset as a `usize`, so that no sum of it is computed narrow.

## What narrow reports

`x + k`, `k + x`, `x * k` or `k * x`, with `k` a number literal and `x`
declared an unsigned integer narrower than 32 bits (`u8`, `u16`, `u24`):
a parameter, a local's annotation, a local made with `@as(u16, ...)` or
`std.mem.readInt(u16, ...)`, a capture of a slice whose type the function
writes (`for (ends) |end|` with `ends: []const u16`), or a field of a
struct the file declares. Anywhere in a slice's start or end or an index
(`sub[x + 4 ..]`, `points[start .. end + 1]`, `table[w + i * 2]`),
through the arithmetic around it, but not into a call or a cast, whose
result has a type of its own.

Only in a function that also treats `x` itself, the same tokens, as an
offset into a slice that can be longer than its type counts:

- it widens `x`: `@as(usize, x)` or any wider unsigned type, or a local
  declared wider with `x` as its initializer (`const end: usize = x;`);
- or it compares `x` with a `.len`, or subtracts it from one
  (`if (off > sub.len or sub.len - off < 4) return null;`).

Not reported:

- a function that compares `x` with a number literal
  (`if (level > 6) return null;`), which bounds it;
- a narrow sum written where nothing in the function says `x` is an
  offset. Over Zig's standard library, the application repos and
  fourteen public projects there are 29 of those, and none is a bug: a
  loop counter bounded by its loop (`k` of `while (k < 16)`), a table
  index bounded by the table's size;
- `x +% k`, which wraps on purpose, and `x - k`, which underflows at the
  same value however wide it is;
- `usize`, `u32` and wider operands, and signed ones.

## The report

```
path:line:col: narrow: `<sum>` is computed in <type>, `<x>`'s type, and overflows from `<x>` = <n>, before it is widened to the `usize` the index takes
    hint: widen it before the arithmetic, `@as(usize, <x>) + <k>`, or declare `<x>` a `usize`
```

## Found in real code

narrow was written for bugs in one font parser (OpenType and WOFF2),
reachable from a hostile font
([#197](https://github.com/kmoneil/zigvet/issues/197)). Over its
released copies it reports both still there: a device-table offset16
checked wide and then indexed narrow (the first example), and a kern
class table at an offset16 near 0xFFFF in a subtable past 64 KB, read as
`sub[off + 2 ..]` after a check in subtraction form. A third, a glyph's
last contour end of 0xFFFF in `points[start .. end + 1]`, had been fixed
before either copy. Its one other report there is in a test helper that
builds a cmap table, `16 + 2 * n` with `n: u16`, which overflows from
`n` = 32768 but cannot get there: the table's length is cast to a `u16`
first, and that panics from `n` = 8190.

Over Zig 0.17.1's standard library and compiler sources, eleven
application repos and fourteen well-known public Zig projects, narrow
reports nothing.

[All rules](index.md)
