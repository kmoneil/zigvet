---
title: alias
parent: Rules
---

# alias

An anonymous initializer assigned to a place that it reads after storing
to it: an element reading what an earlier one stored, or, for a union or
an optional, any element reading the place at all.

```zig
if (ext[1] < ext[0]) ext = .{ ext[1], ext[0] };
```

Zig 0.17.0 writes an anonymous initializer straight into the place it is
assigned to, an element at a time in the order written. So this stores
`ext[1]` into `ext[0]`, then reads `ext[0]` back for the second element,
which is now `ext[1]` too: the swap gives `{ ext[1], ext[1] }`, in every
build mode, with no diagnostic. The same goes for a shift
(`d.rate = .{ new, d.rate[0] }`), a rotate, and a struct swap
(`p = .{ .x = p.y, .y = p.x }`). A typed initializer, `P{...}` or
`[_]T{...}`, is built aside and then copied, so it is safe and not
reported.

The fix is to copy the old value first and read the copy, or to assign the
fields one at a time, each read before it is overwritten.

## A union's tag, and an optional's mark

A union is given its tag, and an optional is marked not null, before any
element of the initializer is evaluated. So even the only element can read
what was stored:

```zig
left = .{ .pair = try alloc(arena, .{ .left = left, .right = right }) };
```

This stores `.pair` into `left`, then copies `left` into the new node as
its left side: tagged `.pair`, its payload the old `f64`'s bytes. The node
is corrupt from the start, and a later `switch` on it panics or follows a
float as a pointer. It is the natural way to build a left-associative
binary node in a recursive-descent parser's loop, and was written eight
times into one project's two parsers (#152). The optional case is the same:
`span = .{ if (span) |s| s[0] else t, t }` with `span` null takes the
`s[0]` branch, as `span` is already marked not null. Measured on 0.17.0, in
every build mode.

The fix is to build the value in a local first, then assign it:

```zig
const combined = try alloc(arena, .{ .left = left, .right = right });
left = .{ .pair = combined };
```

## What alias reports

An element of an anonymous initializer assigned with `=` that reads, by the
same path, a field or literal index an earlier element stored (by field name,
in the order written, or by position), or reads the whole place, or a part
of it holding a stored slot (`f(p.*)`), after an element has stored into it.
Nested anonymous initializers are followed field by field.

For a union or an optional, any element reading the whole place, or a part
of it holding the place (`h` for `h.e = ...`), is reported, and for a union
a read of a field other than the one being given a value. That holds when
the file declares the place a tagged union (`union(enum)` or `union(T)`) or
an optional, and for an initializer of one field into a place whose type
the file does not show, such as a type from another file or a local set
from a call, which is taken for a union. Then only a read of the whole
place is reported. A struct given one field could be reported there too,
but of the 3,050 such initializers in Zig 0.17.0's sources and twenty-six
projects, none was.

Not reported: an element reading the slot it is about to store, which is
fine and common (`lo = .{ .x = @min(lo.x, q.x), .y = @min(lo.y, q.y) }`);
an index that is not a literal, which could be either; and reads of no
memory of the place: its address (`&p.step`), the pointer it is reached
through (`.owner = b` in `b.* = .{...}`), anything shorter than it, which
may be such a pointer, a `return`, and compile-time builtins such as
`@sizeOf`. Nor, for a union, its own field (`t = .{ .leaf = t.leaf + 1 }`
reads the payload before it is written), nor for an optional its payload
(`o.?`), nor a struct the file declares given one field: its omitted
fields are given their defaults after the fields named, so
`c = .{ .a = sum(c) }` reads `c` as it was. Two names for the same memory
are out of reach.

Nor are two shapes that read what was stored on purpose: a slot stored with
what it holds already (`.superblock = self.superblock`), which reads the
same afterwards; and a whole struct given its fields by name, none of them
read from what it held, which is being made afresh, so that
`self.* = .{ .arena = .init(gpa), .allocator = self.arena.allocator() }`
reads back the field it has just set because that is the one it means. A
swap or shift reads what the place held, by position, by name, or into
part of a struct, and is still reported.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and seven
application repos, alias found one real defect and no false positive.

[All rules](index.md)
