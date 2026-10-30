---
title: unlock
parent: Rules
---

# unlock

A lock taken, then something that can fail before the unlock, with no
`defer` to unlock it.

```zig
try self.pool_mut.lock(io);
const conn = try self.pool.create(self.allocator); // fails: the function returns holding the lock
self.pool_mut.unlock(io);
```

When `create` fails, the error leaves the function with the mutex still
held, and the next `lock` waits for good. It compiles clean in every build
mode and goes wrong only when the step between fails, the path tests
seldom take, and nothing at run time says why the program hangs. An HTTP
server library's connection pool has this exact code.

The fix is `defer self.pool_mut.unlock(io);` straight after the lock.

## What unlock reports

`x.lock(...)`, `x.lockUncancelable(...)`, `x.lockShared(...)` or
`x.lockSharedUncancelable(...)` as a statement, or under `try`, then
`x.unlock(...)` (or `x.unlockShared(...)`) later in the same block, `x`
the same as written, and between them something that fails with an error:
a `try`, a `return error.X`, or a `return` of what a `catch` or an
`else |err|` caught, on a path that does not unlock first.

Not reported: a lock a `defer` or `errdefer` unlocks before the failure,
however it is written (`defer if (!unlocked) m.unlock();`); a plain
`return` between, since a function may return holding the lock on
purpose; the lock call's own `catch`; and code in a `test` block, where a
failure ends the test.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, unlock reports nothing. Over fourteen well-known public
Zig projects, two, both real, in an HTTP server library and a game engine.

[All rules](index.md)
