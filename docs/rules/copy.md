---
title: copy
parent: Rules
---

# copy

A `std.Io.Writer` or `Reader` interface copied out of the struct its
methods find with `@fieldParentPtr`.

```zig
var aw: std.Io.Writer.Allocating = .init(gpa);
defer aw.deinit();
var w = aw.writer;       // a copy
try w.writeAll("hello"); // the drain looks for `aw` around `w`
```

The implementations get back to themselves from the interface's address:
`Allocating` with `@fieldParentPtr("writer", w)`, `File.Writer` with
`@fieldParentPtr("interface", w)`. So the interface works only where it
is, through `&aw.writer` or `&file_writer.interface`. A copy compiles clean
in every build mode and works until the first drain, a flush or a full
buffer, which reads whatever sits next to the copy as if it were the
parent: the code above crashes reading an allocator's `vtable` off the
stack. The old `std.io` writers were plain values that copied freely,
which is the code this looks like.

The fix is a pointer: `const w = &aw.writer;`.

## What copy reports

`x.f` read as a value, where `f` is the interface field of `x`'s type: the
initializer of a local, the value of an assignment or of a named field of
an initializer, a `return` value, or an argument to one of the file's own
functions whose parameter takes a `Writer` or `Reader` by value. `x`'s type
is one the file shows, written or made by `x`'s initializer: `File.Writer`,
`File.Reader`, `Stream.Writer`, `Stream.Reader` and `Reader.Limited`
(`interface`); `Writer.Allocating`, `Writer.Discarding`, `Writer.Hashing`,
`Writer.Hashed` and `flate.Compress` (`writer`); `Reader.Hashed` and the
`Decompress` types (`reader`); and `tls.Client` (both). A local made by a
call to a method named `writer`, `writerStreaming`, `reader` or
`readerStreaming` (`file.writer(io, &buf)`) counts as a `File.Writer` or
`File.Reader`.

Not reported: `&x.f`; a method called on it (`x.f.print(...)`), which
takes its address; a field read out of it; a field that is itself a
pointer, as `Io.Terminal`'s `writer` is, which copies fine; and a type the
file does not show.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources, the application
repos and fourteen well-known public Zig projects, copy reports nothing:
the copies there of a field named `writer` are copies of a pointer, which
copy fine.

[All rules](index.md)
