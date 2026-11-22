---
title: wrap
parent: Rules
---

# wrap

A test for unsigned wraparound after a plain `+`, which cannot wrap.

```zig
pub fn take(src: []const u8, off: *usize, n: u32) ?[]const u8 {
    const end = off.* + n;
    if (end < off.* or end > src.len) return null;
    const s = src[off.*..end];
    off.* = end;
    return s;
}
```

`end < off.*` is C's test for a sum that wrapped. Zig's `+` does not
wrap: an overflow panics in Debug and ReleaseSafe, and in ReleaseFast and
ReleaseSmall it is undefined behavior, so LLVM, told the add does not
wrap, may delete the test. The test is never true. Here, on a 64-bit
target the sum never overflows and `end > src.len` does the work; on
wasm32, where `usize` is 32 bits, `take(buf, &off, 0xFFFFFFFF)` panics
with `integer overflow` instead of returning null, as the author meant.
Tests and fuzzers on a 64-bit machine never see it.

The fix is to test before adding. `std.math.add` and `@addWithOverflow`
say when the sum overflows:

```zig
const end = std.math.add(usize, off.*, n) catch return null;
if (end > src.len) return null;
```

Or sum in a wider type, compare that, and then narrow it.

## What wrap reports

A comparison `s < a`, `s < b`, `a > s` or `b > s`, where `s` is
`a + b`, written in place (`if (a + b < a)`) or as a local's initializer
(`const end = start + len;`), and the operand compared is a name or a
place reached from one (`off.*`, `self.pos`), the same tokens as in the
sum.

The sum has to be shown unsigned, and nothing in it signed or a float:
when `b` is signed, `s < a` asks a real question, whether `b` was
negative. What shows it is a declared type (`usize`, `u32`, `c_uint`) of
a parameter, a local or a capture, through a pointer (`off.*` of
`off: *usize`) or of a field of a struct the file declares
(`hdr.total_compressed_size`), `.len`, `@as(u32, x)`,
`std.mem.readInt(u32, ...)`, a local's annotation (`const s: u64 = a +
b;`), or the local used to slice or index, which takes a `usize`.

Not reported:

- `+%` and `+|`, which do not trap;
- `s <= a`, which asks also whether `b` is 0;
- a comparison with anything but an operand of the sum;
- an operand or the local assigned to, or its address taken, between the
  sum and the test, or anywhere in a loop around the test and not around
  the sum, whose next turn runs the test again;
- a sum whose type the syntax does not show, such as two fields of a
  struct from another file.

## The report

```
path:line:col: wrap: `<test>` tests whether `<sum>` wrapped, but `+` does not wrap: an overflow panics in Debug and ReleaseSafe and is undefined in ReleaseFast, so the test is never true
    hint: test before adding, with `std.math.add` or `@addWithOverflow`, or sum in a wider type and compare that
```

## Found in real code

wrap was written for two bugs in one WOFF2 decoder
([#198](https://github.com/kmoneil/zigvet/issues/198)): the end of the
compressed block (`dir_end + totalCompressedSize`) and the end of each
transformed-glyf substream, both a `usize` cursor plus a `u32` from the
font, both followed by `end < start`. Each panicked on wasm32 given a
size of 0xFFFFFFFF; it reports both.

Over Zig 0.17.1's standard library and compiler sources, eleven
application repos and fourteen well-known public Zig projects, wrap
reports nothing, and nothing more when a sum whose sign the syntax does
not show is let through.

[All rules](index.md)
