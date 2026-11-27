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
| [freed](freed.md) | A function that returns what its own `defer` frees, or a `std.json` value parsed out of it | The caller reads freed memory |
| [grow](grow.md) | A pointer into a list's items or a reader's buffer, kept across a call that can move them | The pointer reads freed memory once the list grows, or other bytes once the reader refills |
| [copy](copy.md) | A `std.Io.Writer` or `Reader` interface copied out of the struct it belongs to | The first flush reads whatever sits next to the copy as its parent, and crashes |

## Error paths: double frees, leaks, held locks

These go wrong when something fails part way, the path tests seldom take.
One needs no failure: twice, for a release written out under a plain
`defer`.

| Rule | Catches | What goes wrong |
|---|---|---|
| [refill](refill.md) | A place freed, then given new memory by something that can fail first | The place still holds the freed memory, and `deinit` or the function's own `defer` frees it again |
| [owner](owner.md) | One allocation freed by two errdefers: the caller's, and the one in the function it hands it to | Freed twice |
| [kept](kept.md) | An `errdefer` that frees what the function has already stored where its caller keeps it | The caller's `deinit` frees it again |
| [handed](handed.md) | An `errdefer` that frees a local, still armed after a call hands the local to a value whose own errdefer'd release frees it | Both run when a later step fails: freed twice |
| [torn](torn.md) | An optional or union built in place by an initializer that can fail | It is left set over what was never made, and `deinit` frees that |
| [twice](twice.md) | A deferred release also written out by hand: an errdefer's on a path that then fails, a defer's wherever its block is then left | Freed or closed twice |
| [sweep](sweep.md) | A loop that frees what a list holds, can fail part way, and empties the list only after it | The list still holds what was freed |
| [unlock](unlock.md) | A lock taken, then something that can fail before the unlock, with no `defer` | The lock stays held, and the next `lock` waits for good |
| [leak](leak.md) | A local released by hand later in its block, with something that can fail between | The release never runs |
| [orphan](orphan.md) | An allocation made in the arguments of a call that can fail (`try list.append(gpa, try gpa.dupe(u8, s))`), or in an initializer with a failure after it (`.{ .a = try gpa.dupe(u8, x), .b = try gpa.dupe(u8, y) }`) | When what follows fails nothing has a name for it, and an `errdefer` after the initializer never runs: the copy leaks, and a thread spawned that way is left neither joined nor detached |

## Errors swallowed

| Rule | Catches | What goes wrong |
|---|---|---|
| [cancel](cancel.md) | In a task's loop, an `Io` call whose error is dropped with `catch {}` or `catch continue`; anywhere, a wait whose error is returned as another (`io.sleep(...) catch return error.Timeout`) | `error.Canceled` comes once, so the loop runs on and the cancel waits for good; renamed, a canceled task says it timed out and its caller retries |
| [fit](fit.md) | A number printed into a buffer too small for it, under `catch unreachable` | A panic in Debug and ReleaseSafe, undefined behavior in ReleaseFast |

## Silently wrong results

| Rule | Catches | What goes wrong |
|---|---|---|
| [alias](alias.md) | An anonymous initializer assigned to a place that it reads after storing to it | `ext = .{ ext[1], ext[0] }` gives `{ ext[1], ext[1] }`, and `e = .{ .pair = f(e) }` hands `f` an `e` already tagged `.pair` |
| [flush](flush.md) | A buffered file or stream writer, written to and never flushed | What is left in the buffer never arrives |
| [positional](positional.md) | A writer on stdout or stderr, or a reader on stdin, made positional (`writer`, `File.Writer.init`, `reader`) | Redirected to a file it writes from byte 0, over what else is written there: `prog > log 2>&1` comes out garbled; a reader reads again what was read before it |
| [wipe](wipe.md) | A local wiped with `@memset` as the last thing done with it | Release builds drop the store, and the secret stays in memory |
| [buckets](buckets.md) | A std `HashMap`'s `capacity()` compared with a count of items, to decide whether an insert that assumes capacity has room | `capacity()` counts buckets, of which the map fills 80%: the test passes with no room, and `putAssumeCapacity` panics in Debug, undefined behavior in ReleaseFast |
| [hollow](hollow.md) | An optional given `@as(T, undefined)` of a pointer, a slice or an error set, then unwrapped in place (`dst.* = @as([]const u8, undefined);`, then `&dst.*.?`) | Its null is in the payload's bits, which this leaves undefined: Debug passes, and ReleaseSafe reads it as null and loses what was written through it |

