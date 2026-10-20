# zigvet

Things Zig compiles that are wrong.

`zigvet [paths...]` parses every `.zig` file with `std.zig.Ast`, the
compiler's own parser, and reports code the compiler accepts in every build
mode that is almost certainly a bug. `go vet` is the closest analog: not
style, which the existing linters cover, but silent wrongness.

Status: three rules. Escape, run over the 0.17.0 standard library and
compiler sources (650,000 lines) and four application repos, found two real
defects and three of its one accepted kind of false positive (below). Alias,
run over the same standard library and seven application repos, found one
real defect and no false positive. Cancel, over the same code, found one
real defect and one harmless case, a test's task that nothing cancels.

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
- the address of a local, parameter or capture, a slice of a local array, or
  the address of one field or element of a local held by value.

Leaving the function:

- returned, directly or through `if`, `switch`, `orelse`, `catch`, `try`, a
  labeled block, a cast, a struct returned by value, a local that holds it,
  or a `std` call that returns part of its argument
  (`std.fmt.bufPrint(&buf, ...)`, `std.mem.trim(u8, &buf, " ")`);
- stored through a parameter (`self.items = ...`, `out.* = ...`) or to a
  container-level variable. Stores report temporaries only: a named local
  stored outward is usually deliberate (a context pointer for the length of
  a call, a thread's `current`), and a store a `defer` undoes is not
  reported at all.

Comptime-known memory is static and never reported: literals, `comptime`
expressions, container-level declarations, `comptime` parameters, and calls
to an `inline fn` (or one returning a comptime-only type) with comptime-known
arguments. The check reads one function at a time and the syntax alone, so
it knows a callee only by name: the file's own functions,
`std.fmt.comptimePrint`, `std.math.maxInt` and `minInt`, and as returning
part of an argument, `std.fmt`'s `bufPrint` and `bufPrintSentinel` and
`std.mem`'s `sliceTo`, `span`, `trim`, `trimStart`, `trimEnd`, `cutPrefix`,
`cutSuffix`, `asBytes`, `sliceAsBytes`, `bytesAsSlice` and `bytesAsValue`.
A function whose
return type only comptime has (`type`, `comptime_int`, `comptime_float`, or
a pointer, slice, array, optional or error union of one, such as
`[]const type`) runs only at compile time, and is not checked.

The one accepted false positive is any other function only ever run at
compile time, where the address is comptime memory and legal. Say so with a
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

From source, with Zig 0.17.0: `zig build -Doptimize=ReleaseSafe`, which
leaves the binary in `zig-out/bin/`.

## Usage

```
zigvet [--exclude <path>]... [--format <text|github|json>] <path>...
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

Exit status: 0 if nothing was reported, 1 if a finding or parse error was,
2 on a usage error or a path that could not be read or holds no `.zig` file
to check. So a lint step aimed at a directory whose Zig has moved fails
rather than passing with nothing checked.

## Output

```
path:line:col: escape: <what> made here leaves <function> through <return | field | global | out param>
    hint: <one line on how to fix it>
```

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
--save git+https://github.com/kmoneil/zigvet#v0.2.0`, then give `build.zig`
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
is not a zigvet rule. Each rule is one lowercase word for what it catches:
`escape`, `alias` and `cancel` so far.

## Tests

`zig build test` runs the unit tests and the case corpus in `test/cases/`.
The cases use the form of the Zig compiler's own `test/cases/`: source,
then `// error` and the expected `// :line:col: error: ...` lines, or
`// compile` for code that must not be reported. The run also compiles
every case with the Zig compiler and fails if it rejects one, so each case
is checked to be code Zig accepts. If a later Zig release starts catching a
shape, its case fails and the rule should drop it.

## License

Apache-2.0; see [LICENSE](LICENSE).
