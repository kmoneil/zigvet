---
title: hoard
parent: Rules
---

# hoard

A fuzz target that keeps memory past one input, from an allocator the test
runner does not check.

```zig
var seen: std.ArrayList([]const u8) = .empty;

fn one(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    try seen.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, input));
    try std.testing.expect(parse(input) != null);
}

test "fuzz: parse" {
    try std.testing.fuzz({}, one, .{});
}
```

In fuzz mode, Zig 0.17's test runner calls the function passed to
`std.testing.fuzz` once for each input, each time with a fresh
`std.testing.allocator`, and exits 1 when an input leaks from it. Memory
taken from any other allocator is not checked, so every input's copy here
is kept for the whole run. A fuzz run is millions of inputs: it ends in
gigabytes, out of memory, or a fuzzer that slows to a crawl, and nothing
says why, since the leak check passes. It compiles clean in every build
mode, and the per-input check makes the target look covered. A global grown
with `std.testing.allocator` fails that check on the first input, which is
how one comes to be grown with another allocator.

The fix is to take the memory from `std.testing.allocator`, which the runner
checks after each input, and give it back before the input ends:

```zig
const copy = try std.testing.allocator.dupe(u8, input);
defer std.testing.allocator.free(copy);
```

## What hoard reports

The target is the second argument of `std.testing.fuzz` or `testing.fuzz`:
a function of the file named alone, through a container the file declares
(`Context.testOne`), or written in place (`struct { fn f(...) ... }.f`). In
it, a call takes memory from an allocator the runner does not check when
that allocator is the call's receiver for `alloc`, `create`, `dupe` and the
like, or one of its arguments (`list.append(gpa, x)`,
`std.fmt.allocPrint(gpa, ...)`, `ArenaAllocator.init(gpa)`). Such an
allocator is written in the file: `std.heap.page_allocator`,
`smp_allocator`, `c_allocator` or `raw_c_allocator`, a local or
container-level constant set to one, or a field of the context that the
fuzz call writes as one
(`std.testing.fuzz(Context{ .gpa = std.heap.page_allocator }, ...)`).

What holds the memory is the local the call's result is bound to, or else
the receiver it is called on (`seen` of `seen.append`). The call is
reported unless the target gives it back: a call there, deferred or not
(an `errdefer` runs only on failure), that frees, destroys, deinits, resets
or clears what holds it (`gpa.free(copy)`, `list.deinit(gpa)`,
`arena.reset(.retain_capacity)`, or `list.clearRetainingCapacity()`, whose
capacity stops growing at the largest input). A call in the arguments of
one that is reported is left to that one.

Not reported: memory from `std.testing.allocator`, or from an arena or
other allocator made on it, which the runner checks after each input;
memory made once and kept for every later input, in the branch that fills
a container-level `var` the first time it is found empty and stores into it
(`keywords orelse made: { ...; keywords = parsed; ... }`,
`if (cache == null) { cache = ...; }` with `null` on either side, or the
`else` of `if (cache != null)`); a call that hands the allocator to one of
the file's own functions that gives back all it takes with it, read one
level with the parameter as the allocator
(`try validate(std.heap.page_allocator, s)`, with a `validate` that frees
its copy); the `test` block that calls `fuzz`, which runs once; a function
the target calls that takes from such an allocator itself, rather than one
it is handed; and a container that carries its own allocator, grown without
naming one.

## Targets behind a wrapper

A runner that also replays seeded inputs under a plain `zig build test`
wraps `std.testing.fuzz`, so the function that does the work is never the
fuzz call's argument:

```zig
pub fn run(context: anytype, comptime testOne: fn (@TypeOf(context), *Draw) anyerror!void, seeded: usize) anyerror!void {
    try std.testing.fuzz(context, struct {
        fn one(ctx: @TypeOf(context), smith: *Smith) anyerror!void {
            var draw: Draw = .{ .smith = smith };
            try testOne(ctx, &draw);
        }
    }.one, .{});
    // ... then each seed, through testOne
}
```

hoard reads such a wrapper
([#136](https://github.com/kmoneil/zigvet/issues/136)): a function declared
at the top of its file whose fuzz target calls one of its parameters. A
call to it, by name in its own file or through the constants that import
its file in another (`fuzzing.run({}, fuzzRender, 400)`,
`lib.fuzzing.run(...)`), has the argument in that parameter's place read as
a target. The argument in the place of the parameter the wrapper hands the
fuzz call as its context is the target's context, so a field of it set to
an allocator counts as above.

A wrapper in another file is seen when that file is checked in the same
run, and reached by path: an `@import("testing/fuzzing.zig")`, or a
constant of another file set to one. A module import
(`@import("app")`), which only the build maps to a file, is not followed.

## Found in real code

Nothing yet, and nothing was expected: the rule came from ruling this shape
out as the cause of a 22 GB fuzz run in a Markdown engine
([#132](https://github.com/kmoneil/zigvet/issues/132)), whose growth turned
out to be in Zig's fuzzer runtime, which no rule can see. Over Zig 0.17.0's
standard library and compiler sources, eleven application repos and
fourteen well-known public Zig projects, 49 files with fuzz targets, it
reports nothing. Its one report while it was being written was a target
that parses a schema once, on the first input, and keeps it in a global for
the rest, which is why memory made once is not reported.

[All rules](index.md)
