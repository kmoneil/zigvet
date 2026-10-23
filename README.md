# zigvet

Things Zig compiles that are wrong.

`zigvet [paths...]` parses every `.zig` file with `std.zig.Ast`, the
compiler's own parser, and reports code the compiler accepts in every build
mode that is almost certainly a bug. `go vet` is the closest analog: not
style, which the existing linters cover, but silent wrongness.

Status: six rules. Escape, run over the 0.17.0 standard library and
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
of them another keeps.

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
  value and `fn slice(self: *const Id) []const u8 { return self.bytes[0..self.len]; }`;
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
or the address of one of its fields. A type is known only when the file
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

Not reported: `cancel` and `await`, which drop the task's own result, not a
cancelation sent to it; anything in a `defer` or `errdefer`; handlers that
use the error or leave (`catch return`, `catch null`); and a task started
from another file, which the syntax of this one cannot see. Whether the
call's error set holds `error.Canceled` is beyond the syntax too; the hint
says how to tell.

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
frees. A function takes a parameter on failure when an `errdefer` in it
frees the parameter (`x.free(p)`, `x.destroy(p)`, `x.rawFree(p, ...)` or
`p.deinit(...)`) and something after it can fail: a `try` or a
`return error.X`. The function is found by name, through its type
(`Store.keep(s, b)`), or as a method of a binding whose type the file
declares (`self.keep(b)`).

Not reported: a call whose error is handled rather than returned with
`try`, which only the caller can judge; an `errdefer` declared after the
call; an argument that is not a plain name; and a function declared in
another file.

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
--save git+https://github.com/kmoneil/zigvet#v0.6.0`, then give `build.zig`
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
for what it catches: `escape`, `alias`, `cancel`, `fit`, `refill` and
`owner` so far.

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
