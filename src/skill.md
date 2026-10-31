---
name: zigvet
description: Finds Zig code that compiles clean in every build mode and is still wrong (stack memory handed back to the caller, double frees, leaks and held locks on error paths, writers never flushed, tests that never run) and says how to fix each. Use after writing or changing Zig code and before calling it done, when a zigvet finding needs reading, fixing, allowing or reporting, and when adding a lint step to a build.zig.
---

# zigvet: Zig that compiles and is wrong

zigvet reads Zig source with the compiler's own parser, with no build and
no configuration, and reports code the compiler accepts in every build
mode that is almost certainly a bug. It reads Zig's standard library and
compiler in under a second, so run it after every change.

Every rule is a bug that passes tests: it goes wrong on an error path
tests seldom take, in memory nothing has written over yet, or in a
release build only. A passing test is no sign a finding is wrong.

## The loop

Run it from the project's root, over everything that holds Zig:
`zigvet .`, or `zigvet build.zig src`. Silence and exit 0 mean nothing
was found.
Each finding says where, which rule, and what is wrong, and on the next
line how to fix it:

```console
$ zigvet src
src/auth.zig:2:28: escape: anonymous array made here leaves scopes through return
    hint: make it comptime-known (`comptime` on the runtime elements) or a container-level const
```

Read the rule's section below, change the code, and run zigvet again
until it is silent. Fix the bug the finding names, not the shape the rule
saw: code moved about until the report goes away still has the bug.

For many findings, `--format json` gives one object per finding.
`--summary` ends the run with a line on stderr saying how many files were
checked and what each rule found, which tells a clean run over 300 files
from one over 3.

## The rules

Each rule is one lowercase word, the name a report and an allow comment
use. Under each: what it catches, the smallest code that trips it, and
the same code fixed. zigvet's tests run every example here: the first
trips its rule, and the fix reports nothing.

### escape

A pointer or slice into stack memory leaves the function that made it:
returned, stored through a parameter, or stored to a global. The caller
reads memory the next call writes over.

```zig
fn scopes(monitoring: bool, asked: []const []const u8) []const []const u8 {
    return if (monitoring) &.{monitoringUrl()} else asked;
}
```

When every element can be known at compile time, `comptime` makes the
array static, as here, or make it a container-level const. Otherwise
return the value itself, have the caller pass in the memory, or allocate
it.

```zig
fn scopes(monitoring: bool, asked: []const []const u8) []const []const u8 {
    return if (monitoring) &.{comptime monitoringUrl()} else asked;
}
```

### freed

A function returns what its own `defer` frees, so the caller gets freed
memory.

```zig
fn joined(gpa: Allocator, a: []const u8, b: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, a);
    try list.appendSlice(gpa, b);
    return list.items;
}
```

Hand the memory over with `toOwnedSlice`, which empties the list so the
`defer` frees nothing, or make the `defer` an `errdefer`.

```zig
fn joined(gpa: Allocator, a: []const u8, b: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, a);
    try list.appendSlice(gpa, b);
    return list.toOwnedSlice(gpa);
}
```

### grow

A pointer into a list's items, or a map's value, kept across a call that
can move them (`append`, `put`). It works while the list has room, which
is most test runs, and reads freed memory once it grows.

```zig
fn bump(gpa: Allocator, list: *std.ArrayList(u32), x: u32) !void {
    const first = &list.items[0];
    try list.append(gpa, x);
    first.* += 1;
}
```

Keep the index and take the pointer again after the growth, or reserve
first with `ensureUnusedCapacity` and grow with an `AssumeCapacity` call,
which cannot move anything.

```zig
fn bump(gpa: Allocator, list: *std.ArrayList(u32), x: u32) !void {
    try list.append(gpa, x);
    list.items[0] += 1;
}
```

### copy

A `std.Io.Writer` or `Reader` interface copied out of the struct it
belongs to. Its methods find their parent from the interface's address,
so the copy's first flush reads whatever sits next to it, and crashes.

```zig
fn greet(gpa: Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var w = aw.writer;
    try w.writeAll("hello");
    return aw.toOwnedSlice();
}
```

