# zigvet

Things Zig compiles that are wrong.

`zigvet [paths...]` parses every `.zig` file with `std.zig.Ast`, the
compiler's own parser, and reports code the compiler accepts in every build
mode that is almost certainly a bug. `go vet` is the closest analog: not
style, which the existing linters cover, but silent wrongness.

Status: seventeen rules. Escape, run over the 0.17.0 standard library and
compiler sources (650,000 lines) and four application repos, found two real
defects and three of its one accepted kind of false positive, which it now
tells apart (below). Alias, run over the same standard library and seven
application repos, found one real defect and no false positive. Cancel,
over the same code, found one real defect and one harmless case, a test's
task that nothing cancels.
Fit, over the same standard library and nine application repos, reports
nothing; over zig-charts as it was before an audit fixed three of these,
it finds two, the third printing a field of a type declared in another
file. Refill, over the same code, reports eleven, all real: two in the
standard library, four in three application repos, and five in third-party
UI code one of them keeps for reference. Owner, over the same code,
reports three, all real: two in two application repos, and a copy of one
of them another keeps; over the public projects, six, all real, in one
compiler, two of them in its tests. Kept, over the same code, reports
four, all real, in one application repo's fake storage server; over
fourteen public Zig projects, 22: 20 real, one of them an optional left
set over what its errdefer frees, and two that leave a freed value in
something their caller throws away. Torn, over the same code, reports
nothing;
over the fourteen public projects, four, all real, in a terminal
emulator, a compiler and a browser. Twice, over the same code, reports
nothing; over the public projects, 23 in one compiler: 22 real, at seven
places, and one false positive, a deinit that resets what it frees run
twice, its type declared in another file. Sweep, over the same code,
reports nothing; over the public projects, one, real, in an editor.
Unlock, over the same code, reports
nothing; over the public projects, two, both real, in an HTTP server
library and a game engine. Wipe, over the same code as it is now and the
public projects, reports nothing; over a Kafka client as it was before
it changed its wipes, all nine. Freed, over the same code and the public
projects, reports nothing: the first test that reads the result fails,
so the bug is fixed before it lands, and the rule's worth is in
reporting it at the edit. Grow, over the same code and the public
projects, reports nothing; the shape is common in correct code (a
depth-first walk that appends and then `continue`s), and the one place
in Zig's own LLVM IR builder that keeps a `getOrPut` pointer across
another `getOrPut` is correct because the second only inserts on a path
that returns. Copy, over the same code and the public projects, reports
nothing; the copies there of a field named `writer` are copies of a
pointer, which copy fine. Flush, over the same code, reports one, real,
in the compiler's build runner, which saves a fuzz crash input through a
buffered writer it never flushes; over the public projects, four in a
terminal emulator, three real (two commands whose error message is lost
before they exit 1, and one whose plain output loses what is left in
its 4 KB buffer at the end) and
one a test that writes a file it only deletes. Cached, over the same code,
reports nothing; over the public projects, seven, all real, in a terminal
emulator, an event loop library and a static site generator, whose build
scripts list a directory of tests, examples or sources to decide what to
build and never tell Zig 0.17's configure cache.

## Rule one: escape

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

### What escape reports

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
  an element or field read out of a local made with an initializer that
  holds it (`whole[i]` of `const whole = [_][]const T{ &.{}, &.{f()} };`),
  a `std` call that returns part of its argument
  (`std.fmt.bufPrint(&buf, ...)`, `std.mem.trim(u8, &buf, " ")`), or one of
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
`printSentinel` only through their namespace, `mem.print`).
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

## Rule two: alias

An anonymous initializer assigned to a place that one of its own later
elements reads.

```zig
if (ext[1] < ext[0]) ext = .{ ext[1], ext[0] };
```

Zig 0.17.0 writes an anonymous initializer straight into the place it is
assigned to, an element at a time in the order written. So this stores
`ext[1]` into `ext[0]`, then reads `ext[0]` back for the second element,
which is now `ext[1]` too: the swap gives `{ ext[1], ext[1] }`, in every
build mode, with no diagnostic. The same goes for a shift
(`d.rate = .{ new, d.rate[0] }`), a rotate, and a struct swap
(`p = .{ .x = p.y, .y = p.x }`). A typed initializer, `P{...}` or
`[_]T{...}`, is built aside and then copied, so it is safe and not
reported.

The fix is to copy the old value first and read the copy, or to assign the
fields one at a time, each read before it is overwritten.

### What alias reports

An element of an anonymous initializer assigned with `=` that reads, by the
same path, a field or literal index an earlier element stored (by field name,
in the order written, or by position), or reads the whole place, or a part
of it holding a stored slot (`f(p.*)`), after an element has stored into it.
Nested anonymous initializers are followed field by field.

