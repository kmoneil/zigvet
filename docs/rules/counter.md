---
title: counter
parent: Rules
---

# counter

A counter declared `u8` or `u16`, stepped in a `while` loop that walks a
slice and stops at its `.len`.

```zig
/// The heading level of a Markdown line, "## Title" -> 2, or null.
fn headingLevel(line: []const u8) ?u8 {
    var level: u8 = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    return level;
}
```

`level < line.len` compares `level` widened to the `usize` of `line.len`,
so on a line longer than 255 bytes it holds for every value a `u8` has.
At 255 it passes, and `level += 1` overflows: a panic in Debug and
ReleaseSafe, and in ReleaseFast and ReleaseSmall a counter that wraps to
0 and a loop that may never end. The `level > 6` check after the loop is
the one meant, and it comes too late.

The fix is to count in a `usize` and narrow the result once it is
checked (`return @intCast(level);`), or to bound the counter by its type
as well as by the `.len`: `while (level < 7 and level < line.len ...)`.

## What counter reports

`x += k` in a `while` loop's body or continue expression, where the
loop's condition, or one of the conditions it joins with `and`, is
`x < e`, `x <= e`, `e > x` or `e >= x`, with `e` a `.len` or arithmetic
on one (`line.len - 1`), and `x` declared an unsigned integer narrower
than 32 bits (`u8`, `u16`): a local's annotation, or a local made with
`@as(u16, ...)`.

Only when the loop walks that slice with `x`: it indexes or slices the
value whose `.len` it compares with `x` or arithmetic on it
(`line[level]`, `self.screen.buf[i]`, `s[i + 1 ..]`).

Not reported:

- a counter that counts a slice's items without walking it, such as a
  replica's number passed on as a `u8`, or one that indexes another
  slice: its range is its own;
- a loop that also compares `x` with a number literal its type holds,
  in its condition (`i < 16 and i < s.len`) or its body
  (`if (i == 15) break;`), which can stop it short;
- the `.len` of an array whose type the file writes (`[16]u8`,
  `*const [N]u8`), a length known where the code is written;
- `x +%= k`, which wraps on purpose;
- `usize`, `u32` and wider counters, and signed ones.

## The report

```
path:line:col: counter: `<x>` is a <type>, and `<e>` can be more than <max>: `<test>` still holds at <max>, so `<step>` overflows
    hint: declare `<x>` a `usize`, or bound it by its type's max as well (`<x> < std.math.maxInt(<type>)`)
```

The line and column are the step's, where the overflow panics.

## Found in real code

counter was written for a Markdown heading parser in Roc's docs renderer
([#204](https://github.com/kmoneil/zigvet/issues/204)), the example
above: a doc comment line of 256 or more `#`s panics it. Over fourteen
well-known public Zig projects it reports that loop and one other bug:
libvaxis's `prettyPrint` walks a screen's cells, width times height of
them, with a `u16`, so a terminal of more than 65535 cells (256 by 256)
overflows it, where `render` walks the same cells with a `usize`.

Over Zig 0.17.1's standard library and compiler sources and eleven
application repos it reports nothing. Taking `!=` as well as `<`, `or` as
well as `and`, and `x = x + k` as a step adds one report there, in the
standard library's deflate, inside a branch where the slice is shorter
than 258 bytes, and no bug.

[All rules](index.md)
