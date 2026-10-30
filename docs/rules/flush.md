---
title: flush
parent: Rules
---

# flush

A buffered file or stream writer, written to and never flushed.

```zig
var buf: [256]u8 = undefined;
var fw = std.Io.File.stdout().writerStreaming(io, &buf);
try fw.interface.print("hello from greet\n", .{});
```

The writer collects what it is given in `buf`, and only `flush` (or
`end`, for a file) sends it on. Here the function returns, `fw` goes with
it, and the line is never written. It compiles clean in every build mode,
prints nothing and reports nothing. A command that prints why it failed to
a buffered stderr and then returns 1 exits with the right status and no
message; one that prints more than the buffer holds loses only the last
part. Code in the shape of the old API, where `std.io.getStdOut().writer()`
wrote straight through, reads the same.

The fix is `try fw.interface.flush();` after the last write, or
`try fw.end();` for a file.

## What flush reports

A `var` local made by a call to a method named `writer` or
`writerStreaming`, or by `File.Writer.init` or `.initStreaming`, whose last
argument, the buffer, is not `&.{}`, and written through its `interface`
later: a call on `fw.interface`, or on a local made with `&fw.interface`,
other than `flush`. It is reported at the declaration when nothing after
it in its block flushes it (`fw.interface.flush()`, `w.flush()` through
such a local, or the writer's own `fw.flush()` or `fw.end()`, in a `defer`
or not) or hands it on: `&fw`, `&fw.interface` or such a local passed to a
call, stored, or returned.

Not reported: an unbuffered writer (`&.{}`), which writes straight
through; `Allocating` and `fixed` writers, whose buffer is the result; a
reader; and a writer handed to a call, which only the callee can judge.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, flush reports one, real, in the compiler's build
runner, which saves a fuzz crash input through a buffered writer it never
flushes. Over fourteen well-known public Zig projects, four in a terminal
emulator: three real (two commands whose error message is lost before
they exit 1, and one whose plain output loses what is left in its 4 KB
buffer at the end) and one a test that writes a file it only deletes.

[All rules](index.md)
