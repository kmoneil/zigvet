---
title: cancel
parent: Rules
---

# cancel

In a task's loop, an `Io` call whose error is dropped with `catch {}` or
`catch continue`. And anywhere, a wait whose error is returned as another.

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

A cancel can also be handed on under another name:

```zig
fn pause(io: Io) error{Timeout}!void {
    io.sleep(.fromSeconds(5), .awake) catch return error.Timeout;
}
```

`error.Canceled` is the one error `sleep` has, so the handler runs for
nothing else: a canceled task says it timed out, `cancel` on it returns
`error.Timeout`, and a caller that would stop on `error.Canceled` carries
on, or retries. The fix is to let it through, `try io.sleep(...)`, or for
a wait with a timeout of its own,
`catch |err| switch (err) { error.Canceled => |e| return e, else => return error.Timeout }`,
which adds `error.Canceled` to the function's error set, as it should be.

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

And in any function, task or not, a wait whose handler returns another
error for whatever it caught: `catch return error.X`, by itself, as the
last statement of the handler's block, or as the `else` of a `switch` on
the error caught. A wait is a call passed `io`, or made on one, named
`sleep`, `wait`, `waitTimeout`, `lock`, `lockShared`, `checkCancel`,
`futexWait` or `futexWaitTimeout`: `std.Io` declares each to return
`error.Canceled` alone, or it and a timeout, so the cancel is what the
handler renames.

Not reported: `cancel` and `await`, which drop the task's own result, not a
cancelation sent to it; anything in a `defer` or `errdefer`; handlers that
use the error or leave (`catch return`, `catch null`); and a task started
from another file, which the syntax of this one cannot see. Whether the
call's error set holds `error.Canceled` is beyond the syntax too; the hint
says how to tell. Of the handlers that name it: one that calls
`io.recancel()`, returns a value the loop may read (`while (tick())`), or
hands the error on (`error.Canceled => |e| return e`), and the same
handler in the task's own function, where returning ends the task. Of the
waits: `catch return error.Canceled`; a handler that names
`error.Canceled` or calls `recancel`; one that returns a value, or
nothing; and any other `Io` call under `catch return error.X` (a read, an
open, a connect). Those have many errors of their own, and the handler is
written for them in code nothing cancels, the standard library's
included.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and seven
application repos, cancel found one real defect and one harmless case, a
test's task that nothing cancels.

Of waits whose error is returned as another, it reports two, both real, in
an application framework: a lookup's wait for its answer, which turns a
cancel into a timeout, and a retry's backoff sleep, which turns it into an
error of its own. Nothing in the standard library or in fourteen
well-known public Zig projects. Read as any `Io` call under
`catch return error.X`, the same code gives 189 more, 45 of them in the
standard library (an `openFile`, a `length`, a `std.process.run`), which
is why the rule stops at waits.

[All rules](index.md)
