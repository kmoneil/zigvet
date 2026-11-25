---
title: twice
parent: Rules
---

# twice

A deferred release also written out by hand, where both run: an
errdefer's on a path that then fails, a defer's wherever its block is then
left.

```zig
const conn = try gpa.create(Conn);
errdefer gpa.destroy(conn);
if (fd < 0) {
    gpa.destroy(conn);
    return error.BadConfig; // the errdefer destroys conn a second time
}
```

An errdefer runs on every error return in its scope, including one that
has already cleaned up by hand, so `conn` is destroyed twice. It compiles
clean in every build mode and reads as careful code: the hand-written free
looks like the author making sure. Unlike [refill](refill.md) and [owner](owner.md) it needs no
allocation to fail: any input that takes the refusing path frees twice,
though such paths (a library refusing a config, a platform call failing)
are often ones tests do not reach. An agent wrote this in a Kafka
client's librdkafka binding, where a refused config freed the handle's
state twice.

```zig
const fd = try listen(address);
defer close(fd);
try expect(accepts(fd));
close(fd); // the defer closes fd again when the block ends
try expectError(error.ConnectionRefused, connect(address));
```

A defer runs however its block is left, so this one needs no failure at
all: every run closes `fd` twice, and the test passes. The second close of
a descriptor is harmless only while nobody has been given its number in
between. With another thread opening sockets or files (a server and its
client in one test binary, a pool, a job runner), it closes theirs, and
the symptom is far from the cause: a connection that reads nothing, then
end of file, one run in forty. A second `free` or `destroy` is undefined
like any other. A web framework's test of its listener did this (#212).

The fix is to drop the hand-written release and let the errdefer or defer
do it. Where the release has to come early, as a listener closed to see
the next connection refused or a file closed before its rename, make the
defer conditional and turn it off there:

```zig
var listening = true;
defer if (listening) close(fd);
try expect(accepts(fd));
close(fd);
listening = false;
```

## What twice reports

A `defer` or `errdefer` whose call releases by its name (a `free`,
`destroy`, `deinit`, `close`, `unmap` or `release` of some kind:
`gpa.free`, `closeHandle`, `deinitAll`), and the same call, but for
whitespace, written as a statement after it in its block, not in a `defer`
or `errdefer`.

Under an `errdefer`, when that statement is followed on its path by
something that makes the function fail: a `try`, a `return error.X`, or a
`return` of what a `catch` or an `else |err|` caught. Not when it is
followed by a plain `return`, `break` or `continue`, which is correct,
since the errdefer does not run; nor for a failure on another branch, or
one the syntax cannot see, such as `return f()` with no `try`; nor in a
`test` block, where a failure ends the test.

Under a `defer`, each time it is written, when the way on from it leaves
the defer's block: by its end, a `return`, or a `break` or `continue` out
of it. In a `test` block too, since the defer runs when the test passes.
Not when a statement on the way takes the address of a name the call is
handed or is called on (`r.get(&c)`), through which it can be made again,
or never returns (`unreachable`, `@panic`, a call of an `exit`, `abort`,
`panic` or `fatal`, or of a function of the file declared `noreturn`),
since no defer runs then; nor after a `continue` of a labeled `switch`,
which the rule does not follow. A loop's next turn is not followed
either: after a release in a loop's body, the way on is what comes after
the loop. A defer that is not a call, such as `defer if (open)
close(fd);`, is not read.

Under either, not reported: one before a statement, on its way out of the
block, that assigns to a name the call is handed or is called on, so that
the deferred call releases something else; a call safe to run twice
(`shrinkRetainingCapacity`, a restore); a function of the file that
stores to what it frees, one of its body's statements assigning anything
but `undefined` to something that is not a local of its own
(`self.* = .{};`, `self.fd = null;`), so the second call frees nothing
(#87), found by its name, through its type, or as a method, the
receiver's type shown by its declaration or by what made it (`T{ ... }`,
a call of a function of the file, by what that is declared to return, a
local `struct`); the `close` of a `std.Io.Queue`, which std documents as
idempotent, where the file writes the queue's type; and a free inside
`if (x.len == 0)` for the `x` it is handed, which frees nothing either
time (#87). A function of a type declared in another file is not seen, so
one that is safe to run twice is still reported.

## Found in real code

Under an errdefer: over Zig 0.17.0's standard library and compiler
sources and the application repos, twice reports nothing. Over fourteen
well-known public Zig projects, 23 in one compiler: 22 real, at seven
places, and one false positive, a deinit that resets what it frees run
twice, its type declared in another file.

Under a defer: over Zig 0.17.1's standard library and compiler sources
and the fourteen public projects, nothing. Before the exemptions above,
the shape matched 48 places there and in the application repos: 32 give
the name something new on the next line, 4 exit a forked child, and 9
are safe to run twice, by a function that nulls what it frees, a queue's
close, or a value made again through its address. That leaves 3 reports,
at two places in the application repos: the listener test above, in a
copy of the framework that another repo keeps, and a test that closes a
socket twice on purpose, to show that its close can be repeated, the
type declared in another file.

[All rules](index.md)
