---
title: grow
parent: Rules
---

# grow

A pointer into a list's items, kept across a call that can move them.

```zig
const first = &list.items[0];
try list.append(gpa, x);
first.* = 7; // append moved the items when the list was full
```

`append` reallocates when the list has no room, and `first` is left
pointing at freed memory. The same holds for `getPtr`, or `getOrPut`'s
`value_ptr`, kept across a `put` on the same map, and for a `for` over
`list.items` whose body appends to `list`: the loop took the slice once
and walks on through the old memory. It compiles clean in every build
mode, and it works whenever the list happened to have room, which is most
test runs: 100 appends leave the pointer valid, 10,000 do not.

The fix is to keep the index and take the pointer again after the growth,
or to reserve with `ensureUnusedCapacity` first and grow with
`appendAssumeCapacity`, which cannot move anything.

## A reader's buffer

A `std.Io.Reader`'s buffer moves the same way
([#188](https://github.com/kmoneil/zigvet/issues/188)):

```zig
const head = in.buffered();
try in.fill(4); // may move the bytes head points at
use(head[0]);
```

When what the reader has not handed out yet does not fit after it, `fill`
moves it to the start of the buffer and reads new bytes in after, so
`head` shows other bytes. std says so for `peek` and `take`: what they
return is invalidated by the next call that reads. It works whenever the
reader is at the start of its buffer or the fill needs no room. The fix is
to take the slice again after the call, or to copy the bytes out before it
when they must outlive it.

## What grow reports

A pointer local made with `&x.items[...]`, `x.items` or a slice of it,
`x.addOne(...)` and its kind when the file shows `x` is an `ArrayList`, or
`x.getPtr(...)`, `x.getOrPut(...)`, `x.getEntry(...)` and their kind when
it shows `x` is a hash map; what an `if` captures from such a `getPtr`; a
`for` over `x.items` or a slice of it; or a local made with
`x.buffered()`, `x.peek(...)`, `x.take(...)` and their kind
(`peekGreedy`, `takeArray`, `takeDelimiterExclusive`, ...), or a slice of
one, when the file shows `x` is a reader: a type named `Reader` the file
does not declare itself, or the `interface` of one
(`&file_reader.interface`). Then a call on the same `x` that can
reallocate (`append`, `appendSlice`, `insert`, `addOne`, `resize`,
`ensureTotalCapacity` and the rest for a list; `put`, `getOrPut`,
`fetchPut`, `ensureTotalCapacity` and the rest for a map; for a reader,
any call that can read more: `fill`, `fillMore`, `rebase`, and those
named `peek`, `take`, `discard`, `read`, `stream`, `append` or `alloc`
and more), and on a path
after it a use of the pointer, or the `for`'s next turn: later in the same
block, after the loop or block a `break` leaves, or on the next turn of a
loop around the call that the pointer was declared outside of.

Not reported: the `AssumeCapacity` calls; a use in another branch of the
`if` or another prong of the `switch` the call is in, or after a
`continue` to a loop the pointer is declared in, which takes it again; a
call that comes, on every path from the pointer, after the list or map, or
what holds it, is stored again (`s.list = saved;`, `list.* = .empty;`),
which grows what was stored; a pointer taken again before the use; a
length, `found_existing` or `index` read out of it, which are copies; a
`getOrPut` that makes a new entry only on a path that leaves at once, when
a `getOrPut` made the pointer and so left a free slot; a reader made with
`fixed`, which reads the bytes it was given in place; `toss`, which reads
nothing; a list, map or reader handed to a call, which only the callee
can judge; and a type the file does not show, such as
`std.SegmentedList`, whose elements never move.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources, the application
repos and fourteen well-known public Zig projects, grow reports nothing.
The shape is common in correct code (a depth-first walk that appends and
then `continue`s), and the one place in Zig's own LLVM IR builder that
keeps a `getOrPut` pointer across another `getOrPut` is correct because
the second only inserts on a path that returns.

Readers: over Zig 0.17.1's standard library and compiler sources, which
make about 130 locals from a reader's `take`, `peek` or `buffered`, grow
reports one, and it is a bug. The resource compiler's `.ani` reader keeps
a chunk id from `takeArray(4)` across the `takeInt` after it, through a
file reader with a 2048-byte buffer: an animated icon whose `anih` id is
the last 4 bytes buffered has it read over by the refill, and is not
seen as animated.

[All rules](index.md)
