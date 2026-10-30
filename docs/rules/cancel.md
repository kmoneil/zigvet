---
title: cancel
parent: Rules
---

# cancel

In a task's loop, an `Io` call whose error is dropped with `catch {}` or
`catch continue`.

```zig
fn worker(io: Io) void {
    while (true) {
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}
```

`std.Io` delivers a cancelation request once: the next cancelation point
returns `error.Canceled`, and later ones succeed. `catch {}` takes that one
error and drops it, so the loop runs on, and whoever called `cancel` on the
task waits for good. It compiles clean in every build mode, and nothing at
run time says why the cancel never returns.

The fix, if the call's error set holds `error.Canceled`, is to return it:

```zig
line.writeStreamingAll(io, bytes) catch |err| switch (err) {
    error.Canceled => |e| return e,
    else => {},
};
```

or to call `io.recancel()` after handling it.

## What cancel reports

The same `catch {}` in code nothing cancels is harmless, and most of it is
in search, cleanup and test loops. What the syntax can see is where a task
starts, so cancel looks only in a function handed to `async` or
`concurrent` (`io.concurrent(worker, ...)`, `group.async(io, handle, ...)`),
or one such a function calls directly, in the same file, and only in its
loops. Reported there: `catch {}`, `catch |_| {}` or `catch continue` on a
call passed `io` or a field named `io`, or called on one.

And in a function a task calls inside one of its loops, a handler that
names `error.Canceled` and leaves without it:
`catch |err| { if (err == error.Canceled) return; ... }`, or a
`switch (err)` prong `error.Canceled => return` or `=> {}`. Leaving that
function returns to the task's loop, which goes on with the cancel spent,
and naming the error shows the call can return it, whatever its name.

Not reported: `cancel` and `await`, which drop the task's own result, not a
cancelation sent to it; anything in a `defer` or `errdefer`; handlers that
use the error or leave (`catch return`, `catch null`); and a task started
from another file, which the syntax of this one cannot see. Whether the
call's error set holds `error.Canceled` is beyond the syntax too; the hint
says how to tell. Of the handlers that name it: one that calls
`io.recancel()`, returns a value the loop may read (`while (tick())`), or
hands the error on (`error.Canceled => |e| return e`), and the same
handler in the task's own function, where returning ends the task.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and seven
application repos, cancel found one real defect and one harmless case, a
test's task that nothing cancels.

[All rules](index.md)