Not reported: an element reading the slot it is about to store, which is
fine and common (`lo = .{ .x = @min(lo.x, q.x), .y = @min(lo.y, q.y) }`);
an index that is not a literal, which could be either; and reads of no
memory of the place: its address (`&p.step`), the pointer it is reached
through (`.owner = b` in `b.* = .{...}`), anything shorter than it, which
may be such a pointer, a `return`, and compile-time builtins such as
`@sizeOf`. Two names for the same memory are out of reach.

Nor are two shapes that read what was stored on purpose: a slot stored with
what it holds already (`.superblock = self.superblock`), which reads the
same afterwards; and a whole struct given its fields by name, none of them
read from what it held, which is being made afresh, so that
`self.* = .{ .arena = .init(gpa), .allocator = self.arena.allocator() }`
reads back the field it has just set because that is the one it means. A
swap or shift reads what the place held, by position, by name, or into
part of a struct, and is still reported.

## Rule three: cancel

In a task's loop, an `Io` call whose error is dropped with `catch {}` or
`catch continue`.

```zig
fn worker(io: Io) void {
    while (true) {
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}
```

`std.Io` delivers a cancelation request once: the next cancelation point
returns `error.Canceled`, and later ones succeed. `catch {}` takes that one
error and drops it, so the loop runs on, and whoever called `cancel` on the
task waits for good. It compiles clean in every build mode, and nothing at
run time says why the cancel never returns.

The fix, if the call's error set holds `error.Canceled`, is to return it:

```zig
line.writeStreamingAll(io, bytes) catch |err| switch (err) {
    error.Canceled => |e| return e,
    else => {},
};
```

or to call `io.recancel()` after handling it.

### What cancel reports

The same `catch {}` in code nothing cancels is harmless, and most of it is
in search, cleanup and test loops. What the syntax can see is where a task
starts, so cancel looks only in a function handed to `async` or
`concurrent` (`io.concurrent(worker, ...)`, `group.async(io, handle, ...)`),
or one such a function calls directly, in the same file, and only in its
loops. Reported there: `catch {}`, `catch |_| {}` or `catch continue` on a
call passed `io` or a field named `io`, or called on one.

And in a function a task calls inside one of its loops, a handler that
names `error.Canceled` and leaves without it:
`catch |err| { if (err == error.Canceled) return; ... }`, or a
`switch (err)` prong `error.Canceled => return` or `=> {}`. Leaving that
function returns to the task's loop, which goes on with the cancel spent,
and naming the error shows the call can return it, whatever its name.

Not reported: `cancel` and `await`, which drop the task's own result, not a
cancelation sent to it; anything in a `defer` or `errdefer`; handlers that
use the error or leave (`catch return`, `catch null`); and a task started
from another file, which the syntax of this one cannot see. Whether the
call's error set holds `error.Canceled` is beyond the syntax too; the hint
says how to tell. Of the handlers that name it: one that calls
`io.recancel()`, returns a value the loop may read (`while (tick())`), or
hands the error on (`error.Canceled => |e| return e`), and the same
handler in the task's own function, where returning ends the task.

## Rule four: fit

A float printed in full into a buffer too small for it, with the error
asserted away.

```zig
fn printNumber(gpa: Allocator, out: *std.ArrayList(u8), v: f64) !void {
    var buf: [48]u8 = undefined;
    try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
}
```

`{d}` on a float never switches to scientific notation: 1e40 prints as 41
digits, the largest f64 as 309, and its smallest subnormal, negative, as
327 bytes. So for `v = 1e60` bufPrint returns error.NoSpaceLeft, and
`catch unreachable`, which says it cannot, turns that into a panic in
Debug and ReleaseSafe and undefined behavior in ReleaseFast and
ReleaseSmall, with no diagnostic in any mode. 48 bytes reads as a fair
size because it is one for an integer, which is at most 20 digits. A chart
library shipped this, reachable from any number in its data.

The fix is one of: print with `{e}`, which needs at most 24 bytes for an
f64; size the buffer for the worst case; or handle the error, with `try`
or a fallback such as `catch "?"` into a `[]const u8`.

### What fit reports

`std.mem.print` or `printSentinel`, or `std.fmt.bufPrint` or
`bufPrintSentinel`, which 0.17.0 keeps for them, under `catch unreachable`,
printing an f16, f32 or f64 with `{d}`, `{}` or `{any}` (fill, width,
precision and `{?d}` included) into a buffer smaller than the most that
can print: 11, 48 and 327 bytes, or with a precision of n digits, 6, 40
and 310 bytes and then a point and n. The buffer's length has to be in the
syntax: `&buf` or `buf[0..]` with `buf: [N]u8`, or `buf` with
`buf: *[N]u8`, where N is a literal, a container-level constant, or
`std.fmt.float.min_buffer_size` (53, which is too small). So does the
value's type: a parameter, local, capture or container-level variable
declared `f16`, `f32` or `f64`, or such a field of a struct the file
declares, found the way escape finds types.

