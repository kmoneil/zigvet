---
title: cached
parent: Rules
---

# cached

A build script that lists a directory, or asks whether a path is there, to
decide what to build, and never tells Zig's configure cache.

```zig
var dir = try b.root.openDir(b.graph.io, "test", .{ .iterate = true });
defer dir.close(b.graph.io);
var it = dir.iterate();
while (try it.next(b.graph.io)) |entry| { ... } // one addTest per file
```

Zig 0.17 caches the configure phase: when nothing it tracks has changed,
`zig build` reuses the last build graph without running `build()`. A file
added to `test/` changes nothing it tracks, so its test is never built,
and `zig build test` passes without running it, until something else
invalidates the cache: an edit to `build.zig`, a new option. It compiles
clean in every build mode, and works on every run that configures anew,
such as the first one after a clone.

The fix is `b.dependOnDirectoryContents(b.path("test"));` next to the
`openDir`, which makes the directory's entries something the cache tracks,
or `b.graph.poisonCache()`, which turns the cache off for the build.
`dependOnDirectoryContents` is not recursive: a `walk` needs one for each
directory it enters as well.

The same staleness comes from only asking whether a path is there:

```zig
if (b.root.access(b.graph.io, "locales", .{})) |_| {
    _ = b.step("locales", "Compile the locales");
} else |_| {}
```

A `locales/` made after the first run changes nothing the cache tracks, so
the step is missing until `build.zig`'s text changes; touching the file is
not enough. The fix here is a dependency on the directory the path would
be in, one that is always there:
`b.dependOnDirectoryContents(b.path("."));`, or `b.graph.poisonCache()`.
A dependency on the path itself does not do it. In Zig 0.17.1 one on a
path that is not there fails the configure
(`error: configuration failed: FileSystemFailure`), and one made only when
the path is there never sees it appear.

## What cached reports

A call to `openDir` with `.iterate = true` in its options and `b.root` in
it, in a function with a `*std.Build` parameter `b`: `b.root.openDir(...)`,
`b.root.root_dir.handle.openDir(...)`, or
`cwd().openDir(io, try b.root.joinString(...), ...)`. It is reported when
the function calls none of `dependOnDirectoryContents`,
`dependOnDirectoryMetadata` and `poisonCache`; or, when it also calls
`walk` or `walkSelectively`, which go into subdirectories, when no
`dependOnDirectory...` call of it is in a loop, as one for each directory
the walk enters is.

And a call that asks after a path of the build root: `access`, `statFile`,
`openFile`, or `openDir` with no `.iterate = true`, with `b.root` in it,
the `owner.root` of a source path (a `LazyPath`'s `src_path`), or made on a
local declared from one. It is reported when its failure is taken as an
answer: the call is the condition of an `if`, or under a `catch` whose
handler goes on (`catch null`, `catch return false`). A helper such as
`fn dirExists(b: *std.Build, path: []const u8) bool` is reported at its
probe, once for all its callers.

Not reported: `b.build_root`, the field of a Zig before 0.17, whose
configure phase always runs; a directory opened by another path
(`cwd().openDir(io, "test", ...)`, `openDirAbsolute`), which the syntax
cannot place in the build root or a Zig version; and a dependency the
caller declares, which only the caller shows. Of the paths asked after:
one under `try`, or whose handler stops the configure (`@panic`,
`unreachable`, a call to `fatal`, `exit` or `abort`, a `return` of an
error), since a configure that fails is not cached; and one in a function
that calls `poisonCache`, or a `dependOn...` that names the path or a
directory above it (`"db"` or `"."` for `"db/seeds.zig"`).

The directory to depend on may have to be found first, so the dependency
is often made in a function of its own. A call by name to a function of
the file counts as the calls that function makes itself: a helper that
makes the nearest directory above the path that is there a dependency,
`dependOnPresence(b, b.path("db/seeds.zig"))`, tells of the path it is
handed, and of a local declared from what it is handed (`sub` of
`const root, const sub = switch (dir) { ... }` by `dependOnPresence(b,
dir)`). One that calls `poisonCache` turns the cache off for the caller.
It is followed one level, and not by a name two functions of the file
have.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, cached reports no directory listed. Over fourteen
well-known public Zig projects, seven, all real, in a terminal emulator,
an event loop library and a static site generator, whose build scripts
list a directory of tests, examples or sources to decide what to build and
never tell Zig 0.17's configure cache.

Of paths asked after, it reports two in an application framework's build
script, both real: whether an app has a file of seed data, and, through a
helper, whether a directory is there. An app that gains either after its
first build does not get the step or the module until `build.zig` changes.
And two in the terminal emulator's, which asks whether a file its source
tarballs carry is in the tree: stale the same way, though a checkout
seldom gains one. Others there that ask after a path tell the cache
already, by poisoning it where the path is missing or with a dependency on
the nearest directory that exists, and are not reported. So is the
framework's fix, a helper that makes the nearest directory above each
path that is there a dependency, called before each probe.

[All rules](index.md)