Take a pointer: `&aw.writer`, `&file_writer.interface`.

```zig
fn greet(gpa: Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("hello");
    return aw.toOwnedSlice();
}
```

### refill

A place freed, then given new memory by something that can fail first.
When it fails, the place still holds the freed memory, and `deinit` frees
it again.

```zig
fn resize(self: *Rows, n: usize) !void {
    self.gpa.free(self.items);
    self.items = try self.gpa.alloc(u32, n);
}
```

Make the new value first, then free the old one and store the new, so a
failure leaves the old value in place.

```zig
fn resize(self: *Rows, n: usize) !void {
    const items = try self.gpa.alloc(u32, n);
    self.gpa.free(self.items);
    self.items = items;
}
```

### owner

One allocation freed by two errdefers: the caller's, and the one in the
function it hands the allocation to. When the callee fails, both run.

```zig
const Store = struct {
    gpa: Allocator,
    kept: std.ArrayList([]u8),

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
};
```

Free it in one place: drop the caller's errdefer, as here, or have the
callee leave the allocation to its caller when it fails.

```zig
const Store = struct {
    gpa: Allocator,
    kept: std.ArrayList([]u8),

    /// Takes `bytes`, even when it fails.
    fn keep(self: *Store, bytes: []u8) !void {
        errdefer self.gpa.free(bytes);
        try self.kept.append(self.gpa, bytes);
    }

    fn save(self: *Store, text: []const u8) !void {
        const bytes = try self.gpa.dupe(u8, text);
        try self.keep(bytes);
    }
};
```

### kept

An `errdefer` frees what the function has already stored where its
caller keeps it, and then something fails. The caller's `deinit` frees it
again.

```zig
fn put(self: *Store, name: []const u8) !void {
    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);
    try self.names.append(self.gpa, owned);
    try self.sizes.append(self.gpa, name.len);
}
```

Undo the store in an `errdefer` after it, as here, or make the store the
last step that can fail: reserve with `ensureUnusedCapacity`, then
`appendAssumeCapacity`.

```zig
fn put(self: *Store, name: []const u8) !void {
    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);
    try self.names.append(self.gpa, owned);
    errdefer _ = self.names.pop();
    try self.sizes.append(self.gpa, name.len);
}
```

### torn

An optional or union field built in place by an initializer that can
fail, which `deinit` frees. Zig writes an initializer into its place a
field at a time, and the optional reads as set before any field is made,
so a failure leaves it set over what was never made.

```zig
const Editor = struct {
    gpa: Allocator,
    text: []const u8,
    pending: ?struct { start: usize, saved: []u8 } = null,

    fn deinit(self: *Editor) void {
        if (self.pending) |p| self.gpa.free(p.saved);
    }

    fn begin(self: *Editor, start: usize) !void {
        self.pending = .{ .start = start, .saved = try self.gpa.dupe(u8, self.text) };
    }
};
```

Make what can fail first, then assign.

```zig
const Editor = struct {
    gpa: Allocator,
    text: []const u8,
    pending: ?struct { start: usize, saved: []u8 } = null,

    fn deinit(self: *Editor) void {
        if (self.pending) |p| self.gpa.free(p.saved);
    }

    fn begin(self: *Editor, start: usize) !void {
        const saved = try self.gpa.dupe(u8, self.text);
        self.pending = .{ .start = start, .saved = saved };
    }
};
```

### twice

An errdefer's free also written out by hand on a path that then returns
an error. The errdefer runs too, so it is freed twice. No allocation has
to fail: any input that takes the path does it.

```zig
fn open(gpa: Allocator, fd: i32) !*Conn {
    const conn = try gpa.create(Conn);
    errdefer gpa.destroy(conn);
    if (fd < 0) {
        gpa.destroy(conn);
        return error.BadConfig;
    }
    conn.* = .{ .fd = fd };
    return conn;
}
```

Drop the hand-written free and let the errdefer do it.

```zig
fn open(gpa: Allocator, fd: i32) !*Conn {
    const conn = try gpa.create(Conn);
    errdefer gpa.destroy(conn);
    if (fd < 0) return error.BadConfig;
    conn.* = .{ .fd = fd };
    return conn;
}
```