Not reported: a value bounded before it is printed, where any comparison
of it (`<`, `<=`, `>`, `>=`), or `@min`, `@max` or `clamp` of it, or of a
local made from it, earlier in the function counts as a bound, since a
bound can take many shapes; one made from an integer with
`@floatFromInt`, which prints no longer than the integer; a constant whose
value is a literal; and a float whose type is not written (`anytype`, an
untyped local) or is declared in another file, or is an f80 or f128.

## Rule five: refill

A place freed, then given new memory by something that can fail first.

```zig
fn resize(self: *Rows, n: usize) !void {
    self.gpa.free(self.items);
    self.items = try self.gpa.alloc(u32, n);
}
```

When the `try` fails, the store never happens: `self.items` still holds
what was just freed, and the error goes back to a caller that still owns
`self`. Its `deinit` frees it again, and anything that reads it first reads
freed memory. It compiles clean in every build mode and reads naturally,
free the old and make the new, and it goes wrong only when an allocation
fails, the path tests seldom take: the debugging allocator says "double
free" when a test makes that allocation fail, and a release build corrupts
the heap and says nothing. Zig 0.17.0's standard library has two, in
`std.Io.Threaded`'s Windows command line cache and in
`std.compress.lzma`'s decoder reset.

The fix is to make the new value first, then free the old one and store
the new, so a failure leaves the old value in place:

```zig
const items = try self.gpa.alloc(u32, n);
self.gpa.free(self.items);
self.items = items;
```

### What refill reports

`x.free(place)`, `x.destroy(place)`, `x.rawFree(place, ...)` or
`place.deinit(...)`, or a call to one of the file's own functions that
frees the parameter the place is passed to (`self.destroyLocal(self.one)`,
where a statement of `destroyLocal` frees `local` or a field of it), as a
statement or the body of an `if` with no `else`, or
`if (place) |old| x.free(old)`, where the place is a field or what a
pointer points at (`self.items`, `a.*`), and a later statement of the same
block stores to the place, or to what holds it written whole
(`history.* = .{ ... }`), with something that can fail first: a `try`, or
a `catch` or `orelse` that returns (`orelse return error.OutOfMemory`), in
the stored value or in a statement between.

Not reported: a place reset first (`self.items = &.{}`, or a store into it
such as `self.items.len = 0`), reset by an `errdefer` or by the `catch` or
`orelse` that handles the failure
(`catch |err| { self.name = null; return err; }`), or perhaps reset by a
call between that is handed what holds it (`self.clear()`), when nothing
that can fail comes before that call; a field of a `var` local not
declared as a pointer, which holds a struct by value that the failing
function throws away; and a bare local, which an `errdefer` of its own can
cover.

## Rule six: owner

One allocation freed by two errdefers: the caller's, and the one in the
function it hands the allocation to.

```zig
/// Takes `bytes`, even when it fails.
fn keep(self: *Store, bytes: []u8) !void {
    errdefer self.gpa.free(bytes);
    try self.kept.append(self.gpa, bytes);
}

fn save(self: *Store, text: []const u8) !void {
    const bytes = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(bytes);
    try self.keep(bytes);
}
```

`keep` frees `bytes` itself when it fails. So when `append` fails, both
errdefers run, `keep`'s and then `save`'s, and the second frees freed
memory. It compiles clean in every build mode, and each function reads
correctly on its own, which is why review passes it: the bug is where the
two meet. The debugging allocator says "double free" only when a test makes
that allocation fail; a release build corrupts the heap and says nothing.

The fix is to free it in one place: drop the caller's errdefer, or have the
callee leave the allocation to its caller when it fails.

### What owner reports

A call under `try` to one of the file's own functions that takes a
parameter on failure, where the argument for that parameter is a name that
an `errdefer` of the caller, declared before the call in a block around it,
frees, or carries one: its address (`&list`), or a field of an
initializer, as deep as they nest (`.{ .state = .{ .items = items } }`).
A function takes a parameter on failure when an `errdefer` in it frees
the parameter (`x.free(p)`, `x.destroy(p)`, `x.rawFree(p, ...)` or
`p.deinit(...)`) and something after it can fail: a `try` or a
`return error.X`. It takes it too when it releases the parameter itself,
or a local copy of it, by hand or in a `defer`, with one of those calls or
with a call whose name says it releases, handed it as its only argument or
one after the first, and fails after that on its path:

```zig
fn push(frames: *std.ArrayList(Frame), frame: Frame) !void {
    var pushed = frame;
    frames.append(gpa, pushed) catch |err| {
        release(&pushed); // frees the frame's components
        return err;
    };
}
```

