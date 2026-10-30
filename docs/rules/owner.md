# owner

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

## What owner reports

A call under `try` to one of the file's own functions that takes a
parameter on failure, or one returned as it is (`return f(...)`, which runs
the caller's errdefers just as `try` does), or one whose `catch` hands on
what it caught (`catch |err| return err`, or a block ending so with no
other way out), where the argument for that parameter (the receiver, for
a method's first) is a name that an `errdefer` of the caller, declared
before the call in a block around it,
frees, or carries one: its address (`&list`), a field of an initializer,
as deep as they nest (`.{ .state = .{ .items = items } }`), or a local
made from one of those that nothing assigns to before the call.
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
`push` in a frame frees them twice when the append fails. A function may
take a field of the parameter instead, and then the argument has to carry
the freed name in that field:

```zig
const Image = struct {
    pixels: []u8,

    /// Turned; the old pixels are freed.
    fn turned(img: Image, gpa: Allocator) !Image {
        defer gpa.free(img.pixels);
        const out = try gpa.alloc(u8, img.pixels.len);
        @memcpy(out, img.pixels);
        return .{ .pixels = out };
    }
};

fn decode(gpa: Allocator, n: usize) !Image {
    const pixels = try gpa.alloc(u8, n);
    errdefer gpa.free(pixels);
    const img: Image = .{ .pixels = pixels };
    return img.turned(gpa); // when the alloc in turned fails, pixels is freed twice
}
```

The function is found by name, through its type (`Store.keep(s, b)`), or
as a method of a binding whose type the file declares, in an annotation or
in its initializer (`self.keep(b)`, `const img = Image{ ... };`).

Not reported: a call whose error is handled rather than handed on, which
only the caller can judge; an `errdefer` declared after the call; an
argument that neither is a name nor carries one; a field the callee frees
of a name the caller's errdefer frees whole (`gpa.destroy(frame)` against
`frame.list.deinit()`), which is not what the caller frees; a method's
receiver, or the first of several arguments, for a call recognized only by
its name (`releasePages(pool, pages)` releases into `pool`); a release
that leaves the value empty (`clearAndFree`), or one followed by an
assignment to it; and a function declared in another file.

## Found in real code

Over Zig 0.17.0's standard library and compiler sources and the
application repos, owner reports three, all real: two in two application
repos, and a copy of one of them another keeps. Over fourteen well-known
public Zig projects, six, all real, in one compiler, two of them in its
tests.

[All rules](../../README.md#the-rules)
