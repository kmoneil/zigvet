---
title: orphan
parent: Rules
---

# orphan

An allocation made in the arguments of a call that can fail.

```zig
fn keep(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), s: []const u8) !void {
    try list.append(gpa, try gpa.dupe(u8, s));
}
```

The copy is made before `append` runs. When `append` then fails, the
error leaves the function, and the copy has no name an `errdefer` could
free it by: it leaks. It compiles clean in every build mode and goes wrong
only when the outer call fails, the path tests seldom take.
`std.testing.checkAllAllocationFailures` on this function reports
`allocated bytes: 5, freed bytes: 0`.

The same shape with a thread,
`try threads.append(gpa, try std.Thread.spawn(.{}, run, .{}))`, leaves a
thread neither joined nor detached, and with an open file, a descriptor
nothing closes. Under a `catch` that undoes state, a second thing goes
wrong: `list.append(gpa, try gpa.dupe(u8, s)) catch |err| { undo(); return err; }`
returns through the inner `try` when the copy fails, and never runs
`undo()`.

The fix is to give it a name and arm its release before the call:

```zig
const copy = try gpa.dupe(u8, s);
errdefer gpa.free(copy);
try list.append(gpa, copy);
```

or to make the call unable to fail first: `ensureUnusedCapacity`, then
`appendAssumeCapacity(try gpa.dupe(u8, s))`.

## What orphan reports

An argument written `try <call>`, where the call is one of std's that
hand back what the caller releases, by name: an allocator's `alloc`,
`dupe`, `create` and their variants, `allocPrint`, a list's
`toOwnedSlice`, `Thread.spawn`, and a directory's `openFile`, `openDir`
and `createFile`. It is reported when the call it is an argument of can
fail where it stands: it is under `try`, or what a `catch` handles.

Memory is reported only from an allocator named for the general-purpose
one, `gpa` in its name (`gpa`, `self.gpa`, `m.gpa`). An arena frees what
it gave with the rest, and most calls of this shape pass one. Under any
other name (`allocator`, `a`) the syntax cannot tell which it is, so
those are left alone. A thread or an open file is reported whatever the
list it goes into is made with.

Not reported:

- an allocator with `arena` in its name, or a local made from one
  (`const gpa = arena_state.allocator();`);
- a call that cannot fail (`appendAssumeCapacity`), or whose `catch` is
  `unreachable`;
- a call to a function of the file that frees that parameter itself when
  it fails, with an `errdefer` naming it, as a function that takes
  ownership does;
- an argument that is no maker by name (`try parse(s)`), and a `spawn`
  that is not `Thread`'s;
- code in a `test` block, where a failure ends the test.

## The report

```
path:line:col: orphan: what <maker> makes here has no name, so if <call> fails after it, nothing releases it
    hint: give it a name and arm its release before the call (`const copy = try gpa.dupe(u8, s); errdefer gpa.free(copy);`), or make the call unable to fail first (`ensureUnusedCapacity`, then `appendAssumeCapacity`)
```

The line and column are the inner `try`'s.

## Found in real code

orphan was written for an application framework
([#236](https://github.com/kmoneil/zigvet/issues/236)): a job runner's
threads, each appended to a list as it is spawned, and two lists of copies
in a client's model. Over eleven application repos it reports those three
and 32 more, all real: 18 are one terminal UI's notices, each copied or
printed in the arguments of a helper that appends it and frees nothing
when the append fails, where one `errdefer` in the helper answers them
all; the rest are copies appended to lists, in three applications, two
check tools and a client library's test fakes.

Over fourteen well-known public Zig projects, 26, all in one compiler:
eleven in its CI checks, nine in test helpers, and six in its build
coordinator, each a copy handed to a call that can fail. Over Zig 0.17.1's
standard library and compiler sources, nothing.

Reading any allocator not named for an arena gives 365 reports over the
same code, and most are arenas under another name (`a`, `allocator`): 84
in one library that reports 6 here. So memory is reported only from an
allocator named `gpa`.

[All rules](index.md)
