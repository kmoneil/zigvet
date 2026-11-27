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

Read the rule's part (`zigvet skill escape` prints this one's: what it
catches, an example and the fix), change the code, and run zigvet again
until it is silent. Fix the bug the finding names, not the shape the rule
saw: code moved about until the report goes away still has the bug.

For many findings, `--format json` gives one object per finding.
`--summary` ends the run with a line on stderr saying how many files were
checked and what each rule found, which tells a clean run over 300 files
from one over 3.

## The rules

Each rule is one lowercase word, the name a report and an allow comment
use. Each has a part of this guide: what it catches, the smallest code
that trips it, and the same code fixed. `zigvet skill escape` prints
escape's; name several to print several. Read a rule's part before
changing the code it reported. zigvet's tests run every example: the
first trips its rule, and the fix reports nothing.

- escape: a pointer or slice into stack memory leaves the function that
  made it.
- freed: a function returns what its own `defer` frees.
- grow: a pointer into a list's items or a map's values, kept across a
  call that can move them.
- copy: a `std.Io.Writer` or `Reader` interface copied out of the struct
  it belongs to.
- refill: a place freed, then given new memory by something that can
  fail first.
- owner: one allocation freed by two errdefers, the caller's and the
  callee's.
- kept: an `errdefer` frees what the function has already stored where
  its caller keeps it.
- handed: an `errdefer` frees a local, still armed after a call handed it
  to a value whose own errdefer'd release frees it.
- torn: an optional or union field built in place by an initializer
  that can fail.
- twice: a deferred release also written out by hand: an errdefer's on a
  path that returns an error, a defer's wherever its block is then left.
- sweep: a loop frees what a list holds, can fail part way, and empties
  the list only after it.
- unlock: a lock taken, then something that can fail before the unlock,
  with no `defer`.
- leak: a local released by hand later, with something that can fail in
  between and no `defer`.
- orphan: an allocation made in the arguments of a call that can fail, or
  in an initializer before another, with no name to free it by.
- cancel: an `Io` call's error dropped in a task's loop, so whoever
  cancels the task waits for good, or a wait's returned as another error.
- fit: a number printed into a buffer too small for it, under
  `catch unreachable`.
- alias: an anonymous initializer assigned to a place its own later
  elements read.
- flush: a buffered file or stream writer, written to and never flushed.
- positional: a writer on stdout or stderr, or a reader on stdin, made
  positional.
- wipe: a local wiped with `@memset` as the last thing done with it,
  which release builds drop.
- buckets: a std `HashMap`'s `capacity()`, its buckets, tested as room
  for items before an insert that assumes capacity.
- hollow: an optional given `@as(T, undefined)` of a pointer, slice or
  error set, then unwrapped, which tests bits left undefined.
- race: a container-level optional holding atomics or a lock, asked
  whether it is null by value.
- wrap: a test for unsigned wraparound after a plain `+`, which panics
  rather than wraps.
- narrow: a `u8` or `u16` offset plus a constant as an index, computed
  in the narrow type, where the same function widens it elsewhere.
- counter: a `u8` or `u16` counter stepped while it is less than the
  `.len` of the slice it walks, which overflows on a longer slice.
- remainder: a remainder by hand, `x - @divFloor(x, d) * d`, whose
  product overflows near the type's minimum, where `@mod` does not.
- parsed: an `i64` from `parseInt` in a plain `-` or `+` with nothing
  bounding it first, which overflows for a value the text's writer picks.
- opath: a directory opened without `.iterate = true`, then listed,
  synced or given new permissions, which Linux refuses.
- tail: `@call(.always_tail, ...)` with nothing that tests the backend,
  which every Debug build on x86_64 Linux fails to compile.
- cached: a build script lists a directory, or asks whether a path is
  there, to decide what to build, and never tells Zig's configure cache.
- unrun: a file whose tests never run, because nothing the test build
  analyses names it.
