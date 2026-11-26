---
title: buckets
parent: Rules
---

# buckets

A std `HashMap`'s `capacity()`, which counts buckets, tested as room for
items before an insert that assumes capacity.

```zig
const Set = struct {
    map: std.AutoHashMapUnmanaged(u32, void) = .empty,
    count: u32 = 0,

    /// Room for one more key, made here where running out can be
    /// reported, so the insert after it cannot fail.
    fn room(s: *Set, gpa: std.mem.Allocator) !void {
        if (s.map.capacity() <= s.count) try s.map.ensureTotalCapacity(gpa, 2 * s.count + 16);
        s.count += 1;
    }

    fn add(s: *Set, gpa: std.mem.Allocator, k: u32) !void {
        try s.room(gpa);
        s.map.putAssumeCapacity(k, {}); // panics at the 26th key
    }
};
```

`capacity()` of a `HashMap` or `HashMapUnmanaged` is its bucket count,
`header().capacity`, and the map holds only its max load of them, 80% by
default, before `available` runs out. `ensureTotalCapacity(gpa, 16)` gives
32 buckets with room for 25 keys, and `room` does not grow again until
`count` reaches 32, so the 26th `putAssumeCapacity` takes
`self.available -= 1` below zero: `integer overflow` in Debug and
ReleaseSafe, undefined behavior in ReleaseFast.

It compiles clean, passes every test that stays under 80% of a power of
two, and reads correctly. `ArrayList` and the array hash maps count items
in `capacity`, which is the reading the code assumes, and the managed
`HashMap.capacity` doc comment says "the number of total elements which
may be present before it is no longer guaranteed that no allocations will
be performed", which is not what it returns.

The fix is to ask for room counted in items, which `ensureUnusedCapacity`
and `ensureTotalCapacity` both take:

```zig
fn add(s: *Set, gpa: std.mem.Allocator, k: u32) !void {
    try s.map.ensureUnusedCapacity(gpa, 1);
    s.map.putAssumeCapacity(k, {});
}
```

`ensureUnusedCapacity` returns at once when there is room.

## What buckets reports

A call of `capacity()` on a map whose type the file writes as one of std's
hash maps that count buckets: `HashMap`, `HashMapUnmanaged`,
`AutoHashMap`, `AutoHashMapUnmanaged`, `StringHashMap` or
`StringHashMapUnmanaged`, reached from `std` (`std.AutoHashMap(K, V)`,
`std.hash_map.HashMap(...)`, `@import("std").StringHashMap(V)`), or a name
declared as one (`const Map = std.StringHashMap(u8);`). It is reported when
it is compared, by itself or in a sum or a difference
(`m.capacity() - m.count() < n`), with `<`, `<=`, `>` or `>=`, against
anything but `0`, in the condition of an `if` or a `while`, and:

- the function around the comparison grows the same map
  (`ensureTotalCapacity`, `ensureUnusedCapacity`) or inserts into it with
  a call that assumes room (`putAssumeCapacity`,
  `putAssumeCapacityNoClobber`, `getOrPutAssumeCapacity` and the like);
- and the file inserts into that map with such a call somewhere, in that
  function or another (`s.map` reached from the same field of the same
  struct counts as the same map).

The report is on the `capacity()` call, and names the insert.

Not reported:

- an array hash map (`AutoArrayHashMapUnmanaged`), whose `capacity()`
  counts items;
- a map type the file declares, or one from another file, which may
  count either way;
- a comparison outside a condition: `assert(m.capacity() >= n)` after
  `ensureTotalCapacity(n)` holds, and says only that the buckets are
  there;
- a comparison with `0`, which asks whether the map has memory at all;
- a map nothing inserts into with a call that assumes room: `put` grows
  when it must, so a test that grows too seldom costs time, not memory
  safety;
- a local map with no type written (`var m = std.AutoHashMap(K, V).init(gpa);`),
  whose type the file does not show.

## Found in real code

The shape comes from a code review of a ~50k-line application, where a
garbage collector's root set grew a map this way and inserted with
`getOrPutAssumeCapacity` where it could not allocate: a page holding 26
to 31 detached DOM nodes panicked in a Debug build (#226).

Over Zig 0.17.1's standard library and compiler, the eleven application
repos and the fourteen well-known public projects zigvet is measured on,
buckets reports nothing. The only std hash map whose `capacity()` is
compared there is in an `assert` right after `ensureTotalCapacity`, which
holds.

[All rules](index.md)
