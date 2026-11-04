---
title: race
parent: Rules
---

# race

A container-level optional asked whether it is null by value, when what it
holds has atomics or a lock in it.

```zig
var registry: ?Registry = null; // Registry has a `mutex: std.Io.Mutex`

fn state(io: std.Io) *Registry {
    if (registry == null) registry = .{ .gpa = gpa, .io = io }; // race
    return &registry.?;
}
```

In Debug, `registry == null` copies the whole global and then reads the
tag from the copy. `if (registry) |r|` does the same before it copies the
payload out. Measured on Zig 0.17.1, on x86_64-linux and aarch64-macos
alike:

| Read | What Debug does with `registry` |
|---|---|
| `registry == null`, `registry != null`, `null == registry` | copies all of it (136 bytes here), then loads the tag from the copy |
| `if (registry) \|r\|`, `\|_\|`, `while (registry) \|r\|` | the same, then copies the payload out |
| `if (registry) \|*r\|` | loads the tag byte in place |
| `registry.?.mutex`, `&registry.?` | reads in place |

When other threads lock the mutex, or store to an atomic, while one thread
asks, that copy is a plain read racing their atomic writes: a data race,
which is undefined behavior. ThreadSanitizer reports it on Linux, a memcpy
against the mutex's cmpxchg, from every test that has threads using the
global; macOS's ThreadSanitizer does not see it. It compiles clean in
every build mode, and the tag read from the copy is right, so the tests
pass until a race detector looks. Release builds drop the copy; the Debug
build a ThreadSanitizer run uses keeps it.

The fix is to ask through a pointer, which reads only the tag:

```zig
fn state(io: std.Io) *Registry {
    if (registry) |*r| return r;
    registry = .{ .gpa = gpa, .io = io };
    return &registry.?;
}
```

## What race reports

`g == null` and `g != null`, either way round, and an `if` or `while` that
captures `g`'s payload by value (`|r|`, `|_|`), where `g` is a
container-level `var` written as `?T`, named as it is or through its
container (`S.g`, `@This().g`), and `T` is a struct or union the file
declares with a field that other threads change atomically:

- `std.atomic.Value(...)`;
- a `Mutex`, `RwLock`, `Semaphore`, `ResetEvent` or `WaitGroup` of any
  namespace, so a project's own `io.Mutex` too;
- a `Condition` or `Event` of `std.Io`, `std.Thread` or `std.atomic`, as
  those names are common elsewhere (`ui.Event`);
- one of those through a container-level `const` (`const Atomic =
  std.atomic.Value;`), or an array of them;
- or a struct the file declares that holds one, a level down.

Not reported:

- a `const`, which nothing writes; a `threadlocal`, which no other thread
  reaches; a local; or a field;
- a capture by pointer, and `.?`;
- a payload with none of those fields, where the same copy is only a
  waste, and a payload type from another file, which zigvet cannot see;
- the global copied some other way, `const r = g.?` or `g orelse ...`
  into a local. Debug copies all of it there too, but what is wanted
  there is the copy, which has its own trouble: a copied lock is not the
  lock.

## Found in real code

One of the application repos zigvet is measured on, a web framework, had
the shape in three modules: a pubsub registry (`registry == null`, a mutex
in the payload), a rate limit table and a traffic table
(`shared == null`, an atomic counter), each started lazily and asked on
every call from every thread. Its first ThreadSanitizer run over the
whole suite, on 4 November 2026, reported them on Linux from every test
that used them, and not on macOS; they now ask through a pointer, and
this rule was proposed from them
([#170](https://github.com/kmoneil/zigvet/issues/170)). Over its code from
before that fix, race reports all three, a fourth of the same shape, and
one test. The test, still there, asks `process == null` after the threads
that touch it were joined: the copy is made, but nothing runs to race it.

Over Zig 0.17.1's standard library and compiler, the other application
repos and the fourteen well-known public projects, it reports nothing.

[All rules](index.md)
