# alias

An anonymous initializer assigned to a place that one of its own later
elements reads.

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

## What alias reports

An element of an anonymous initializer assigned with `=` that reads, by the
same path, a field or literal index an earlier element stored (by field name,
in the order written, or by position), or reads the whole place, or a part
of it holding a stored slot (`f(p.*)`), after an element has stored into it.
Nested anonymous initializers are followed field by field.

Not reported: an element reading the slot it is about to store, which is
fine and common (`lo = .{ .x = @min(lo.x, q.x), .y = @min(lo.y, q.y) }`);
an index that is not a literal, which could be either; and reads of no
memory of the place: its address (`&p.step`), the pointer it is reached
through (`.owner = b` in `b.* = .{...}`), anything shorter than it, which
may be such a pointer, a `return`, and compile-time builtins such as
`@sizeOf`. Two names for the same memory are out of reach.

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

[All rules](../../README.md#the-rules)