### sweep

A loop frees what a list holds, can fail part way, and empties the list
only after the loop. When it fails, the list still holds what earlier
turns freed.

```zig
fn flush(self: *Outbox) !void {
    for (self.queue.items) |m| {
        try self.send(m);
        self.gpa.free(m);
    }
    self.queue.clearRetainingCapacity();
}
```

Take each out of the list as it is freed, or empty the list before the
loop and free what it held.

```zig
fn flush(self: *Outbox) !void {
    while (self.queue.pop()) |m| {
        defer self.gpa.free(m);
        try self.send(m);
    }
}
```

### unlock

A lock taken, then something that can fail before the unlock, with no
`defer`. The lock stays held, and the next `lock` waits for good.

```zig
fn take(self: *Pool, io: std.Io) !*Conn {
    try self.mutex.lock(io);
    const conn = try self.pool.create(self.gpa);
    self.mutex.unlock(io);
    return conn;
}
```

`defer` the unlock straight after the lock.

```zig
fn take(self: *Pool, io: std.Io) !*Conn {
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);
    return self.pool.create(self.gpa);
}
```

### leak

A local released by hand later in its block, with something that can
fail in between and no `defer`. When it fails, the local is never
released.

```zig
fn insert(conn: *Conn, rows: []const Row) !void {
    var stmt = try conn.prepare("insert into t values (?)");
    for (rows) |row| try stmt.bind(row);
    stmt.finalize();
}
```

`defer` the release straight after the local is made, in place of the one
by hand; an `errdefer` if the function returns the local.

```zig
fn insert(conn: *Conn, rows: []const Row) !void {
    var stmt = try conn.prepare("insert into t values (?)");
    defer stmt.finalize();
    for (rows) |row| try stmt.bind(row);
}
```

### cancel

In a task's loop, an `Io` call whose error is dropped with `catch {}` or
`catch continue`. A task is a function handed to `async` or `concurrent`,
or one it calls. `error.Canceled` comes once, so the task runs on, and
whoever cancels it waits for good.

```zig
fn start(io: std.Io) !std.Io.Future(void) {
    return io.concurrent(worker, .{io});
}

fn worker(io: std.Io) void {
    while (true) {
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}
```

Return `error.Canceled`: with `try`, as here, or with
`catch |err| switch (err) { error.Canceled => |e| return e, else => {} }`.
Or call `io.recancel()` after handling it.

```zig
fn start(io: std.Io) !std.Io.Future(std.Io.Cancelable!void) {
    return io.concurrent(worker, .{io});
}

fn worker(io: std.Io) std.Io.Cancelable!void {
    while (true) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
```

### fit

A number printed into a buffer too small for it, with `catch unreachable`
saying it cannot fail. `{d}` of an f64 can need 327 bytes, and a u128 39:
a panic in Debug and ReleaseSafe, undefined behavior in ReleaseFast.

```zig
fn show(w: *std.Io.Writer, v: f64) !void {
    var buf: [48]u8 = undefined;
    try w.writeAll(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
}
```

Print a float with `{e}`, which needs at most 24 bytes for an f64, as
here; size the buffer for the worst case; or handle `error.NoSpaceLeft`.

```zig
fn show(w: *std.Io.Writer, v: f64) !void {
    var buf: [48]u8 = undefined;
    try w.writeAll(std.fmt.bufPrint(&buf, "{e}", .{v}) catch unreachable);
}
```

### alias

An anonymous initializer assigned to a place one of its own later
elements reads. Zig writes it into the place an element at a time, so
`ext = .{ ext[1], ext[0] }` gives `{ ext[1], ext[1] }`.

```zig
fn sorted(a: u32, b: u32) [2]u32 {
    var ext: [2]u32 = .{ a, b };
    if (ext[1] < ext[0]) ext = .{ ext[1], ext[0] };
    return ext;
}
```

Copy the old value first and read the copy, swap with `std.mem.swap`, as
here, or assign the fields one at a time, each read before it is
overwritten. A typed initializer, `[2]u32{...}`, is built aside and safe.

