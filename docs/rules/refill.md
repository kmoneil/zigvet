---
title: refill
parent: Rules
---

# refill

A place freed, then given new memory by something that can fail first.

```zig
fn resize(self: *Rows, n: usize) !void {
    self.gpa.free(self.items);
    self.items = try self.gpa.alloc(u32, n);
}
```

When the `try` fails, the store never happens: `self.items` still holds
what was just freed, and the error goes back to a caller that still owns
`self`. Its `deinit` frees it again, and anything that reads it first reads
freed memory. It compiles clean in every build mode and reads naturally,
free the old and make the new, and it goes wrong only when an allocation
fails, the path tests seldom take: the debugging allocator says "double
free" when a test makes that allocation fail, and a release build corrupts
the heap and says nothing. Zig 0.17.0's standard library has two, in
`std.Io.Threaded`'s Windows command line cache and in
`std.compress.lzma`'s decoder reset.

The fix is to make the new value first, then free the old one and store
the new, so a failure leaves the old value in place:

```zig
const items = try self.gpa.alloc(u32, n);
self.gpa.free(self.items);
self.items = items;
```

## What refill reports

`x.free(place)`, `x.destroy(place)`, `x.rawFree(place, ...)` or
`place.deinit(...)`, or a call to one of the file's own functions that
frees the parameter the place is passed to (`self.destroyLocal(self.one)`,
where a statement of `destroyLocal` frees `local` or a field of it), as a
statement or the body of an `if` with no `else`, or
`if (place) |old| x.free(old)`, and a later statement of the same block
stores to the place, or to what holds it written whole
(`history.* = .{ ... }`), with something that can fail first: a `try`, or
a `catch` or `orelse` that returns (`orelse return error.OutOfMemory`), in
the stored value or in a statement between.

The place is a field or what a pointer points at (`self.items`, `a.*`),
which the caller still holds when the function fails. A local the failing
function throws away, a bare one or a field of a `var` not declared as a
pointer, is reported when the function's own `defer` frees it on the way
out, or its `errdefer` when the failure returns an error, armed before the
failure in a block around it:

```zig
var name: []u8 = try gpa.dupe(u8, "x");
defer gpa.free(name);
gpa.free(name);
name = try gpa.dupe(u8, text); // fails: the defer frees name a second time
```

A defer that frees through a loop or an `if` counts too:
`for (sample.items) |s| gpa.free(s.line)` frees `sample.items[j].line`,
and `if (name) |n| gpa.free(n)` frees `name`.

Not reported: a place reset first (`self.items = &.{}`, or a store into it
such as `self.items.len = 0`), reset by an `errdefer` or by the `catch` or
`orelse` that handles the failure
(`catch |err| { self.name = null; return err; }`), or perhaps reset by a
call between that is handed what holds it (`self.clear()`), when nothing
that can fail comes before that call; a place released by a method of
its own, one of the file's, that stores to what it frees
(`if (r.rgb) |p| gpa.free(p); r.rgb = null;`), so a second `deinit` finds
nothing; and a local no defer frees again, since nothing reads it after
the failure, or whose defer frees only what holds it
(`defer sample.deinit(gpa)` frees the list's buffer, not the lines its
elements hold).

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, refill reports eleven, all real: two in the standard
library, four in three application repos, and five in third-party UI code
one of them keeps for reference.

The local form adds thirteen over the application repos and well-known
public Zig projects, all real: a page token freed and copied again in a
paging loop, a pool or a scene rebuilt in a fuzz harness or a test, a
polled result freed and fetched again, and a name rebuilt under an
`errdefer` that frees it.

[All rules](index.md)
