---
title: tail
parent: Rules
---

# tail

`@call(.always_tail, ...)` with nothing before it that tests the backend.

```zig
pub fn scan(xs: []const u8, start: usize) usize {
    var i = start;
    while (i + 4 <= xs.len) : (i += 4) {
        if (std.mem.findScalar(u8, xs[i..][0..4], 0)) |k| return i + k;
    }
    return @call(.always_tail, rest, .{ xs, i }); // fails on x86_64 Linux in Debug
}
```

`.always_tail` asks for a tail call or a compile error: std's doc comment
for `CallModifier` says "If this is not possible, a compile error is
emitted instead." LLVM makes one. Zig's own x86_64 backend makes none, and
it is the Debug default on x86_64 Linux. So the file compiles in every
build mode on macOS and on aarch64, and in every release build on x86_64
Linux, and every Debug build there fails:

```
$ zig test -target x86_64-linux -fno-llvm --test-no-exec tail.zig
tail.zig:15:12: error: unable to perform tail call: compiler backend 'stage2_x86_64' does not support tail calls on target architecture 'x86_64' with the selected CPU feature flags
```

The function above is from a scanner library written and tested on an
aarch64 Mac. The error landed on its consumers: every Debug build of a
program that imports it failed there, one error for each instantiation, 54
in one build. It was found the first time a consumer's suite ran on x86_64
Linux, after two releases had shipped with it
([#219](https://github.com/kmoneil/zigvet/issues/219)).

The admission test holds where the code is written: every build mode the
author runs compiles it. What fails is a build on another system, by a
backend the author's machine never picks, and for a library a build by
someone else.

The fix is to ask for the tail call only where the backend makes one, and
for a plain call elsewhere:

```zig
const builtin = @import("builtin");

const tail: std.lang.CallModifier = if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto;

pub fn scan(xs: []const u8, start: usize) usize {
    // ...
    return @call(tail, rest, .{ xs, i });
}
```

`.auto` costs a stack frame per call where the jump would have cost none,
which matters only for a call that recurses without end, as a threaded
interpreter's handlers do. Such a program can say so instead, with
`@compileError` for the backends it does not support.

## What tail reports

The `@call` whose modifier is written as `.always_tail`, or as
`CallModifier.always_tail` by any path, when nothing in its function before
it tests the backend: `builtin.zig_backend`, by itself or through a
declaration of the file whose value reads it (`const llvm =
builtin.zig_backend == .stage2_llvm;`), read in the function's body from
its start to the call. The function is the innermost one around the call.

```zig
const Handler = *const fn (vm: *Vm, ip: usize) void;
const handlers = [_]Handler{ halt, inc, dec };

fn inc(vm: *Vm, ip: usize) void {
    vm.acc += 1;
    return @call(.always_tail, handlers[vm.code[ip]], .{ vm, ip + 1 }); // reported
}
```

Not reported:

- a modifier held in a name or computed, the fix above, or
  `@call(if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto, ...)`;
- a call in a branch on the backend, an `if` or a `switch`, or after a test
  of it in its function, such as
  `if (builtin.zig_backend == .stage2_x86_64) @compileError("needs LLVM");`;
- every call in a file that refuses a backend at the top of a container,
  in a `comptime` block that tests the backend and calls `@compileError`;
- a call in a function that is not `pub` and is named only inside branches
  on the backend, as `const run = if (llvm) runTail else runLoop;` names
  `runTail`. A `pub` function is reported, since a consumer may call it
  by its name.

Reported though the build may be right:

- a build that asks for LLVM for every artifact, with `.use_llvm = true`.
  The file does not show it, and a library's consumers do not inherit it:
  their builds pick the backend for themselves.
- a test of the CPU or the build mode in place of the backend. A test that
  leaves x86_64 out, or Debug, says nothing of the backend that
  `-fno-llvm`, or a later Zig's default, picks.

LLVM makes no tail calls on wasm32 without the `tail_call` CPU feature
either, so a program built for the web needs more than the test above.
tail does not report that: the fix it asks for is the backend's.

## Found in real code

Over Zig 0.17.1's standard library and compiler and the fourteen
well-known public projects zigvet is measured on, tail reports nothing:
none of them writes `.always_tail` outside a comment.

In the eleven application repos it reports one: the call above, in an
application's vendored copy of the scanner from before its fix. Every
Debug test build of that application on x86_64 Linux failed there, 54
errors a binary, while its suites passed on the Mac it is written on.

Public code that asks for tail calls, threaded interpreters mostly, shows
the other shapes on this page: the modifier held in a constant that tests
the backend, and a `@compileError` for the x86_64 backend before the call.
Neither is reported.

[All rules](index.md)