A caller that frees the components in an errdefer and hands them to
`push` in a frame frees them twice when the append fails. The function is
found by name, through its type (`Store.keep(s, b)`), or as a method of a
binding whose type the file declares (`self.keep(b)`).

Not reported: a call whose error is handled rather than returned with
`try`, which only the caller can judge; an `errdefer` declared after the
call; an argument that neither is a name nor carries one; a release of
something reached through the parameter (`self.list.deinit()`), which is
not what the caller frees; a method's receiver, or the first of several
arguments, for a call recognized only by its name
(`releasePages(pool, pages)` releases into `pool`); a release that leaves
the value empty (`clearAndFree`), or one followed by an assignment to it;
and a function declared in another file.

## Rule seven: kept

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
says nothing. It is the third shape of one mistake, after refill and owner:
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

### What kept reports

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

## Rule eight: torn

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
a field at a time, as alias explains, and an optional reads as set, or a
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

### What torn reports

An assignment of a struct or array initializer, through parentheses and
`@as`, with a `try`, or a `catch` or `orelse` that returns, in one of its
fields or elements, as deep as initializers nest, to a field whose type
the file declares as an optional or a union, reached as kept's stores are
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

## Rule nine: twice

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
looks like the author making sure. Unlike refill and owner it needs no
allocation to fail: any input that takes the refusing path frees twice,
though such paths (a library refusing a config, a platform call failing)
are often ones tests do not reach. An agent wrote this in a Kafka
client's librdkafka binding, where a refused config freed the handle's
state twice.

The fix is to drop the hand-written free and let the errdefer do it.

### What twice reports

An `errdefer` whose call releases by its name (a `free`, `destroy`,
`deinit`, `close`, `unmap` or `release` of some kind: `gpa.free`,
`closeHandle`, `deinitAll`), and the same call, but for whitespace,
written as a statement after it in its block, not in a `defer` or
`errdefer`, followed on its path by something that makes the function
fail: a `try`, a `return error.X`, or a `return` of what a `catch` caught.

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

## Rule ten: sweep

A loop that frees what a list holds, can fail part way, and empties the
list only after it.

```zig
for (self.queue.items) |m| {
    try self.send(m); // fails on a later turn: earlier turns' are freed and still held
    self.gpa.free(m);
}
self.queue.clearRetainingCapacity();
```

When `send` fails on the third message, the first two are freed, the
`clearRetainingCapacity` never runs, and the queue still holds them: the
next flush sends freed memory and frees it again, and `deinit` frees it
once more. It compiles clean in every build mode and reads as tidy code,
free each, then clear. It is refill's mistake in a loop: freed, then a
failure before the place is reset. An agent wrote it in a UI framework's
image store, where a review found it.

The fix is to take each out of the list as it is freed
(`while (q.held.pop()) |m|`), or to empty the list before the loop and
free what it held.

### What sweep reports

A `for` over `p.items`, or a slice of it, where `p` is reached as kept's
stores are, whose body frees what the loop's capture holds
(`x.free(e)`, `x.destroy(e)`, `x.rawFree(e, ...)` or `e.deinit(...)`, with
`e` the capture, reached through it, or captured from it by a `switch` or
an `if`) and can fail (a `try`, or a `catch` or `orelse` that returns), so
a later turn fails after an earlier turn's free, when `p` is emptied after
the loop (`clearRetainingCapacity`, `clearAndFree`,
`shrinkRetainingCapacity`, `shrinkAndFree`, or `p.items.len = ...`).

Not reported: a list taken apart as it is freed (`swapRemove`,
`orderedRemove` or `pop` on it in the loop); a list a local holds; and a
list an `errdefer` before the loop resets.

## Rule eleven: unlock

A lock taken, then something that can fail before the unlock, with no
`defer` to unlock it.

```zig
try self.pool_mut.lock(io);
const conn = try self.pool.create(self.allocator); // fails: the function returns holding the lock
self.pool_mut.unlock(io);
```

When `create` fails, the error leaves the function with the mutex still
held, and the next `lock` waits for good. It compiles clean in every build
mode and goes wrong only when the step between fails, the path tests
seldom take, and nothing at run time says why the program hangs. An HTTP
server library's connection pool has this exact code.

The fix is `defer self.pool_mut.unlock(io);` straight after the lock.

### What unlock reports

`x.lock(...)`, `x.lockUncancelable(...)`, `x.lockShared(...)` or
`x.lockSharedUncancelable(...)` as a statement, or under `try`, then
`x.unlock(...)` (or `x.unlockShared(...)`) later in the same block, `x`
the same as written, and between them something that fails with an error:
a `try`, a `return error.X`, or a `return` of what a `catch` caught, on a
path that does not unlock first.

