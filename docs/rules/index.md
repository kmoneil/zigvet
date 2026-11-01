---
title: Rules
nav_order: 2
has_children: true
has_toc: false
---

# The rules

Each rule is one word for what it catches. Its page shows the bug, why it
goes wrong, exactly what the rule reports and leaves alone, and what it
found in real code.

## Dangling pointers

| Rule | Catches | What goes wrong |
|---|---|---|
| [escape](escape.md) | A pointer or slice into stack memory that leaves the function that made it | The caller reads memory the next call writes over |
| [freed](freed.md) | A function that returns what its own `defer` frees | The caller reads freed memory |
| [grow](grow.md) | A pointer into a list's items, kept across a call that can move them | The pointer reads freed memory once the list grows |
| [copy](copy.md) | A `std.Io.Writer` or `Reader` interface copied out of the struct it belongs to | The first flush reads whatever sits next to the copy as its parent, and crashes |

## Error paths: double frees, leaks, held locks

These all go wrong only when something fails part way, the path tests
seldom take.

| Rule | Catches | What goes wrong |
|---|---|---|
| [refill](refill.md) | A place freed, then given new memory by something that can fail first | The place still holds the freed memory, and `deinit` frees it again |
| [owner](owner.md) | One allocation freed by two errdefers: the caller's, and the one in the function it hands it to | Freed twice |
| [kept](kept.md) | An `errdefer` that frees what the function has already stored where its caller keeps it | The caller's `deinit` frees it again |
| [torn](torn.md) | An optional or union built in place by an initializer that can fail | It is left set over what was never made, and `deinit` frees that |
| [twice](twice.md) | An errdefer's free also written out by hand on a path that then fails | Freed twice |
| [sweep](sweep.md) | A loop that frees what a list holds, can fail part way, and empties the list only after it | The list still holds what was freed |
| [unlock](unlock.md) | A lock taken, then something that can fail before the unlock, with no `defer` | The lock stays held, and the next `lock` waits for good |
| [leak](leak.md) | A local released by hand later in its block, with something that can fail between | The release never runs |

## Errors swallowed

| Rule | Catches | What goes wrong |
|---|---|---|
| [cancel](cancel.md) | In a task's loop, an `Io` call whose error is dropped with `catch {}` or `catch continue` | `error.Canceled` comes once, so the loop runs on and the cancel waits for good |
| [fit](fit.md) | A number printed into a buffer too small for it, under `catch unreachable` | A panic in Debug and ReleaseSafe, undefined behavior in ReleaseFast |

## Silently wrong results

| Rule | Catches | What goes wrong |
|---|---|---|
| [alias](alias.md) | An anonymous initializer assigned to a place that it reads after storing to it | `ext = .{ ext[1], ext[0] }` gives `{ ext[1], ext[1] }`, and `e = .{ .pair = f(e) }` hands `f` an `e` already tagged `.pair` |
| [flush](flush.md) | A buffered file or stream writer, written to and never flushed | What is left in the buffer never arrives |
| [wipe](wipe.md) | A local wiped with `@memset` as the last thing done with it | Release builds drop the store, and the secret stays in memory |

## Builds and tests

| Rule | Catches | What goes wrong |
|---|---|---|
| [cached](cached.md) | A build script that lists a directory to decide what to build, and never tells Zig's configure cache | A file added there is not built until something else changes the build |
| [unrun](unrun.md) | A file whose tests never run, because nothing the test build analyses refers to it | `zig build test` passes without them |
| [hoard](hoard.md) | A fuzz target that keeps memory past one input, from an allocator the test runner does not check | It grows with every input until the run runs out of memory, and the leak check passes |

## What a rule has to be

The code compiles clean in every build mode and is still wrong. If the
compiler, `zig fmt` or an existing linter already catches it, it is not a
zigvet rule, and nor is code that is right but larger or slower than it
could be. Each rule is measured on real code before it lands: Zig's
standard library and compiler, application repos, and fourteen well-known
public Zig projects. Each rule's page says what it found there.
