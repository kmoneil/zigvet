# torn

An optional or union built in place by an initializer that can fail, which
`deinit` frees.

```zig
self.pending = .{
    .start = target.start,
    .removed = removed,
    .selections_before = try self.gpa.dupe(Selection, self.selections.items),
};
```

Zig 0.17.0 builds an initializer straight in the place it is assigned to,
a field at a time, as [alias](alias.md) explains, and an optional reads as set, or a
union as tagged, before any of its fields is made. When the `try` fails,
`self.pending` is left set over what was never made, and `self` goes back
to a caller that still owns it, so `deinit`, which frees what `pending`
holds, frees whatever `selections_before` happens to hold. It compiles
clean in every build mode and reads as one step. An agent wrote this in a
UI framework's text editor, where it stood until a scan found it and a
test that refused each allocation in turn confirmed the double free.

The fix is to make what can fail first, then assign:

```zig
const before = try self.gpa.dupe(Selection, self.selections.items);
self.pending = .{ .start = target.start, .removed = removed, .selections_before = before };
```

## What torn reports

An assignment of a struct or array initializer, through parentheses and
`@as`, with a `try`, or a `catch` or `orelse` that returns, in one of its
fields or elements, as deep as initializers nest, to a field whose type
the file declares as an optional or a union, reached as [kept](kept.md)'s stores are
(through a parameter, a local pointer made from one, or what an `if` or
`while` captures from one, or a container-level `var`), where a function
of the file named `deinit` names that field.

Not reported: a place left half-written, the fields before what failed new
and the rest as they were, which is wrong only if something reads it after
the error, which the syntax cannot see (over the public projects these
were mostly a result the caller drops on the error); a place whose type
the file does not show, or that no `deinit` names; a local, or memory the
function makes; a place an `errdefer` declared before it resets
(`errdefer self.pending = null;`); an assignment in a function named
`init...`, whose caller deinits nothing if it fails; and a `catch` that
falls back (`f() catch 0`), which cannot fail.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, torn reports nothing. Over fourteen well-known public
Zig projects, four, all real, in a terminal emulator, a compiler and a
browser.

[All rules](../../README.md#the-rules)
