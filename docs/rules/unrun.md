---
title: unrun
parent: Rules
---

# unrun

A file whose tests never run, because nothing the test build analyses
refers to it.

```zig
// storage.zig, whose own tests run: the module's root has `test { _ = storage; }`
pub const s3 = @import("storage/s3.zig");
pub const S3 = s3.S3;

test "storage: a key that could leave the store is refused" { ... }
```

Zig analyses a declaration only when something it analyses refers to it,
and runs a file's tests only when it analyses the file. None of
storage.zig's tests names `s3` or `S3`, or anything that leads to them, so
s3.zig is never analysed: `zig build test` passes, and not one of s3.zig's
tests is built or run. They read as coverage in review and have never run
once. It compiles clean in every build mode.

The fix is a line in a test block of storage.zig, `_ = s3;`, which the
hint names. `std.testing.refAllDecls(@This())` does it for every pub
declaration of the file, but not for one that is not pub, nor for the
files those import in turn, which `refAllDeclsRecursive` does. A module
the test build imports by name, `@import("vaxis")`, never runs its tests
in it, however much of the module the build uses.

## What unrun reports

It is the one rule that reads more than one file: it asks which of the
files checked the tests reach, so name the project's directory, its
`build.zig` with it.

It starts from the roots, the files whose tests a build runs with nothing
referring to them: a `.zig` path a build script names
(`b.path("src/root.zig")`, in `build.zig` or a file with a `*std.Build`
parameter), each file under a directory one opens, and, where nothing
names one, an import cycle that nothing outside it imports, a file
nothing imports among them: the files of it whose tests name another
file, as a test root's do (`test { _ = forum; }`,
`refAllDecls(@This())`), or each file of it when none does. That last is
how a root the build hides is found, such as an app's `app.zig` that a
framework's build script names and the app's files import back. A
root's tests reach what they name,
and a declaration reached reaches everything in it: a function's body, a
type's members and their tests. `alias.Name`, with `alias` a constant
`@import("x.zig")`, reaches `Name` in x.zig, and `_ = alias;` reaches
x.zig alone, which runs its tests. An import used as a value, as an
argument (`refAllDecls(alias)`, `@typeInfo(alias)`), a type or a local
constant, reaches every pub declaration of x.zig, as reflection over it
may. In the standard library, `@import("std")` is its `std.zig`.

Reported, at the file's first test: a file with tests that a file checked
imports by path and nothing reached refers to. Every guess errs toward
reached, so the rule misses rather than reports: a name is taken to mean
the file's declaration of it wherever it is used, and code a comptime
condition rules out counts. Not seen: a root only the build's own logic
names (`b.path(b.fmt(...))`), unless it is found as above, a file outside
those checked, tests run another way, such as `zig test` in a script, and
a module that names
itself, `@import("mylib")` inside mylib, which only the build maps to a
file; an allow comment above the reported `test` covers one of those.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, unrun reports 16 files of tests that never run, all
real: 13 in the compiler's copy of its resource compiler, which no root of
Zig's build reaches; one in its AST generator, whose one test the standard
library's tests never reach; and an application repo's benchmark helper,
with the copy another keeps. Over that repo as it was before a fix found
by hand, it reports the two files the fix names. Over fourteen well-known
public Zig projects, four, all real, in a terminal UI library: 20 tests of
its widgets, which neither its tests nor its C API's run.

With a cycle the build hides the root of rooted at the files whose tests
name another file ([#141](https://github.com/kmoneil/zigvet/issues/141)),
the standard library, one import cycle whose root no build script in the
lib directory names, shows one more without being told `std.zig` is its
root: `std/os/linux/bpf/btf.zig`, whose one test never runs, since
bpf.zig declares `btf` and nothing the tests reach names it. Over the
application repos and the fourteen public projects, that change reports
nothing new.

[All rules](index.md)