Not reported: a lock a `defer` or `errdefer` unlocks before the failure,
however it is written (`defer if (!unlocked) m.unlock();`); a plain
`return` between, since a function may return holding the lock on
purpose; the lock call's own `catch`; and code in a `test` block, where a
failure ends the test.

## Rule twelve: wipe

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

### What wipe reports

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

## Rule thirteen: freed

A function returns what its own `defer` frees.

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(gpa);
try list.appendSlice(gpa, a);
return list.items; // freed before the caller gets it
```

The `defer` runs after the return value is made and before the caller
gets it, so the caller always gets freed memory. It compiles clean in
every build mode. The debugging allocator writes over what it frees, so a
test that reads the result finds `UUUU` where it wrote `abcd`; a function
no test reads hands freed memory on, and a release build reads whatever
the allocator put there next.

The fix is to hand the memory over: `return list.toOwnedSlice(gpa);`,
which empties the list so the `defer` frees nothing, or an `errdefer` in
place of the `defer`.

### What freed reports

`defer x.deinit(...)`, `defer a.free(x)`, `defer a.destroy(x)` or
`defer a.rawFree(x, ...)`, where `x` is a name or a field of one
(`self.list`), then a `return` later in the same block, before anything
assigns to `x` or to what holds it, whose value is a view of `x`: `x`
itself, `x.items`, `.ptr` of a view, a slice or `&` of an element of one,
`x.written()`, `x.keys()`, `x.values()` or `x.slice()`, a `std.mem` or
`std.fmt` call that returns part of its argument
(`std.mem.trim(u8, x.items, " ")`), a cast of one, an initializer with one
as a field, or a branch of an `if` or `switch` that gives one.

Not reported: a call that takes `x` and returns something else
(`return parse(x.items)`, `return gpa.dupe(u8, x.items)`) or hands it over
(`toOwnedSlice`); a length or an element read out of it; an `errdefer`, or
a `defer` behind an `if`, which may not free on this path; and a `return`
after an assignment to `x`.

## Rule fourteen: grow

A pointer into a list's items, kept across a call that can move them.

```zig
const first = &list.items[0];
try list.append(gpa, x);
first.* = 7; // append moved the items when the list was full
```

`append` reallocates when the list has no room, and `first` is left
pointing at freed memory. The same holds for `getPtr`, or `getOrPut`'s
`value_ptr`, kept across a `put` on the same map, and for a `for` over
`list.items` whose body appends to `list`: the loop took the slice once
and walks on through the old memory. It compiles clean in every build
mode, and it works whenever the list happened to have room, which is most
test runs: 100 appends leave the pointer valid, 10,000 do not.

The fix is to keep the index and take the pointer again after the growth,
or to reserve with `ensureUnusedCapacity` first and grow with
`appendAssumeCapacity`, which cannot move anything.

### What grow reports

A pointer local made with `&x.items[...]`, `x.items` or a slice of it,
`x.addOne(...)` and its kind when the file shows `x` is an `ArrayList`, or
`x.getPtr(...)`, `x.getOrPut(...)`, `x.getEntry(...)` and their kind when
it shows `x` is a hash map; what an `if` captures from such a `getPtr`; or
a `for` over `x.items` or a slice of it. Then a call on the same `x` that
can reallocate (`append`, `appendSlice`, `insert`, `addOne`, `resize`,
`ensureTotalCapacity` and the rest for a list; `put`, `getOrPut`,
`fetchPut`, `ensureTotalCapacity` and the rest for a map), and on a path
after it a use of the pointer, or the `for`'s next turn: later in the same
block, after the loop or block a `break` leaves, or on the next turn of a
loop around the call that the pointer was declared outside of.

Not reported: the `AssumeCapacity` calls; a use in another branch of the
`if` or another prong of the `switch` the call is in, or after a
`continue` to a loop the pointer is declared in, which takes it again; a
call that comes, on every path from the pointer, after the list or map, or
what holds it, is stored again (`s.list = saved;`, `list.* = .empty;`),
which grows what was stored; a pointer taken again before the use; a
length, `found_existing` or `index` read out of it, which are copies; a
`getOrPut` that makes a new entry only on a path that leaves at once, when
a `getOrPut` made the pointer and so left a free slot; a list or map
handed to a call, which only the callee can judge; and a type the file
does not show, such as `std.SegmentedList`, whose elements never move.

## Rule fifteen: copy

A `std.Io.Writer` or `Reader` interface copied out of the struct its
methods find with `@fieldParentPtr`.

```zig
var aw: std.Io.Writer.Allocating = .init(gpa);
defer aw.deinit();
var w = aw.writer;       // a copy
try w.writeAll("hello"); // the drain looks for `aw` around `w`
```

The implementations get back to themselves from the interface's address:
`Allocating` with `@fieldParentPtr("writer", w)`, `File.Writer` with
`@fieldParentPtr("interface", w)`. So the interface works only where it
is, through `&aw.writer` or `&file_writer.interface`. A copy compiles clean
in every build mode and works until the first drain, a flush or a full
buffer, which reads whatever sits next to the copy as if it were the
parent: the code above crashes reading an allocator's `vtable` off the
stack. The old `std.io` writers were plain values that copied freely,
which is the code this looks like.

The fix is a pointer: `const w = &aw.writer;`.

### What copy reports

`x.f` read as a value, where `f` is the interface field of `x`'s type: the
initializer of a local, the value of an assignment or of a named field of
an initializer, a `return` value, or an argument to one of the file's own
functions whose parameter takes a `Writer` or `Reader` by value. `x`'s type
is one the file shows, written or made by `x`'s initializer: `File.Writer`,
`File.Reader`, `Stream.Writer`, `Stream.Reader` and `Reader.Limited`
(`interface`); `Writer.Allocating`, `Writer.Discarding`, `Writer.Hashing`,
`Writer.Hashed` and `flate.Compress` (`writer`); `Reader.Hashed` and the
`Decompress` types (`reader`); and `tls.Client` (both). A local made by a
call to a method named `writer`, `writerStreaming`, `reader` or
`readerStreaming` (`file.writer(io, &buf)`) counts as a `File.Writer` or
`File.Reader`.

Not reported: `&x.f`; a method called on it (`x.f.print(...)`), which
takes its address; a field read out of it; a field that is itself a
pointer, as `Io.Terminal`'s `writer` is, which copies fine; and a type the
file does not show.

## Rule sixteen: flush

A buffered file or stream writer, written to and never flushed.

```zig
var buf: [256]u8 = undefined;
var fw = std.Io.File.stdout().writerStreaming(io, &buf);
try fw.interface.print("hello from greet\n", .{});
```

The writer collects what it is given in `buf`, and only `flush` (or
`end`, for a file) sends it on. Here the function returns, `fw` goes with
it, and the line is never written. It compiles clean in every build mode,
prints nothing and reports nothing. A command that prints why it failed to
a buffered stderr and then returns 1 exits with the right status and no
message; one that prints more than the buffer holds loses only the last
part. Code in the shape of the old API, where `std.io.getStdOut().writer()`
wrote straight through, reads the same.

The fix is `try fw.interface.flush();` after the last write, or
`try fw.end();` for a file.

### What flush reports

A `var` local made by a call to a method named `writer` or
`writerStreaming`, or by `File.Writer.init` or `.initStreaming`, whose last
argument, the buffer, is not `&.{}`, and written through its `interface`
later: a call on `fw.interface`, or on a local made with `&fw.interface`,
other than `flush`. It is reported at the declaration when nothing after
it in its block flushes it (`fw.interface.flush()`, `w.flush()` through
such a local, or the writer's own `fw.flush()` or `fw.end()`, in a `defer`
or not) or hands it on: `&fw`, `&fw.interface` or such a local passed to a
call, stored, or returned.

Not reported: an unbuffered writer (`&.{}`), which writes straight
through; `Allocating` and `fixed` writers, whose buffer is the result; a
reader; and a writer handed to a call, which only the callee can judge.

## Rule seventeen: cached

A build script that lists a directory to decide what to build, and never
tells Zig's configure cache.

```zig
var dir = try b.root.openDir(b.graph.io, "test", .{ .iterate = true });
defer dir.close(b.graph.io);
var it = dir.iterate();
while (try it.next(b.graph.io)) |entry| { ... } // one addTest per file
```

Zig 0.17 caches the configure phase: when nothing it tracks has changed,
`zig build` reuses the last build graph without running `build()`. A file
added to `test/` changes nothing it tracks, so its test is never built,
and `zig build test` passes without running it, until something else
invalidates the cache: an edit to `build.zig`, a new option. It compiles
clean in every build mode, and works on every run that configures anew,
such as the first one after a clone.

The fix is `b.dependOnDirectoryContents(b.path("test"));` next to the
`openDir`, which makes the directory's entries something the cache tracks,
or `b.graph.poisonCache()`, which turns the cache off for the build.
`dependOnDirectoryContents` is not recursive: a `walk` needs one for each
directory it enters as well.

### What cached reports

A call to `openDir` with `.iterate = true` in its options and `b.root` in
it, in a function with a `*std.Build` parameter `b`: `b.root.openDir(...)`,
`b.root.root_dir.handle.openDir(...)`, or
`cwd().openDir(io, try b.root.joinString(...), ...)`. It is reported when
the function calls none of `dependOnDirectoryContents`,
`dependOnDirectoryMetadata` and `poisonCache`; or, when it also calls
`walk` or `walkSelectively`, which go into subdirectories, when no
`dependOnDirectory...` call of it is in a loop, as one for each directory
the walk enters is.

Not reported: `b.build_root`, the field of a Zig before 0.17, whose
configure phase always runs; a directory opened by another path
(`cwd().openDir(io, "test", ...)`, `openDirAbsolute`), which the syntax
cannot place in the build root or a Zig version; and a dependency the
caller declares, which only the caller shows.

## Install

With Homebrew, on macOS or Linux:

```sh
brew install kmoneil/tap/zigvet
```

With Scoop, on Windows:

```powershell
scoop bucket add kmoneil https://github.com/kmoneil/scoop-bucket
scoop install kmoneil/zigvet
```

Both move to each release by themselves, after checking every file's build
provenance and installing it. Or download a binary yourself: each
[release](https://github.com/kmoneil/zigvet/releases) carries a binary
for Linux, macOS and Windows on x86-64 and arm64, named
`zigvet-<linux|darwin|windows>-<amd64|arm64>` (`.exe` on Windows), with
`SHA256SUMS` and a build-provenance attestation for every file. On an
Apple-silicon Mac, for example:

```sh
curl -fLO https://github.com/kmoneil/zigvet/releases/latest/download/zigvet-darwin-arm64
curl -fLO https://github.com/kmoneil/zigvet/releases/latest/download/SHA256SUMS
shasum -a 256 --check --ignore-missing SHA256SUMS
gh attestation verify zigvet-darwin-arm64 --repo kmoneil/zigvet
chmod +x zigvet-darwin-arm64 && mv zigvet-darwin-arm64 /usr/local/bin/zigvet
```

A binary downloaded with a browser on macOS is quarantined; clear it with
`xattr -d com.apple.quarantine zigvet`. `curl` does not set the flag.

From v0.2.1 on, releases are also reproducible: a tag built with Zig 0.17.0
from ziglang.org gives the same bytes wherever it is built, so a release
can be checked without trusting the workflow that made it. CI builds every
change on Linux and on macOS and compares them. To check one yourself:

```sh
git clone --depth 1 --branch <tag> https://github.com/kmoneil/zigvet && cd zigvet
zig build release && cd zig-out/release
curl -fLO https://github.com/kmoneil/zigvet/releases/download/<tag>/SHA256SUMS
shasum -a 256 --check SHA256SUMS
```

It takes Zig as ziglang.org ships it: a Zig built against another LLVM,
such as Homebrew's, writes its linker's name into the Linux binaries, so
those two differ while the macOS and Windows ones still match. The release
binaries carry no debug info, since it holds the paths of the machine that
built them, so a panic prints its message but not a symbolized stack trace.

From source, with Zig 0.17.0: `zig build -Doptimize=ReleaseSafe`, which
leaves the binary in `zig-out/bin/`.

## Usage

```
zigvet [--exclude <path>]... [--format <text|github|json>] [--summary] <path>...
zigvet --version
```

A file is checked whatever its extension. A directory is walked for `.zig`
files, skipping hidden directories, `zig-out` and `zig-pkg`. Paths print
cleaned (`./src/a.zig` as `src/a.zig`), and a file reached more than one
way is checked once. A file that does not parse is reported with the error
`zig ast-check` gives for it.

`--exclude <path>` skips a file or directory, and may be given more than
once. It is matched against paths as zigvet prints them, so name it
relative to the current directory: `zigvet . --exclude _tmp` leaves out a
scratch directory, or a second worktree checked out inside it.

`--summary` ends the run with one line on stderr, in every format, saying
how many files were checked and what each rule reported:

```
zigvet: checked 354 files, no findings
zigvet: checked 41 files, 3 findings (escape 1, refill 2)
```

It is off by default, so a clean run prints nothing, as `zig fmt --check`
does, and a lint step in a build stays quiet. Turn it on where a zero has
to be trusted, such as CI after an upgrade: it tells a run over 354 files
from a run over 3.

Exit status: 0 if nothing was reported, 1 if a finding or parse error was,
2 on a usage error or a path that could not be read or holds no `.zig` file
to check. So a lint step aimed at a directory whose Zig has moved fails
rather than passing with nothing checked.

## Output

```
path:line:col: escape: <what> made here leaves <function> through <return | field | global | out param>
    hint: <one line on how to fix it>
