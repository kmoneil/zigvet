---
title: leak
parent: Rules
---

# leak

A local released by hand later in its block, with something between that
can fail and no `defer` to release it.

```zig
var stmt = try r.conn.prepare(sql);
for (rows) |row| try bindRow(&stmt, row); // fails: the function returns without finalizing stmt
stmt.finalize();
```

When a `bindRow` fails, the error leaves the function before the
`finalize`, and the prepared statement is never released. It compiles
clean in every build mode and goes wrong only when the step between
fails, the path tests seldom take; the debugging allocator says "leaked"
only in a test that makes it fail. It is [unlock](unlock.md)'s shape, with a resource
for the lock. A web framework's batched insert has this exact code.

The fix is `defer stmt.finalize();` straight after the `prepare`, in
place of the one by hand, or an `errdefer` where the function returns
the local on some path.

## What leak reports

A local made by a call that can fail, under `try` or `catch`
(`try prepare(gpa)`, `try gpa.alloc(u8, n)`), or made empty (`.empty`,
`.{}`, an `init` that cannot fail), then released later in the same
block by a statement: a call on it whose name is a release word
(`stmt.finalize()`, `file.close(io)`, `list.deinit(gpa)`), or one handed
it, as its only argument or one after the first, whose name is or has
one: an allocator's (`gpa.free(buf)`), a namespace's (`posix.close(fd)`,
`c.sqlite3_finalize(stmt)`) or a function's. The release words are
`deinit`, `finalize`, `close`, `destroy`, `free`, `release` and `unmap`,
as a word of the name (`sqlite3_finalize`, not `closest`). What an
allocator's `create(T)` made is released by `destroy`, and what its
`alloc` or `dupe` made by `free`, not by a `deinit` of what an `init`
made in it. The release may be in each branch of a statement there, an
`if` with an `else` or a `switch`, when every branch releases it
(`if (keep) file.close(io) else { file.close(io); try remove(); }`).
Reported at the first statement between that fails with an
error, a `try`, a `return error.X`, or a `return` of what a `catch` or
an `else |err|` caught, on a path that does not release it first; for
an empty value, after the first statement that uses it, since one that
fails while filling it leaves nothing to release.

Not reported: a local a `defer` or `errdefer` names before the failure,
whether it releases it or hands it back
(`errdefer self.defs.restore(&snapshot);`); one assigned to between, or
stored on the failing path (`self.stmt = stmt;`); a failure in a `return`
that hands the local on (`return try wrap(face);`); one made from
something else, a name, a field, a call that cannot fail
(`self.allocatedSlice()`) or one under `orelse` (`map.get(key) orelse`),
which is a view more often than something new; one made with an arena or
released into one (`cells.deinit(p.arena)`), which frees it with the
rest; a release under `try`, a step that can fail rather than a release
(a builder's `try scope.finalize()`); a value's method with a release
word in a longer name, which releases what the value keeps
(`self.codegen.freeGeneral(reg)` hands a register back to a pool); a
failed `expect`, and code in a `test` block, where a failure ends the
test.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources, leak reports
nothing. Over the application repos, 16, all real: the two prepared
statements of the batched insert above, a file a tool leaves open when
its write fails, and allocations check programs and scratch copies leave
behind when a step fails. Over fourteen well-known public Zig projects,
ten, all real: seven in a compiler, an allocation or a canonicalizer left
behind when the next step runs out of memory; two in a database's tools;
and a directory an editor leaves open when it cannot change into it.

[All rules](index.md)
