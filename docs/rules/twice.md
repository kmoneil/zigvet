# twice

An errdefer's free also written out by hand on a path that then fails.

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

The fix is to drop the hand-written free and let the errdefer do it.

## What twice reports

An `errdefer` whose call releases by its name (a `free`, `destroy`,
`deinit`, `close`, `unmap` or `release` of some kind: `gpa.free`,
`closeHandle`, `deinitAll`), and the same call, but for whitespace,
written as a statement after it in its block, not in a `defer` or
`errdefer`, followed on its path by something that makes the function
fail: a `try`, a `return error.X`, or a `return` of what a `catch` or an
`else |err|` caught.

Not reported: the same statement followed by a plain `return`, `break` or
`continue`, which is correct, since the errdefer does not run; a failure
on another branch; one after a statement that assigns to a name the call
is handed or is called on, which then frees something else; a call safe
to run twice (`shrinkRetainingCapacity`, a restore); a method of a type
the file declares whose body ends by writing its receiver whole with
anything but `undefined` (`self.* = .{};`), so the second call frees
nothing, the type shown by the receiver's declaration or by what made it
(`T{ ... }`, `T.init(...)`); a free inside `if (x.len == 0)` for the `x`
it is handed, which frees nothing either time (#87); code in a `test`
block; and a failure the syntax cannot see, such as `return f()` with no
`try`. A method of a type declared in another file is not seen, so one
that resets its receiver is still reported.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, twice reports nothing. Over fourteen well-known public
Zig projects, 23 in one compiler: 22 real, at seven places, and one false
positive, a deinit that resets what it frees run twice, its type declared
in another file.

[All rules](../../README.md#the-rules)
