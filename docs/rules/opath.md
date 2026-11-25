---
title: opath
parent: Rules
---

# opath

A directory opened without `.iterate = true`, then listed, synced, or given
new permissions or a new owner.

```zig
fn syncDir(io: Io, dir: Io.Dir, sub: []const u8) !void {
    const d = try dir.openDir(io, sub, .{}); // O_PATH on Linux
    defer d.close(io);
    const as_file: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}
```

On Linux, Zig opens a directory that is not for iterating with `O_PATH`:
`dirOpenDirPosix` in `std/Io/Threaded.zig` has
`if (@hasField(posix.O, "PATH") and !options.iterate) flags.PATH = true;`.
An `O_PATH` descriptor names the directory and does not open it. It serves
as the directory a path is opened under, and it answers `fstat`. `fsync`,
`getdents64`, `fchmod` and `fchown` of one are `EBADF`, which std answers
with `errnoBug`: a panic in Debug, and `error.Unexpected` in the other
build modes. macOS has no `O_PATH`, so there the same code works and its
tests pass.

The function above is from a blob store that syncs a directory after
renaming a new file into it, so that the name is on disk as well as the
bytes. Every write of a new file failed on Linux for days while every test
on macOS passed
([#208](https://github.com/kmoneil/zigvet/issues/208)).

std says so where a doc comment can. `openDir`'s says the directory
"cannot be iterated unless the `iterate` option is set to `true`", and
those of `Dir.setPermissions` and `Dir.setOwner` that it "must have been
opened with `OpenOptions.iterate` set to `true`". Nothing checks it: the
option is a runtime value, a `Dir` is the same type either way, and the
code compiles clean in every build mode.

The fix is one field: `.{ .iterate = true }`, or for `createDirPathOpen`
`.{ .open_options = .{ .iterate = true } }`, which Linux opens without
`O_PATH`.

## What opath reports

The call that opens the directory, which is the line to change: `openDir`,
`openDirAbsolute`, `createDirPathOpen` or `std.testing.tmpDir` as a local's
initializer, when its options are written there and leave `iterate` false,
and later in the local's block the directory is:

- listed: `d.iterate()`, `d.iterateAssumeFirstIteration()`, `d.walk(...)`
  or `d.walkSelectively(...)`;
- synced: `sync` of a file made from its handle
  (`.{ .handle = d.handle, ... }`, as a local or in place), or
  `fsync(d.handle)` and `fdatasync(d.handle)` by any path;
- given new permissions or a new owner: `d.setPermissions(...)`,
  `d.setOwner(...)`;
- or handed to a function of the same file that does one of these with the
  parameter it arrives in, when that parameter is written as a `Dir`.

A `tmpDir`'s directory is its `dir` field, so `tmp.dir.iterate()` after
`std.testing.tmpDir(.{})` is reported at the `tmpDir` call.

```zig
fn syncDir(io: Io, dir: Io.Dir) !void {
    const as_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}

fn put(io: Io, root: Io.Dir) !void {
    var slots = try root.openDir(io, "slots", .{}); // reported here
    defer slots.close(io);
    try syncDir(io, slots);
}
```

Not reported: options held in a name or computed (`opts`,
`.{ .iterate = recursive }`), whose value the syntax does not show; a
directory kept in a field, returned or handed in, which only another
function shows the opening of; a local assigned again before the use, which
may by then be another directory; a function that hands the directory on to
another, since one call is followed and no further, or one whose name two
functions of the file share, since the call does not say which it reaches;
and what an `O_PATH` descriptor allows: `stat`, `close`, and everything that
takes a path under the directory (`openFile`, `access`, `createFile`,
`rename`).

## Found in real code

Over Zig 0.17.1's standard library and compiler and the fourteen well-known
public projects zigvet is measured on, opath reports nothing. They run
their tests on Linux, where the first run of such code panics, so it cannot
last there. It is a bug of code written and tested on macOS and run on
Linux.

In three of the eleven application repos zigvet is measured on, it reports
8. Two are directories synced after a rename through a `syncDir` function,
the bug above again in a second code base, whose program runs on Linux.
Five are tests that list a `std.testing.tmpDir(.{})`, which panic on their
first run there. One is in an application built only for macOS so far, a
cache directory made private with
`dir.setPermissions(io, .fromMode(0o700)) catch {}`: right where it runs
today, and on Linux a release build's `catch` would drop
`error.Unexpected` and leave the cache with the mode it was made with. The
same repos open directories without `iterate` in dozens of other places
and use them only for the paths under them, which is right, and is not
reported.

[All rules](index.md)
