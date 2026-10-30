# kept

An `errdefer` that frees what the function has already stored where its
caller keeps it, and then something fails.

```zig
fn put(self: *Store, name: []const u8) !void {
    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);
    try self.names.append(self.gpa, owned);
    try self.sizes.append(self.gpa, name.len);
}
```

When the second `append` fails, the errdefer frees `owned`, but
`self.names` already holds it, and `self` goes back to a caller that still
owns it. Its `deinit` frees `owned` again, and anything that reads `names`
first reads freed memory. It compiles clean in every build mode, each line
reads correctly, and it goes wrong only when the step after the store
fails, the path tests seldom take: the debugging allocator says "double
free" when a test makes it fail, and a release build corrupts the heap and
says nothing. It is the third shape of one mistake, after [refill](refill.md) and [owner](owner.md):
a failure that leaves what the caller owns holding freed memory. Agents
wrote it in two of the application repos, where tests that refused each
allocation in turn found it, and it is in a compiler, an editor, a browser
and a terminal emulator among the public projects.

The fix is to make the store the last step that can fail:

```zig
const owned = try self.gpa.dupe(u8, name);
errdefer self.gpa.free(owned);
try self.names.ensureUnusedCapacity(self.gpa, 1);
try self.sizes.append(self.gpa, name.len);
self.names.appendAssumeCapacity(owned);
```

or to undo the store in an `errdefer` after it
(`errdefer _ = self.names.pop();`).

## What kept reports

An `errdefer` of `x.free(name)`, `x.destroy(name)`, `x.rawFree(name, ...)`
or `name.deinit(...)`, alone or in a block, and after it a store of `name`
itself: handed to `append`, `appendAssumeCapacity`, `insert`, `put`,
`putAssumeCapacity` or `putNoClobber`, as an argument or a field of one
(`.{ .name = name }`), or assigned to a field or what a pointer points at
(`self.pty = name`, or in a field initializer), where what holds it is
reached through a parameter, a local pointer made from one
(`const self: *T = @ptrCast(@alignCast(ctx));`), or what an `if` or
`while` captures from one, or is a container-level `var`. It is reported
when,
after the store and on its path, before the errdefer's block ends,
something makes the function fail: a `try`, a `return error.X`, or a
handler that returns the error it caught.

The same goes for what an optional holds, freed through `.?`:

```zig
self.search = .{ .state = try .init(self.alloc), .thread = undefined };
const s: *Search = &self.search.?;
errdefer s.state.deinit();
s.thread = try .spawn(.{}, run, .{&s.state});
```

When `spawn` fails, the errdefer deinits the state but leaves
`self.search` set, so the next search takes it as running, and the
`deinit` that checks it deinits the state again. It is reported when an
errdefer releases a place reached through `.?` of an optional, written
there or through a local pointer made from it (`&self.search.?`), where
the optional is a field reached as a store's holder is, the function
assigns it before the errdefer, a function of the file named `deinit`
names it, the errdefer does not assign it as well, and something fails
after the errdefer. Setting it back in the same errdefer
(`self.search = null;`) is the fix.

Not reported: a store into a local, which the failing function throws
away; a value made from `name` (`name.toOwnedSlice(...)`, `name.len`),
which is not what the errdefer frees; a local emptied after the store and
before the failure (`procs = .empty;`), which leaves the errdefer freeing
that, not what the holder keeps (#86); a store in a function that makes
what holds it, one named `init...` or one that writes it whole
(`self.* = .{ ... }`), whose caller holds nothing of it if it fails; a
store a `defer` or `errdefer` armed before the failure can undo, one that
names what holds it (`errdefer _ = self.names.pop();`,
`defer self.pending = null;`) or, declared after the store, hands `name`
to a call that does not free it (`errdefer self.disown(conn);`); and a
failure on a branch the store is not on, or after a `return`, `break` or
`continue` that ends its path.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, kept reports four, all real, in one application repo's
fake storage server. Over fourteen well-known public Zig projects, 22: 20
real, one of them an optional left set over what its errdefer frees, and
two that leave a freed value in something their caller throws away.

[All rules](../../README.md#the-rules)