```zig
fn sorted(a: u32, b: u32) [2]u32 {
    var ext: [2]u32 = .{ a, b };
    if (ext[1] < ext[0]) std.mem.swap(u32, &ext[0], &ext[1]);
    return ext;
}
```

### flush

A buffered file or stream writer, written to and never flushed. What is
left in its buffer never arrives.

```zig
fn greet(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    try fw.interface.print("hello\n", .{});
}
```

Flush it after the last write, or `end()` it for a file.

```zig
fn greet(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    try fw.interface.print("hello\n", .{});
    try fw.interface.flush();
}
```

### wipe

A local wiped with `@memset` as the last thing done with it. Release
builds drop the dead store, and the secret stays in memory; Debug keeps
it, so a test of the wipe passes.

```zig
fn login(io: std.Io) !void {
    var secret: [64]u8 = undefined;
    defer @memset(&secret, 0);
    try readSecret(io, &secret);
}
```

Wipe it with `std.crypto.secureZero`, which release builds keep.

```zig
fn login(io: std.Io) !void {
    var secret: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    try readSecret(io, &secret);
}
```

### cached

A build script lists a directory to decide what to build, and never tells
Zig's configure cache. A file added there is not built until something
else changes the build, so `zig build test` passes without it.

```zig
pub fn build(b: *std.Build) !void {
    const io = b.graph.io;
    var dir = try b.root.openDir(io, "test", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| addCase(b, entry.name);
}
```

`b.dependOnDirectoryContents` next to the `openDir`, as here (one for
each directory a `walk` enters: it is not recursive), or
`b.graph.poisonCache()`.

```zig
pub fn build(b: *std.Build) !void {
    const io = b.graph.io;
    b.dependOnDirectoryContents(b.path("test"));
    var dir = try b.root.openDir(io, "test", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| addCase(b, entry.name);
}
```

### unrun

A file whose tests never run, because nothing the test build analyses
refers to it: Zig runs a file's tests only when something it analyses
names the file. `zig build test` passes without them. The rule reads
every file checked, so this example is two files.

```zig
// root.zig
pub const s3 = @import("s3.zig");

test "root" {}

// s3.zig
test "s3: a key that leaves the bucket is refused" {}
```

Name the file in a test block of the file that imports it, as the hint
says. `std.testing.refAllDecls(@This())` names every pub declaration,
but not what those files import in turn.

```zig
// root.zig
pub const s3 = @import("s3.zig");

test {
    _ = s3;
}

// s3.zig
test "s3: a key that leaves the bucket is refused" {}
```

### hoard

A fuzz target keeps memory past one input, from an allocator the test
runner does not check. It grows with every input until the run runs out
of memory, and the leak check passes.

```zig
var seen: std.ArrayList([]const u8) = .empty;

fn one(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    try seen.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, input));
    try std.testing.expect(parse(input) != null);
}

test "fuzz: parse" {
    try std.testing.fuzz({}, one, .{});
}
```

Take the memory from `std.testing.allocator`, which the runner checks
after each input, and give it back before the input ends.

```zig
fn one(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const copy = try std.testing.allocator.dupe(u8, input);
    defer std.testing.allocator.free(copy);
    try std.testing.expect(parse(copy) != null);
}

test "fuzz: parse" {
    try std.testing.fuzz({}, one, .{});
}
```

## When a finding looks wrong

Take it as a bug until shown otherwise, and show it with a test that
takes the path:

- refill, owner, kept, torn, sweep and leak go wrong when something fails
  part way. `std.testing.checkAllAllocationFailures` runs a function once
  for each allocation in it, failing that one, and `std.testing.allocator`
  then reports the double free or the leak. After unlock's, the next
  `lock` waits for good.
- twice needs no failure made: a test with the input that takes the
  path, and `std.testing.allocator` reports the double free.
- escape: `zigvet.clobberStack()`, called after the function returns and
  before its result is read, writes over the stack the function used, so
  a Debug test fails at once. It comes from zigvet's package
  (`tests.root_module.addImport("zigvet", zigvet.module("zigvet"))`, with
  the dependency below).