```

or, for a loop's capture stored to a local declared outside the loop,
`<what> made here leaves its turn of the loop through local '<name>'`.

Findings go to stdout, in path order and then source order. An allow
comment that suppresses nothing (below) is reported the same way, with
`allow` in the rule's place.

For CI, `--format github` writes each report as a GitHub Actions workflow
command instead, so it lands on the pull request's diff:

```
::error file=src/kms/fake_kms.zig,line=1297,col=54,title=zigvet escape::result of a call made here leaves rawOf through return. hint: return the value itself, have the caller pass in the memory, or allocate it
```

and `--format json` writes one JSON array, an object per report, for other
tools:

```json
[
{"path":"src/a.zig","line":2,"column":12,"rule":"escape","message":"anonymous array made here leaves f through return","hint":"make it comptime-known (`comptime` on the runtime elements) or a container-level const"}
]
```

`rule` is the rule's name, `allow` for an allow comment that suppresses
nothing, or `error` for a parse error, which has no hint (`null`). The
reports, their order and the exit status are the same in every format;
a message about the run itself, such as a path that could not be read,
goes to stderr as text.

## Allowing a report

For a report zigvet gets wrong, say so in the comment lines directly above
the reported line, naming the rule and giving a reason:

```zig
// zigvet: allow escape only called at comptime, from the build script
return &.{Scope.monitoring.url()};
```

The reason is required; an allow comment without one suppresses nothing.

Every allow comment has to suppress something. One that does not is
reported itself, with why: nothing on the line below breaks its rule any
more, it names no rule zigvet has, it gives no reason, or it sits at the end
of the line it means instead of above it. It counts toward the exit status
like a finding, so an allow cannot outlive the code it excused and then
excuse whatever is written there next.

## Use it in a build

Add zigvet to `build.zig.zon`, pinned to a release tag, with `zig fetch
--save git+https://github.com/kmoneil/zigvet#v0.11.0`, then give `build.zig`
a lint step, the way `zig fmt --check` is used:

```zig
const zigvet = b.dependency("zigvet", .{
    .target = b.graph.host,
    .optimize = .ReleaseSafe,
});
const vet = b.addRunArtifact(zigvet.artifact("zigvet"));
vet.setCwd(b.path("."));
vet.addArgs(&.{"src"});
b.step("lint", "Report code that compiles but is wrong").dependOn(&vet.step);
```

`zig build lint` then fails when zigvet reports anything. zigvet's own
`zig build lint` is the same step run over its `src/`.

## Clobber the stack in tests

A function that returns a slice of its own frame passes a test that reads
the slice straight away, because nothing has written over that memory yet.
That is how the bug above passed its test for two days. `clobberStack()`
writes over the stack the returned frame used, so the same test fails at
once:

```zig
const zigvet = @import("zigvet");

test "scopesFor asks for read-only Monitoring" {
    const got = Auth.scopesFor(.monitoring, &asked);
    zigvet.clobberStack();
    try std.testing.expectEqualStrings(monitoring_read_url, got[0]);
}
```

Give the test module the import in `build.zig`, from the same dependency as
the lint step:

```zig
tests.root_module.addImport("zigvet", zigvet.module("zigvet"));
```

Since v0.2.0. It finds the bug only in
a function a test calls, and is dependable only in a Debug build (the
default for `zig build test`): an optimized build may turn a read of a dead
frame into anything. The escape rule finds the shapes it knows in any
function, so the two are worth having together.