## Data races

| Rule | Catches | What goes wrong |
|---|---|---|
| [race](race.md) | A container-level optional tested by value (`g == null`, `if (g) \|v\|`) when what it holds has a lock or atomics in it | Debug copies all of it to read the tag, a plain read racing other threads' atomic writes, and ThreadSanitizer reports it |

## Arithmetic

| Rule | Catches | What goes wrong |
|---|---|---|
| [wrap](wrap.md) | A test for unsigned wraparound after a plain `+` (`end < start` after `end = start + n`) | `+` panics rather than wraps, so the test is never true: on wasm32 the input it was written for panics |
| [narrow](narrow.md) | A `u8` or `u16` offset plus a constant as an index (`sub[offset + 4 ..]`), where the function widens or bounds-checks the offset elsewhere | Computed in the narrow type, it overflows at 0xFFFC though the widened check passed: a panic, or the wrong bytes in ReleaseFast |
| [counter](counter.md) | A `u8` or `u16` counter stepped while it is less than the `.len` of the slice it walks (`while (level < line.len and line[level] == '#') level += 1`) | The test still holds at 255, so the step overflows on a longer slice: a panic, or in ReleaseFast a loop that may never end |
| [remainder](remainder.md) | A remainder taken by hand from a floor division of a signed parameter (`t - @divFloor(t, 86400) * 86400`) | The product overflows for a `t` near the type's minimum, where `@mod` gives the answer: a panic, or undefined behavior in ReleaseFast, one odd timestamp away |
| [parsed](parsed.md) | An `i64`, `isize` or `i128` from `parseInt` in a plain `-` or `+` with nothing bounding it first (`now_s - at`, `at` parsed from a header) | One of the type's two ends overflows whatever the other operand is, and the text's writer picks it: a remote panic, or a wrapped result in ReleaseFast |

## Portability

| Rule | Catches | What goes wrong |
|---|---|---|
| [opath](opath.md) | A directory opened without `.iterate = true`, then listed, synced through its handle, or given new permissions or a new owner | Linux opens it with `O_PATH`, where each of those is `EBADF`: a panic in Debug and `error.Unexpected` otherwise, while the same code passes on macOS |
| [tail](tail.md) | `@call(.always_tail, ...)` with nothing before it that tests `builtin.zig_backend` | Zig's own x86_64 backend, the Debug default on x86_64 Linux, makes no tail calls: every Debug build there fails to compile, a library's consumers' too, while macOS and every release build pass |

## Builds and tests

| Rule | Catches | What goes wrong |
|---|---|---|
| [cached](cached.md) | A build script that lists a directory, or asks whether a path is there, to decide what to build, and never tells Zig's configure cache | A file added there, or the path once it is made, is not built until something else changes the build |
| [unrun](unrun.md) | A file whose tests never run, because nothing the test build analyses refers to it | `zig build test` passes without them |
| [hoard](hoard.md) | A fuzz target that keeps memory past one input, from an allocator the test runner does not check | It grows with every input until the run runs out of memory, and the leak check passes |

## What a rule has to be

The code compiles clean in every build mode and is still wrong. If the
compiler, `zig fmt` or an existing linter already catches it, it is not a
zigvet rule, and nor is code that is right but larger or slower than it
could be. Each rule is measured on real code before it lands: Zig's
standard library and compiler, application repos, and fourteen well-known
public Zig projects. Each rule's page says what it found there.