If the code is right and zigvet cannot see why, say so in the comment
lines directly above the reported line, with the rule's name and a
reason:

```zig
// zigvet: allow escape only called at comptime, from the build script
return &.{Scope.monitoring.url()};
```

An allow comment that suppresses nothing is reported itself, as rule
`allow`, and fails the run as a finding does: one with no reason, one
that names no rule zigvet has, one at the end of the line rather than
above it, and one left over after the code changed. Delete it when its
finding goes.

Then report it, so the rule gets better: an issue on
https://github.com/kmoneil/zigvet/issues with `zigvet --version`, the
finding as printed, and the smallest code that shows it. Search the open
and closed issues first. File the same way:

- a missed case: a bug of a rule's kind zigvet did not report, with the
  smallest code that has it;
- a rule idea: a mistake the compiler accepts in every build mode that is
  still wrong. Not a rule: anything the compiler, `zig fmt` or an
  existing linter catches; style; and code that is right but slower or
  larger than it could be.

## Add it to a build

With zigvet on the PATH (`brew install kmoneil/tap/zigvet`, or a release
binary), a step `zig build test` runs too:

```zig
const lint = b.addSystemCommand(&.{ "zigvet", "build.zig", "src" });
lint.setCwd(b.path("."));
b.step("lint", "Report code that compiles but is wrong (zigvet)").dependOn(&lint.step);
test_step.dependOn(&lint.step);
```

`setCwd` makes paths print from the project's root, as an editor and a
CI annotation want them. zigvet is quiet on a pass, so the step prints
nothing unless it fails, and a command with no output files runs every
time rather than being cached.

With nothing installed, as a package pinned to a release tag:
`zig fetch --save git+https://github.com/kmoneil/zigvet#v<version>`, then

```zig
const zigvet = b.dependency("zigvet", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
const lint = b.addRunArtifact(zigvet.artifact("zigvet"));
lint.setCwd(b.path("."));
lint.addArgs(&.{ "build.zig", "src" });
```

In CI, `zigvet --format github src` puts each finding on the pull
request's diff.

## Reading the output

`--format` takes `text` (the default), `github` (GitHub Actions
annotations) or `json`. Text is `path:line:col: rule: message`, then,
indented on the next line, `hint:` and the fix. json is one array with an
object per report: `path`, `line`, `column` (both from 1), `rule`,
`message` and `hint`. `rule` is a rule's name, `allow` for an allow
comment that suppresses nothing, or `error` for a file that does not
parse, which has no hint (`null`) and gives the error `zig ast-check`
would.

Reports go to stdout in path order, then source order, and are the same
in every format. What is said about the run itself, such as a path that
cannot be read, goes to stderr as text.

## Exit status

0 when nothing was reported; 1 when a finding, an allow comment that
suppresses nothing, or a parse error was; 2 on a usage error, or a path
that cannot be read or holds no .zig file to check. zigvet still reports
what it could read.

## What catches agents out

- Name the whole project, build.zig with it: `zigvet .`. unrun asks which
  files the tests reach from the build's roots, so a file checked alone,
  or a directory without the files that import it, says nothing of its
  tests.
- A clean run prints nothing. `--summary` says how many files were
  checked; a path that holds no .zig file is exit 2, not a clean run.
- Hidden files and directories, `zig-out` and `zig-pkg` are skipped.
  `--exclude <path>` skips more, named as zigvet prints paths: relative
  to the current directory. A file named outright is checked whatever its
  extension.
- A finding points at one place (the free, the lock, the call that can
  move a list) and its message names the others (what fails, what frees
  it again): read the message, not just the line, before editing.
- The rules read syntax alone: names, `defer` and `errdefer`, and the
  types the file declares, not what the compiler infers. A shape spread
  across files or behind a helper may not be seen, so no finding is not
  proof of no bug.
- `zigvet --help` prints every flag and `zigvet --version` the version;
  `zigvet skill --install <dir>` writes this file to
  `<dir>/zigvet/SKILL.md`. To check a directory named `skill`, name it
  `./skill`.
