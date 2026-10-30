# wipe

A local wiped with `@memset` as the last thing done with it, a dead store
release builds drop.

```zig
var secret: [64]u8 = undefined;
defer @memset(&secret, 0);
```

Nothing reads `secret` after the `memset`, and its life ends with it, so
to the optimizer the store is dead: in ReleaseFast it is not there at all,
even when the local's address was handed to a call before, and the secret
stays in the stack slot for whatever reads that memory next. It compiles
clean in every build mode, and Debug keeps the store, so a test of the
wipe passes. A Kafka client wiped its OAuth exchange this way, nine
times, before changing every one to `std.crypto.secureZero`, "which an
optimizer cannot drop". A security weakness rather than a crash: the
secret stays readable.

The fix is `defer std.crypto.secureZero(u8, &secret);`, which writes
through a volatile pointer that release builds keep.

## What wipe reports

`@memset(&x, 0)`, `@memset(&x.field, 0)` or `@memset(x[a..b], 0)`, where
`x` is a `var` local held by value (an array, or a value made with an
initializer or of a struct the file declares), in a `defer` in `x`'s own
block, or as a statement followed in that block only by statements that
do not name `x`.

Not reported: a `memset` followed by a use of `x` (initialization, or
reuse in a loop); one a `defer` declared before it reads after it; what a
pointer or slice points at, which may be the heap; a value other than
zero, as a test writes `'x'` over a buffer to show a callee kept its own
copy; code in a `test` block; and `std.crypto.secureZero`.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources, the application
repos and fourteen well-known public Zig projects, as they are now, wipe
reports nothing. Over a Kafka client as it was before it changed its
wipes, it reports all nine.

[All rules](../../README.md#the-rules)
