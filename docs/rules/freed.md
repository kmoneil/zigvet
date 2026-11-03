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

## A value parsed out of it

```zig
const json = try gpa.dupe(u8, text);
defer gpa.free(json);
return std.json.parseFromSlice(Config, gpa, json, .{}); // strings point into json
```

`std.json.parseFromSlice` and `parseFromSliceLeaky` default to
`.allocate = .alloc_if_needed`: a string with no escape in it is a slice
of the input, not a copy. So the value's strings point into `json`, which
the `defer` frees as the function returns. It compiles clean in every build
mode, `Parsed.deinit` frees its arena without complaint, and the value
reads right until something reuses the freed bytes. A string that holds an
escape (`\"`, `é`) is copied, so the same code works on some inputs
and not others.

The fix is `.{ .allocate = .alloc_always }`, which copies every string into
the value's own memory, or keeping the input alive as long as the value.

## What freed reports

`defer x.deinit(...)`, `defer a.free(x)`, `defer a.destroy(x)` or
`defer a.rawFree(x, ...)`, where `x` is a name or a field of one
(`self.list`), then a `return` later in the same block, before anything
assigns to `x` or to what holds it, whose value is a view of `x`: `x`
itself, `x.items`, `.ptr` of a view, a slice or `&` of an element of one,
`x.written()`, `x.keys()`, `x.values()` or `x.slice()`, a `std.mem` or
`std.fmt` call that returns part of its argument
(`std.mem.trim(u8, x.items, " ")`), a cast of one, an initializer with one
as a field, a branch of an `if` or `switch` that gives one, either side of
a `catch` or `orelse`, what a `try` gives, or a `const` declared after the
`defer` with one as its value (`const items = x.items; return items;`).

A value `std.json.parseFromSlice` or `parseFromSliceLeaky` parses out of a
view of `x` is one too, unless its options set `.allocate` to anything but
`.alloc_if_needed`. The options are read where the call writes them out,
or from a `const` the function declares with an initializer; options from
anywhere else (a parameter, a call) are not known, and not reported. Nor is
a value of a number or `bool` type, which holds no string.

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

The `std.json` case turned up in a test harness that read a fixture's
JSON, parsed it, freed the text with `defer` and returned the `Parsed`: the
delimiter it held no longer matched, so the parser under test split no
field. In the public projects, the two functions that return a value
parsed out of what their `defer` frees, in ZLS and Roc, both pass
`.allocate = .alloc_always`.

[All rules](index.md)