- hoard: a fuzz target keeps memory past one input, from an allocator
  the test runner does not check.

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
`defer` frees nothing, or make the `defer` an `errdefer`. A value
`std.json.parseFromSlice` parsed out of what the `defer` frees is reported
too: its strings point into the input unless the options say
`.allocate = .alloc_always`.

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
is most test runs, and reads freed memory once it grows. A slice of a
`std.Io.Reader`'s buffer (`take`, `peek`, `buffered`) kept across a call
that reads more (`fill`, `takeInt`) is the same: a refill moves the
buffer's bytes and reads others into their place. So is a method whose
doc says its slice lives until `deinit` while another grows the list.

```zig
fn bump(gpa: Allocator, list: *std.ArrayList(u32), x: u32) !void {
    const first = &list.items[0];
    try list.append(gpa, x);
    first.* += 1;
}

fn isAnih(in: *std.Io.Reader) !bool {
    const id = try in.takeArray(4);
    _ = try in.takeInt(u32, .little);
    return std.mem.eql(u8, id, "anih");
}

const Names = struct {
    bytes: std.ArrayList(u8) = .empty,
    pub fn add(n: *Names, gpa: Allocator, s: []const u8) !void {
        try n.bytes.appendSlice(gpa, s);
    }
    /// All the names. Valid until `deinit`.
    pub fn all(n: *const Names) []const u8 {
        return n.bytes.items;
    }
};
```

Keep the index and take the pointer again after the growth, or reserve
first with `ensureUnusedCapacity` and grow with an `AssumeCapacity` call,
which cannot move anything. Copy a reader's bytes out before reading on.
Make a doc say what ends the slice.

```zig
fn bump(gpa: Allocator, list: *std.ArrayList(u32), x: u32) !void {
    try list.append(gpa, x);
    list.items[0] += 1;
}

fn isAnih(in: *std.Io.Reader) !bool {
    const id = (try in.takeArray(4)).*;
    _ = try in.takeInt(u32, .little);
    return std.mem.eql(u8, &id, "anih");
}

const Names = struct {
    bytes: std.ArrayList(u8) = .empty,
    pub fn add(n: *Names, gpa: Allocator, s: []const u8) !void {
        try n.bytes.appendSlice(gpa, s);
    }
    /// All the names. Valid until the next `add`.
    pub fn all(n: *const Names) []const u8 {
        return n.bytes.items;
    }
};
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
it again, or, for a local, the function's own `defer` does.

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

### handed

An `errdefer` frees a local, and is still armed after a call has handed
the local to a value that a later `errdefer` releases, freeing it with
it. When anything after fails, both run, and the local is freed twice.

```zig
const Pending = struct {
    gpa: std.mem.Allocator,
    url: []u8,

    fn make(gpa: std.mem.Allocator, url: []u8) !*Pending {
        const p = try gpa.create(Pending);
        p.* = .{ .gpa = gpa, .url = url };
        return p;
    }

    fn destroy(p: *Pending) void {
        p.gpa.free(p.url);
        p.gpa.destroy(p);
    }
};

fn prepare(gpa: std.mem.Allocator, href: []const u8) !*Pending {
    const url = try gpa.dupe(u8, href);
    errdefer gpa.free(url);
    const p = try Pending.make(gpa, url);
    errdefer p.destroy();
    try check(p);
    return p;
}
```

Scope the first errdefer to the hand-over, so it covers only the call
failing.

```zig
const Pending = struct {
    gpa: std.mem.Allocator,
    url: []u8,

    fn make(gpa: std.mem.Allocator, url: []u8) !*Pending {
        const p = try gpa.create(Pending);
        p.* = .{ .gpa = gpa, .url = url };
        return p;
    }

    fn destroy(p: *Pending) void {
        p.gpa.free(p.url);
        p.gpa.destroy(p);
    }
};

