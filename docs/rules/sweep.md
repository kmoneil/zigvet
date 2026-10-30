# sweep

A loop that frees what a list holds, can fail part way, and empties the
list only after it.

```zig
for (self.queue.items) |m| {
    try self.send(m); // fails on a later turn: earlier turns' are freed and still held
    self.gpa.free(m);
}
self.queue.clearRetainingCapacity();
```

When `send` fails on the third message, the first two are freed, the
`clearRetainingCapacity` never runs, and the queue still holds them: the
next flush sends freed memory and frees it again, and `deinit` frees it
once more. It compiles clean in every build mode and reads as tidy code,
free each, then clear. It is [refill](refill.md)'s mistake in a loop: freed, then a
failure before the place is reset. An agent wrote it in a UI framework's
image store, where a review found it.

The fix is to take each out of the list as it is freed
(`while (q.held.pop()) |m|`), or to empty the list before the loop and
free what it held.

## What sweep reports

A `for` over `p.items`, or a slice of it, where `p` is reached as [kept](kept.md)'s
stores are, whose body frees what the loop's capture holds
(`x.free(e)`, `x.destroy(e)`, `x.rawFree(e, ...)` or `e.deinit(...)`, with
`e` the capture, reached through it, or captured from it by a `switch` or
an `if`) and can fail (a `try`, or a `catch` or `orelse` that returns), so
a later turn fails after an earlier turn's free, when `p` is emptied after
the loop (`clearRetainingCapacity`, `clearAndFree`,
`shrinkRetainingCapacity`, `shrinkAndFree`, or `p.items.len = ...`).

Not reported: a list taken apart as it is freed (`swapRemove`,
`orderedRemove` or `pop` on it in the loop); a list a local holds; and a
list an `errdefer` before the loop resets.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, sweep reports nothing. Over fourteen well-known public
Zig projects, one, real, in an editor.

[All rules](../../README.md#the-rules)
