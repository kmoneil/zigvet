---
title: positional
parent: Rules
---

# positional

A writer on stdout or stderr made positional.

```zig
var buf: [1024]u8 = undefined;
var out = std.Io.File.stdout().writer(io, &buf); // positional
try out.interface.print("{d} rows\n", .{n});
try out.interface.flush();
```

`File.writer` and `File.Writer.init` make a positional writer: it writes
with `pwrite` at a position of its own, from byte 0, and never moves the
file's offset. In a terminal or a pipe `pwrite` fails and the writer falls
back to writing where the stream is, so it works there. Redirected to a
regular file it does not: it writes over whatever else is written to that
file.

Measured on Zig 0.17.0, a program that writes `result line 1`, prints
`warning: something` with `std.debug.print`, then writes `result line 2`:

| Run | Positional stdout | Streaming stdout |
|---|---|---|
| `prog > log 2>&1` | `warning: sometresult line 2` | all three lines |
| `{ echo before; prog; echo after; } > log` | the lines written over each other | all four lines |
| `prog >> log` on macOS | the start of the log written over | appended |
| `prog > log`, the only writer | correct | correct |

`prog > log 2>&1` is the usual way to keep a CI log. On Linux, `pwrite`
appends under `O_APPEND`, so `>>` is safe there; the shared file of
`2>&1` is not. It compiles clean in every build mode, and a program that
is the only writer of a fresh file gets correct output, which is how it
passes its tests. zigvet 0.1.0 had it, and lost its own findings under
`zig build` ([#7](https://github.com/kmoneil/zigvet/issues/7)).

The fix costs nothing: `writerStreaming`, or `File.Writer.initStreaming`
in place of `.init`, writes at the file's offset, after what else was
written there.

## What positional reports

`f.writer(io, buffer)`, `File.Writer.init(f, io, buffer)` and
`File.Writer.initDetect(...)`, or `.init(f, ...)` and `.initDetect(f, ...)`
for a local whose type is written as a `File.Writer`, where `f` is stdout
or stderr: `std.Io.File.stdout()`, `File.stderr()` and the like,
`.stdout()` where a `File` is expected, or a `const` the function declares
as one. `initDetect` picks streaming only for a terminal, so it is
positional for a file too.

Not reported: the streaming writers; a writer on any other file, which the
program opens and is the only writer of; a reader; and a file the function
is handed, which only its caller knows.

## Found in real code

Zig 0.17.0's own `zig init` template makes its stdout writer this way
(`lib/init/src/main.zig`), so most projects made with `zig init` start
with it. Over the standard library and compiler, positional reports 15
writers: the template, `translate-c`, `objcopy`, `resinator`, aro's driver
and the benchmarks. It reports 25 in four of the application repos zigvet
is measured on, and 53 in nine of the fourteen well-known public projects,
31 of them in Ghostty (`ghostty +version > out.txt 2>&1` among them).
The same code bases make 106 streaming writers on the same streams.

[All rules](index.md)
