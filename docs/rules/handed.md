---
title: handed
parent: Rules
---

# handed

An `errdefer` that frees a local, still armed after a call has handed the
local to a value whose own errdefer'd release frees it.

```zig
const Pending = struct {
    gpa: Allocator,
    url: []u8,

    /// Takes `url`: destroy frees it.
    fn make(gpa: Allocator, url: []u8) !*Pending {
        const p = try gpa.create(Pending);
        p.* = .{ .gpa = gpa, .url = url };
        return p;
    }

    fn destroy(p: *Pending) void {
        p.gpa.free(p.url);
        p.gpa.destroy(p);
    }
};

fn prepare(gpa: Allocator, href: []const u8) !*Pending {
    const url = try gpa.dupe(u8, href);
    errdefer gpa.free(url);
    const p = try Pending.make(gpa, url);
    errdefer p.destroy();
    gpa.free(try gpa.alloc(u8, 1)); // when this fails, url is freed twice
    return p;
}
```

Once `Pending.make` has taken `url`, `p.destroy()` frees it. If anything
after fails, both errdefers run, the second first, and `url` is freed
twice: the debugging allocator says "double free" when a test makes that
allocation fail, and a release build corrupts the heap. Each errdefer is
right where it stands, the first covering `make` failing and the second
the steps after it, which is why each reads correctly. The bug is that
the first stays armed after the hand-over.

It is the third shape of one mistake, after [owner](owner.md) and
[twice](twice.md): two releases of one allocation on one failure. In
owner the callee frees what it is handed when it fails; in twice a
release is written out by hand; here both are the caller's errdefers.

The fix is to scope the first errdefer to the hand-over, so it covers only
the call failing:

```zig
const url = try gpa.dupe(u8, href);
const p = blk: {
    errdefer gpa.free(url);
    break :blk try Pending.make(gpa, url);
};
errdefer p.destroy();
```

## What handed reports

An `errdefer` that frees a name, as [kept](kept.md) reads one
(`x.free(name)`, `x.destroy(name)`, `x.rawFree(name, ...)` or
`name.deinit(...)`, alone or in a block), followed in its block by:

- a declaration made by a call that is handed the name as an argument
  (`const p = try Pending.make(gpa, url);`, through a `try` or a `catch`,
  or with neither), where the call is a function of the file that stores
  that parameter in a field: of an initializer (`.{ .url = url }`) or
  assigned to (`p.url = url`);
- then, in the same block, an `errdefer` that releases what the
  declaration made through a function of the file, as a method
  (`p.destroy()`) or with it as an argument (`release(p)`), that frees
  that field of it (`p.gpa.free(p.url)`, `p.url.deinit(...)`);
- then, with both armed, something that makes the function fail: a
  `try`, a `return error.X`, a handler that returns what it caught, or a
  `return` of a call that can fail.

The report is on the first errdefer, and names the call, the release and
what fails.

Not reported:

- the first errdefer scoped to the hand-over, the fix above;
- a call that copies the name (`.url = try gpa.dupe(u8, url)`) rather than
  storing it;
- a release that frees another field, or only the value itself
  (`gpa.destroy(p)`);
- a name assigned anew before the failure;
- a call or a release the file does not declare, which zigvet cannot
  read;
- nothing that fails after the second errdefer, or a failure only before
  it.

## Found in real code

The shape comes from a code review of a ~50k-line application, where a
script loader's classic and module paths both did this, and both freed a
URL twice under `checkAllAllocationFailures` (#225).

Over Zig 0.17.1's standard library and compiler, the eleven application
repos and the fourteen well-known public projects zigvet is measured on,
handed reports nothing.

[All rules](index.md)
