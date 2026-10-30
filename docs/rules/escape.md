# escape

A pointer or slice into stack memory that leaves the function that made it.

```zig
fn scopesFor(scope: Scope, asked: []const []const u8) []const []const u8 {
    return if (scope == .monitoring) &.{Scope.monitoring.url()} else asked;
}
```

`Scope.monitoring.url()` is a call, so the anonymous array is built at run
time, in this function's own frame. `&` takes its address, the slice is
returned, and once the function returns that memory belongs to whatever is
called next. Zig 0.17.0 compiles this without a diagnostic in every mode: the
compiler's one error in this family ("returning address of expired local
variable") anchors on `var` locals and cannot see this shape. This exact code
shipped, passed its tests for two days, and failed only when an unrelated
`std.debug.print` happened to overwrite the stack slot.

The fix is one of:

```zig
return &.{comptime Scope.monitoring.url()};
```

or a container-level constant, which is evaluated at compile time and static:

```zig
const monitoring_read = [_][]const u8{Scope.monitoring.url()};
```

## What escape reports

Made on the stack, and not comptime-known:

- the address of an array or struct initializer, `&.{...}`, `&[_]T{...}`,
  `&T{...}`, or a slice of one;
- the address of a call's result, `&f()`;
- the address of a local, parameter or capture, a slice of a local array,
  the address of one field or element of a local held by value, or a slice
  of an array field of a local, parameter or capture held by value
  (`id.bytes[0..id.len]` with `id: Id`) when the file declares the struct,
  through as many fields held by value as its types show
  (`t.name.bytes[0..]` with `t: Topic` and `name: Name`). A `for` loop's
  capture held by value has the type of an element of its input when the
  function writes the input's type (`topics: []const Topic`).

Leaving the function:

- returned, directly or through `if`, `switch`, `orelse`, `catch`, `try`, a
  labeled block, a cast, a struct returned by value, a local that holds it,
  a local returned whole with it stored into a field or element of the
  local after its declaration (`s.w = .fixed(&s.buf); return s;`), an
  element or field read out of a local made with an initializer that
  holds it (`whole[i]` of `const whole = [_][]const T{ &.{}, &.{f()} };`),
  a `std` call that returns part of its argument
  (`std.fmt.bufPrint(&buf, ...)`, `std.mem.trim(u8, &buf, " ")`), a `std`
  reader or writer made over it (`file.writer(io, &buf)`), or one of
  the file's own that does, such as `return id.slice();` with `id` held by
  value and `fn slice(self: *const Id) []const u8 { return self.bytes[0..self.len]; }`,
  or one of the file's own whose result holds a copy of the argument, such
  as `return ctx.render(.{ .errors = &errs });` with a `render` that copies
  its `params` into memory its result points at, or `return buffer.reader();`
  with a `reader` that returns `.{ .buffer = self }`;
- stored through a parameter (`self.items = ...`, `out.* = ...`), through a
  pointer capture of what one points at (`for (into) |*out| out.* = ...`),
  or to a container-level variable. Stores report temporaries and loop
  captures only (below): a named local stored outward is usually
  deliberate (a context pointer for the length of a call, a thread's
  `current`), and a store a `defer` undoes is not reported at all.

A capture held by value in a loop, `for (topics) |topic|`, is a copy made
for one turn, which the next turn writes over. What points into it is
reported stored anywhere that outlives the turn: through a parameter or to
a container-level variable, as a temporary is, and also to a local declared
outside the loop, or through a pointer capture of one:

```zig
var last: []const u8 = "";
for (topics) |topic| last = topic.name.slice();
```

Capturing by pointer, `|*topic|`, points into what the loop walks instead.
Not reported: the same passed to a call, such as
`try map.put(gpa, topic.name.slice(), at)`, which is wrong or right by what
the callee keeps (a `StringHashMap` keeps the key, a `BufMap` copies it);
and a capture whose type is declared in another file or made by a type
function (`name: Small(249)`), whose fields the file cannot show.

Comptime-known memory is static and never reported: literals, `comptime`
expressions, container-level declarations, `comptime` parameters, and calls
to an `inline fn` (or one returning a comptime-only type) with comptime-known
arguments. The check reads the syntax alone, so
it knows a callee only by name: the file's own functions,
`std.fmt.comptimePrint`, `std.math.maxInt` and `minInt`, and as returning
part of an argument, `std.fmt`'s `bufPrint` and `bufPrintSentinel` and
`std.mem`'s `print`, `printSentinel`, `sliceTo`, `span`, `trim`,
`trimStart`, `trimEnd`, `cutPrefix`, `cutSuffix`, `asBytes`,
`sliceAsBytes`, `bytesAsSlice` and `bytesAsValue` (`print` and
`printSentinel` only through their namespace, `mem.print`), and as holding
the buffer they are given, their last argument, `std.Io`'s readers and
writers: `fixed`, `init` and `initStreaming` through a `Writer` or a
`Reader` (`std.Io.Writer.fixed(&buf)`, `File.Reader.init(file, io, &buf)`),
`.fixed(&buf)` in a file that declares no `fixed` of its own, and the
`writer`, `reader`, `writerStreaming` and `readerStreaming` methods of a
file or a stream (`file.writer(io, &buf)`), when the file declares no
method of that name for the receiver's type. A store into a field of a
local counts only for a local held by value, through as many fields as
the file's types show held by value, and into an element only for a local
array: a store through a local pointer is a store outward, as one through
a parameter is.
One of the file's own functions returns part of an argument when it
returns, directly, a slice of an array that a pointer parameter points at
or the address of one of its fields. Its result holds a copy of an
argument when it holds the parameter in a field or element of what it
returns (`return .{ .config = config };`), or in a local it returns or
holds so, at the local's declaration, in a field of it, or through it
(`p.* = params;`). A method's receiver is such an argument too: taken by
pointer, it stands for the address of a binding held by value, or where a
pointer binding points; taken by value, for what the receiver holds. Not
followed: a parameter returned whole, maybe through a cast, whose argument
may be a function's address (so not a `self` returned for chaining); and a
function declared in another file. A type is known only when the file
declares it, by name or as `@This()`, and a method only through its
receiver's written type: `const p = &id; return p.slice();` is not
followed, `const p: *const Id = &id;` is. A function whose
return type only comptime has (`type`, `comptime_int`, `comptime_float`, or
a pointer, slice, array, optional or error union of one, such as
`[]const type`) runs only at compile time, and is not checked. Nor is one
the file shows runs only then: one with a `var` only comptime allows
(`var count = 0;`), or one the file uses at least once and only ever calls
at compile time, under `comptime`, in container-level code
(`pub const entries = entriesArray();`) or from another such function.
Over fourteen public Zig projects these were 16 of escape's 20 reports.

The one accepted false positive is any other function only ever run at
compile time, such as a `pub` one called from another file, where the
address is comptime memory and legal. Say so with a
`comptime` block in the function, as upstream asks for its own check, or
with an allow comment. A function with a `comptime` parameter, which such a
function always has, gets that fix in its hint too.

## The report

```
path:line:col: escape: <what> made here leaves <function> through <return | field | global | out param>
    hint: <one line on how to fix it>
```

or, for a loop's capture stored to a local declared outside the loop,
`<what> made here leaves its turn of the loop through local '<name>'`.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources (650,000 lines)
and four application repos, escape found two real defects, and three of
the one false positive it accepts, which it now tells apart from the rest
(above).

[All rules](../../README.md#the-rules)
