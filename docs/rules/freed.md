---
title: freed
parent: Rules
---

# freed

A function returns what its own `defer` frees.

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(gpa);
try list.appendSlice(gpa, a);
return list.items; // freed before the caller gets it
```

The `defer` runs after the return value is made and before the caller
gets it, so the caller always gets freed memory. It compiles clean in
every build mode. The debugging allocator writes over what it frees, so a
test that reads the result finds `UUUU` where it wrote `abcd`; a function
no test reads hands freed memory on, and a release build reads whatever
the allocator put there next.

The fix is to hand the memory over: `return list.toOwnedSlice(gpa);`,
which empties the list so the `defer` frees nothing, or an `errdefer` in
place of the `defer`.

## What freed reports

`defer x.deinit(...)`, `defer a.free(x)`, `defer a.destroy(x)` or
`defer a.rawFree(x, ...)`, where `x` is a name or a field of one
(`self.list`), then a `return` later in the same block, before anything
assigns to `x` or to what holds it, whose value is a view of `x`: `x`
itself, `x.items`, `.ptr` of a view, a slice or `&` of an element of one,
`x.written()`, `x.keys()`, `x.values()` or `x.slice()`, a `std.mem` or
`std.fmt` call that returns part of its argument
(`std.mem.trim(u8, x.items, " ")`), a cast of one, an initializer with one
as a field, or a branch of an `if` or `switch` that gives one.

Not reported: a call that takes `x` and returns something else
(`return parse(x.items)`, `return gpa.dupe(u8, x.items)`) or hands it over
(`toOwnedSlice`); a length or an element read out of it; an `errdefer`, or
a `defer` behind an `if`, which may not free on this path; and a `return`
after an assignment to `x`.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources, the application
repos and fourteen well-known public Zig projects, freed reports nothing:
the first test that reads the result fails, so the bug is fixed before it
lands, and the rule's worth is in reporting it at the edit.

[All rules](index.md)
