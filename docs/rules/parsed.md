---
title: parsed
parent: Rules
---

# parsed

A full-width signed `parseInt` result as an operand of a plain `-` or `+`,
with nothing bounding it first.

```zig
/// A webhook's freshness check, run before its signature is checked, so
/// `timestamp` is whatever the sender wrote.
pub fn fresh(timestamp: []const u8, now_s: i64) bool {
    const at = std.fmt.parseInt(i64, timestamp, 10) catch return false;
    return @abs(now_s - at) <= tolerance_s;
}
```

`at` is any value the text holds. For `x - p`, one of `p` at the type's
minimum and `p` at its maximum overflows for every `x` but -1, and for
`x + p` for every `x` but 0, so it does not matter where `x` came from:
whoever writes the text picks an operand that overflows. A timestamp of
`-9223372036854775808` panics this function in Debug and ReleaseSafe, and
in ReleaseFast the difference wraps and the check answers from that. When
the text is a header, a query parameter or a file, it is a remote panic.

The fix is to compare the value against bounds first,
`if (at < now_s -| tolerance_s or at > now_s +| tolerance_s) return false;`,
to parse a narrower type and widen it, or to say what happens with `-|`,
`-%` or `std.math.sub`.

## What parsed reports

`a - b` or `a + b`, with a plain operator, where one operand is the result
of a call named `parseInt` whose type is `i64`, `isize` or `i128`: the
call itself, under `try` or `catch`, or a local it initializes. The other
operand can be anything no wider, a literal included: `page - 1` panics
for one value, and the sender can write it.

Not reported:

- a value the function bounds before the arithmetic, at one end at least:
  an ordering comparison with it as an operand (`at < lo`, an `assert` of
  one), `@min`, `@max` or a call named `clamp` with it as an argument, or
  a `switch` on it. A timestamp held to no less than zero can be taken
  from another;
- a narrower type (`parseInt(i32, ...)`), whose sum with an `i64` cannot
  overflow, and an unsigned one, which a later comparison often checks;
- an other operand the file shows wider (`@as(i128, now) - at`);
- text of a fixed width under nineteen characters (`text[0..4]`, a year),
  which cannot spell a value near either end;
- `-|`, `+|`, `-%`, `+%`, `std.math.sub` and `std.math.add`;
- a local assigned again before the arithmetic;
- a parsed value that reaches the arithmetic through a field or another
  function, which the syntax of one function does not follow;
- a product. `secs * 1000` overflows for more values than a sum does, and
  is another rule's.

## The report

```
path:line:col: parsed: `<a> - <b>` overflows for `<b>` at either end of <type>, and `<b>` is `parseInt`'s, any value the text holds, with nothing bounding it first: a panic in Debug and ReleaseSafe, a wrapped result in ReleaseFast, for whoever writes the text
    hint: compare `<b>` against bounds first, parse a narrower type and widen it, or say what happens with `-|`, `-%` or `std.math.sub`
```

The line and column are the sum's or the difference's.

## Found in real code

parsed was written for a webhook's freshness check
([#235](https://github.com/kmoneil/zigvet/issues/235)), the example
above, which ran before the signature was checked, and for the same check
in a second application. Both were fixed before the rule was written, so
over Zig 0.17.1's standard library and compiler sources and eleven
application repos it reports nothing.

Over fourteen well-known public Zig projects it reports one sum, in a
static site generator that reads a commit's time from git's own output,
which git keeps in range: the shape, and nothing its authors would call a
bug. Before the guard on fixed-width text it reported three more in an
application, the year, hour and minute of a date parser, read from four
and two characters.

[All rules](index.md)
