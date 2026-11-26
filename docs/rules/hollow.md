---
title: hollow
parent: Rules
---

# hollow

An optional given a payload of `undefined`, then unwrapped in place,
when the payload is a pointer, a slice or an error set.

```zig
fn copyOptional(a: std.mem.Allocator, src: *const ?[]const u8, dst: *?[]const u8) !void {
    if (src.*) |*payload| {
        dst.* = @as([]const u8, undefined);
        try copySlice(a, payload, &dst.*.?); // reads as null in ReleaseSafe
    } else {
        dst.* = null;
    }
}
```

`dst.* = @as([]const u8, undefined)` is written to make `dst.*` non-null
before anything is in it, so the copy can be written where it will stay.
That works for an optional that keeps a flag of its own: `?u32`, an
optional struct or array. An optional of a pointer, a slice or an error
set keeps none. Its null is a payload of 0, so the optional is all
payload, and an undefined payload leaves undefined whether it is null.
The `.?` after it branches on that.

Debug fills undefined memory with `0xaa`, which reads as set, so the code
passes every Debug test. ReleaseSafe drops the store of `undefined`, and
the optional reads as whatever its bytes held before:

| mode (aarch64-macos) | `dst.name` after the copy, from memory that was zero |
|---|---|
| Debug | `k` |
| ReleaseSafe | `null`, then `panic: attempt to use null value` at the caller's `.?` |
| ReleaseFast | `k` (by luck) |

An `if (dst.*) |*p|` in place of the `.?` skips its branch in ReleaseSafe,
ReleaseFast and ReleaseSmall alike.

Build the payload in a local and assign the optional once:

```zig
fn copyOptional(a: std.mem.Allocator, src: *const ?[]const u8, dst: *?[]const u8) !void {
    if (src.*) |*payload| {
        var copy: []const u8 = undefined;
        try copySlice(a, payload, &copy);
        dst.* = copy;
    } else {
        dst.* = null;
    }
}
```

or, where the payload's address matters (a slot something else holds a
pointer to), store a defined value first, a copy of the source, and write
the payload through `.?`: `dst.* = payload.*;`, then
`try copySlice(a, payload, &dst.*.?);`.

Generic code meets the same bug for every type it is given that is a
pointer, a slice or an error set. A deep copy that switches on
`@typeInfo(T)` can ask the child's kind and read those aside:

```zig
.optional => |o| {
    if (comptime @typeInfo(o.child) == .pointer) {
        var v: o.child = undefined;
        try copyInto(o.child, src, &v);
        dst.* = v;
        return;
    }
    dst.* = @as(o.child, undefined);
    try copyInto(o.child, src, &dst.*.?);
},
```

## What hollow reports

An assignment (`dst.* = @as(T, undefined);`), or a local's declaration
(`var slot: ?*Node = @as(*Node, undefined);`), whose value is
`@as(T, undefined)`, where `T` is:

- a pointer or slice type written out: `*Node`, `[*]u8`, `[]const u8`,
  `[:0]const u8`, `*const fn () void`;
- `anyerror`, an error set (`error{Full}`), or a merge of error sets;
- a name declared as one of these (`const Name = [:0]const u8;`);
- or generic: a parameter of type `type` of the function around it, or of
  one that returns the type the function is declared in
  (`fn Slot(comptime T: type) type`), or a `child` (`o.child` of
  `.optional => |o|`).

It is reported when the same place, as written, is then unwrapped later
in the function: `dst.*.?`, `if (dst.*) |p|` or `while (dst.*) |p|`,
`dst.* orelse`, or a comparison with `null`, before anything stores to
the whole place or takes its address. The report is on the place, and
names the unwrap.

Not reported:

- a payload type that keeps a flag: an integer, a struct, an array, a
  C pointer (`[*c]u8`) or an `allowzero` pointer;
- a payload type the file does not show, such as a struct from another
  file (`@as(Session, undefined)`), which keeps a flag unless it is a
  pointer;
- a place assigned whole, or whose address is taken (`fill(&dst.*)`),
  before the unwrap, either of which may store a defined value;
- a store or an unwrap in a `defer` or `errdefer`, which runs when the
  block is left, not where it is written;
- a generic payload whose type the function asks `@typeInfo` about
  (`@typeInfo(o.child)`), as code that reads a pointer aside does;
- `dst.* = undefined`, the whole optional undefined, which leaves even an
  optional with a flag of its own undefined, and is another bug.

## Found in real code

The shape comes from a generic XML binding's in-place parse, where
`out.* = @as(o.child, undefined);` then `&out.*.?` lost an optional
string's child in ReleaseSafe and passed every Debug test; its fix reads
a pointer aside, as above (#232).

Over Zig 0.17.1's standard library and compiler, the eleven application
repos and the fourteen well-known public projects zigvet is measured on,
hollow reports nothing. The only optionals given `@as(T, undefined)` there
are a web browser's, whose payloads are structs and an array, which keep a
flag of their own.

[All rules](index.md)