fn prepare(gpa: std.mem.Allocator, href: []const u8) !*Pending {
    const url = try gpa.dupe(u8, href);
    const p = blk: {
        errdefer gpa.free(url);
        break :blk try Pending.make(gpa, url);
    };
    errdefer p.destroy();
    try check(p);
    return p;
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

A deferred release also written out by hand, where both run: an
errdefer's on a path that then returns an error, a defer's wherever its
block is then left. It is released twice. No allocation has to fail: any
input that takes the path does it, and under a defer every run.

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

fn replace(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    const file = try dir.createFile(io, "new", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
    file.close(io);
    try dir.rename("new", dir, name, io);
}
```

Drop the hand-written one and let the errdefer or defer do it. Where the
release has to come early, as this close before the rename, make the
defer conditional and turn it off there.

```zig
fn open(gpa: Allocator, fd: i32) !*Conn {
    const conn = try gpa.create(Conn);
    errdefer gpa.destroy(conn);
    if (fd < 0) return error.BadConfig;
    conn.* = .{ .fd = fd };
    return conn;
}

fn replace(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    const file = try dir.createFile(io, "new", .{});
    var open_file = true;
    defer if (open_file) file.close(io);
    try file.writeStreamingAll(io, data);
    file.close(io);
    open_file = false;
    try dir.rename("new", dir, name, io);
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

### orphan

An allocation made in the arguments of a call that can fail. The argument
is made first; when the call then fails, nothing has a name for it, so no
errdefer can free it and it leaks. The same goes for a thread
(`try std.Thread.spawn(...)`) or an open file passed that way, and for an
initializer with a `try` after the allocation
(`.{ .a = try gpa.dupe(u8, x), .b = try gpa.dupe(u8, y) }`): an errdefer
after it does not run for a failure inside it. Memory is reported only
from an allocator named `gpa`: an arena frees it anyway.

```zig
fn keep(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), s: []const u8) !void {
    try list.append(gpa, try gpa.dupe(u8, s));
}
```

Give it a name and arm its release before the call, as here; or make the
call unable to fail first (`ensureUnusedCapacity`, then
`appendAssumeCapacity`).

```zig
fn keep(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), s: []const u8) !void {
    const copy = try gpa.dupe(u8, s);
    errdefer gpa.free(copy);
    try list.append(gpa, copy);
}
```

### cancel

In a task's loop, an `Io` call whose error is dropped with `catch {}` or
`catch continue`. A task is a function handed to `async` or `concurrent`,
or one it calls. `error.Canceled` comes once, so the task runs on, and
whoever cancels it waits for good. And in any function, a wait (`sleep`,
`wait`, `waitTimeout`, `lock`) under `catch return error.X`, which hands
the cancel on under another name.

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
here; size the buffer for the whole line's worst case, the format's own
text and every number in it (`"user-{d}"` of a u64 needs 25); or handle
`error.NoSpaceLeft`.

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

A union is given its tag, and an optional is marked not null, before any
element is evaluated, so even the only element can read what was stored:
`left = .{ .pair = try alloc(arena, .{ .left = left, .right = right }) }`
copies `left` into the new node already tagged `.pair`, its payload not
yet written. Build the value in a local first, then assign it.

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

### positional

A writer on stdout or stderr, or a reader on stdin, made positional.
Redirected to a file, a writer writes from byte 0 at a position of its
own, over what else is written there: under `prog > log 2>&1`, anything
printed to stderr and the output overwrite each other.

```zig
fn report(io: std.Io, rows: usize) !void {
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    try out.interface.print("{d} rows\n", .{rows});
    try out.interface.flush();
}
```

Make it streaming, which writes at the file's offset: `writerStreaming`,
or `File.Writer.initStreaming` in place of `.init`.

```zig
fn report(io: std.Io, rows: usize) !void {
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    try out.interface.print("{d} rows\n", .{rows});
    try out.interface.flush();
}
```

A reader on stdin made positional is the same bug from the reading side:
redirected from a file, it reads from byte 0, so under
`{ read -r header; prog; } < input` it reads the header again. Make it
`readerStreaming`, or `File.Reader.initStreaming` in place of `.init`.

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

### buckets

A std `HashMap`'s or `HashMapUnmanaged`'s `capacity()` tested as room for
items before an insert that assumes capacity. It counts buckets, and the
map fills only 80% of them before an insert must grow, so the test passes
with no room, and `putAssumeCapacity` panics in Debug.

```zig
fn add(map: *std.AutoHashMapUnmanaged(u32, void), gpa: std.mem.Allocator, key: u32) !void {
    if (map.capacity() <= map.count()) try map.ensureTotalCapacity(gpa, map.count() * 2 + 8);
    map.putAssumeCapacity(key, {});
}
```

Ask for room counted in items: `ensureUnusedCapacity` returns at once
when there is room.

```zig
fn add(map: *std.AutoHashMapUnmanaged(u32, void), gpa: std.mem.Allocator, key: u32) !void {
    try map.ensureUnusedCapacity(gpa, 1);
    map.putAssumeCapacity(key, {});
}
```

### hollow

An optional given a payload of `undefined`, then unwrapped in place. An
optional of a pointer, a slice or an error set keeps its null in the
payload's own bits, so `@as(T, undefined)` leaves it neither null nor set,
and the `.?` after it branches on undefined: Debug's 0xaa fill reads as
set, while ReleaseSafe can read it as null and lose what was written
through it.

```zig
fn copyName(gpa: std.mem.Allocator, src: []const u8, dst: *?[]const u8) !void {
    dst.* = @as([]const u8, undefined);
    try dupeInto(gpa, src, &dst.*.?);
}

fn dupeInto(gpa: std.mem.Allocator, src: []const u8, out: *[]const u8) !void {
    out.* = try gpa.dupe(u8, src);
}
```

Build the payload in a local and assign the optional once; or, where its
address matters, store a defined value first (a copy of the source) and
write the payload through `.?`. Generic code can ask
`@typeInfo(T) == .pointer` and read a pointer aside.

```zig
fn copyName(gpa: std.mem.Allocator, src: []const u8, dst: *?[]const u8) !void {
    var name: []const u8 = undefined;
    try dupeInto(gpa, src, &name);
    dst.* = name;
}

fn dupeInto(gpa: std.mem.Allocator, src: []const u8, out: *[]const u8) !void {
    out.* = try gpa.dupe(u8, src);
}
```

### race

A container-level optional asked whether it is null by value, when what
it holds has atomics or a lock in it. Debug copies the whole global to
read the tag, a plain read racing the atomic writes of every thread that
locks it: a data race, which ThreadSanitizer reports.

```zig
const Registry = struct {
    mutex: std.Io.Mutex = .init,
    hits: usize = 0,
};

var registry: ?Registry = null;

fn state() *Registry {
    if (registry == null) registry = .{};
    return &registry.?;
}
```

Ask through a pointer, which reads only the tag: `if (registry) |*r|`, and
`|*r|` in place of a by-value capture.

```zig
const Registry = struct {
    mutex: std.Io.Mutex = .init,
    hits: usize = 0,
};

var registry: ?Registry = null;

fn state() *Registry {
    if (registry) |*r| return r;
    registry = .{};
    return &registry.?;
}
```

### wrap

A test for unsigned wraparound, `end < start`, after a plain `+`. Zig's
`+` does not wrap: an overflow panics in Debug and ReleaseSafe and is
undefined in ReleaseFast, so the test is never true, and on a 32-bit
target (wasm32) the input it was written for panics instead.

```zig
fn take(src: []const u8, off: *usize, n: u32) ?[]const u8 {
    const end = off.* + n;
    if (end < off.* or end > src.len) return null;
    const s = src[off.*..end];
    off.* = end;
    return s;
}
```

Test before adding: `std.math.add` and `@addWithOverflow` say when the
sum overflows. Or sum in a wider type and compare that.

```zig
const std = @import("std");

fn take(src: []const u8, off: *usize, n: u32) ?[]const u8 {
    const end = std.math.add(usize, off.*, n) catch return null;
    if (end > src.len) return null;
    const s = src[off.*..end];
    off.* = end;
    return s;
}
```

### narrow

An offset declared `u8` or `u16` plus a constant, as a slice's bound or
an index. Zig computes `offset + 4` in `u16` and widens only the result,
so it overflows at 0xFFFC, a panic in Debug and ReleaseSafe and the wrong
bytes in ReleaseFast, though the bounds check above, widened, passes.

```zig
const std = @import("std");

pub fn tagged(sub: []const u8, offset: u16) ?u32 {
    if (offset == 0 or @as(usize, offset) + 6 > sub.len) return null;
    if (std.mem.readInt(u16, sub[offset + 4 ..][0..2], .big) != 0x8000) return null;
    return std.mem.readInt(u32, sub[offset..][0..4], .big);
}
```

Widen before the arithmetic, `@as(usize, offset) + 4`, or take the offset
as a `usize`, so no sum of it is computed narrow.

```zig
const std = @import("std");

pub fn tagged(sub: []const u8, offset: usize) ?u32 {
    if (offset == 0 or offset + 6 > sub.len) return null;
    if (std.mem.readInt(u16, sub[offset + 4 ..][0..2], .big) != 0x8000) return null;
    return std.mem.readInt(u32, sub[offset..][0..4], .big);
}
```

### counter

A counter declared `u8` or `u16`, stepped in a `while` loop that walks a
slice and stops at its `.len`. The comparison widens the counter, so on a
slice longer than the type counts it holds at 255 (or 65535), and the
step overflows: a panic in Debug and ReleaseSafe, and in ReleaseFast a
counter that wraps to 0 and a loop that may never end.

```zig
pub fn headingLevel(line: []const u8) ?u8 {
    var level: u8 = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    return level;
}
```

Count in a `usize` and narrow the result once it is checked, or bound the
counter by its type as well as by the `.len`.

```zig
pub fn headingLevel(line: []const u8) ?u8 {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    return @intCast(level);
}
```

### remainder

A remainder taken by hand from a floor division of a signed integer,
`x - @divFloor(x, d) * d`, in one expression or with the division in a
local. For an `x` near its type's minimum the product is below the
minimum: a panic in Debug and ReleaseSafe, undefined behavior in
ReleaseFast. A timestamp parsed from input can be that `x`.

```zig
fn secondsOfDay(t: i64) i64 {
    return t - @divFloor(t, 86400) * 86400;
}
```

`@mod` is the same value and cannot overflow. `x - @divTrunc(x, d) * d`
cannot either, and is not reported.

```zig
fn secondsOfDay(t: i64) i64 {
    return @mod(t, 86400);
}
```

### parsed

A `parseInt` result of `i64`, `isize` or `i128` as an operand of a plain
`-` or `+`, with nothing bounding it first. The text's writer picks the
value: one at either end of the type overflows, a panic in Debug and
ReleaseSafe and a wrapped result in ReleaseFast. On a header, a query
parameter or a file, that is a remote panic.

```zig
pub fn fresh(timestamp: []const u8, now_s: i64) bool {
    const at = std.fmt.parseInt(i64, timestamp, 10) catch return false;
    return @abs(now_s - at) <= 300;
}
```

Compare it against bounds first, as here; or parse a narrower type and
widen it; or say what happens with `-|`, `-%` or `std.math.sub`.

```zig
pub fn fresh(timestamp: []const u8, now_s: i64) bool {
    const at = std.fmt.parseInt(i64, timestamp, 10) catch return false;
    if (at < now_s -| 300 or at > now_s +| 300) return false;
    return true;
}
```

### opath

A directory opened without `.iterate = true`, then listed (`iterate`,
`walk`), synced through its handle, or given new permissions or a new
owner. Linux opens such a directory with `O_PATH`, a descriptor that names
it and cannot read or change it, so each of those is `EBADF` there: a
panic in Debug, `error.Unexpected` otherwise. macOS has no `O_PATH`, so
the code works there and its tests pass. The report is on the call that
opens it, also when the use is in a function of the same file it is
handed to.

```zig
pub fn syncDir(io: Io, dir: Io.Dir, sub: []const u8) !void {
    const d = try dir.openDir(io, sub, .{});
    defer d.close(io);
    const as_file: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}
```

Open it for iterating, which Linux does without `O_PATH`:
`.{ .iterate = true }`, or `.{ .open_options = .{ .iterate = true } }`
for `createDirPathOpen`.

```zig
pub fn syncDir(io: Io, dir: Io.Dir, sub: []const u8) !void {
    const d = try dir.openDir(io, sub, .{ .iterate = true });
    defer d.close(io);
    const as_file: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}
```

### tail

`@call(.always_tail, ...)` asks for a tail call or a compile error. LLVM
makes one; Zig's own x86_64 backend, the Debug default on x86_64 Linux,
makes none. So the code compiles on macOS and in every release build, and
every Debug build on x86_64 Linux fails, a library's consumers' builds
among them. The report is on the `@call`, when nothing before it in its
function tests `builtin.zig_backend`.

```zig
pub fn scan(xs: []const u8, i: usize) usize {
    if (i >= xs.len or xs[i] == 0) return i;
    return @call(.always_tail, scan, .{ xs, i + 1 });
}
```

Ask for the tail call only where the backend makes one, and for a plain
call elsewhere: a modifier held in a constant that tests the backend.

```zig
const builtin = @import("builtin");
const std = @import("std");

const tail: std.lang.CallModifier = if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto;

pub fn scan(xs: []const u8, i: usize) usize {
    if (i >= xs.len or xs[i] == 0) return i;
    return @call(tail, scan, .{ xs, i + 1 });
}
```

### cached

A build script lists a directory to decide what to build, and never tells
Zig's configure cache. A file added there is not built until something
else changes the build, so `zig build test` passes without it. The same
goes for asking whether a path is there (`b.root.access(io, "locales",
.{})` in an `if`, or under a `catch` that goes on).

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
`b.graph.poisonCache()`. For a path asked after, depend on the directory
it would be in, one that is always there (`b.path(".")`): a dependency on
a path that is not there fails the configure. A function of the build
script that makes the dependency (say, on the nearest directory above the
path that is there) counts, called with the path.

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
of memory, and the leak check passes. A function handed to a wrapper
around `std.testing.fuzz` (`fuzzing.run({}, fuzzRender, 400)`) is read as a
target too, when the wrapper's file is checked in the same run.

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
  path, and `std.testing.allocator` reports the double free. A
  descriptor closed twice shows only when another thread was given its
  number in between.
- race: a Debug test built with ThreadSanitizer
  (`.sanitize_thread = true` on its module) on x86_64 Linux, with other
  threads locking or storing while one asks. macOS's ThreadSanitizer does
  not see this copy.
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
  files the tests reach from the build's roots. A file named by itself,
  as when only the files a change touched are given, is taken as reached,
  so such a run reports no unrun; a directory is read as all there is, so
  one without its test root can report a file the root reaches.
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
- `zigvet --help` prints every flag and `zigvet --version` the version.
  `zigvet skill` prints this guide without the rules' parts,
  `zigvet skill --all` the whole of it, and
  `zigvet skill --install <dir>` writes `<dir>/zigvet/SKILL.md`, which
  has an agent run `zigvet skill`. To check a directory named `skill`,
  name it `./skill`.