## What a rule has to be

The admission test: the code compiles clean in every build mode and is still
wrong. If the compiler, `zig fmt` or an existing linter already catches it, it
is not a zigvet rule. Code that is right but larger or slower than it could
be is out of scope as well: what it costs depends on the build mode and on
how many times it is instantiated, which the syntax does not show and a
profiler of the built program does (#30). Each rule is one lowercase word
for what it catches: `escape`, `alias`, `cancel`, `fit`, `refill`,
`owner`, `kept`, `torn`, `twice`, `sweep`, `unlock`, `wipe`, `freed`,
`grow`, `copy`, `flush` and `cached` so far.

## Tests

`zig build test` runs the unit tests and the case corpus in `test/cases/`.
The cases use the form of the Zig compiler's own `test/cases/`: source,
then `// error` and the expected `// :line:col: error: ...` lines, or
`// compile` for code that must not be reported. The run also compiles
every case with the Zig compiler and fails if it rejects one, so each case
is checked to be code Zig accepts. If a later Zig release starts catching a
shape, its case fails and the rule should drop it.

`scripts/corpus-diff.sh` runs two builds of zigvet over the same
directories, by default the latest tag and the working tree, and prints
only the reports that differ, with each build's time. Run it before a rule
change lands: over code that holds no new bug, the change should add
nothing but the reports it was written for. List the directories in
`corpus.txt` at the repository root (gitignored, one per line) or give them
as arguments; `--base` and `--head` each take a git ref or a zigvet binary.

`scripts/wild-corpus.sh` keeps shallow clones of fourteen well-known public
Zig projects (Ghostty, TigerBeetle, ZLS, Roc and others) in `.wild/`, which
git ignores and the walk skips, and prints their directories, so a rule is
also measured on code nobody here wrote:
`scripts/corpus-diff.sh --base main $(scripts/wild-corpus.sh)`. A clone
already there is used as it is; `--update` fetches each project's latest
commit.

## License

Apache-2.0; see [LICENSE](LICENSE).
