# cached

A build script that lists a directory to decide what to build, and never
tells Zig's configure cache.

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

Not reported: `b.build_root`, the field of a Zig before 0.17, whose
configure phase always runs; a directory opened by another path
(`cwd().openDir(io, "test", ...)`, `openDirAbsolute`), which the syntax
cannot place in the build root or a Zig version; and a dependency the
caller declares, which only the caller shows.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, cached reports nothing. Over fourteen well-known public
Zig projects, seven, all real, in a terminal emulator, an event loop
library and a static site generator, whose build scripts list a directory
of tests, examples or sources to decide what to build and never tell Zig
0.17's configure cache.

[All rules](../../README.md#the-rules)
