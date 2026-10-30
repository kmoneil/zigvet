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
`if (place) |old| x.free(old)`, where the place is a field or what a
pointer points at (`self.items`, `a.*`), and a later statement of the same
block stores to the place, or to what holds it written whole
(`history.* = .{ ... }`), with something that can fail first: a `try`, or
a `catch` or `orelse` that returns (`orelse return error.OutOfMemory`), in
the stored value or in a statement between.

Not reported: a place reset first (`self.items = &.{}`, or a store into it
such as `self.items.len = 0`), reset by an `errdefer` or by the `catch` or
`orelse` that handles the failure
(`catch |err| { self.name = null; return err; }`), or perhaps reset by a
call between that is handed what holds it (`self.clear()`), when nothing
that can fail comes before that call; a field of a `var` local not
declared as a pointer, which holds a struct by value that the failing
function throws away; and a bare local, which an `errdefer` of its own can
cover.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, refill reports eleven, all real: two in the standard
library, four in three application repos, and five in third-party UI code
one of them keeps for reference.

[All rules](index.md)
