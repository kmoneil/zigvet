// What is stored into a field or element of a local after its declaration
// leaves with the local when the local is returned whole (#125).
const S = struct {
    buf: [8]u8 = undefined,
    bytes: []const u8 = "",
    at: *const u8 = &zero,
};
const T = struct { inner: S = .{} };
const zero: u8 = 0;

fn ownField() S {
    var s: S = .{};
    s.bytes = s.buf[0..4];
    return s;
}
fn fieldAddress() S {
    var s: S = .{};
    s.at = &s.buf[0];
    return s;
}
fn another(n: u8) S {
    var x: [2]u8 = .{ n, n };
    x[0] = 0;
    var s: S = .{};
    s.bytes = &x;
    return s;
}
fn element(n: u8) [2][]const u8 {
    var x: [2]u8 = .{ n, n };
    x[0] = 0;
    var names: [2][]const u8 = .{ "", "" };
    names[1] = &x;
    return names;
}
fn deeper(n: u8) T {
    var x: [1]u8 = .{n};
    x[0] = 0;
    var t: T = .{};
    t.inner.bytes = &x;
    return t;
}

// Not reported: a store through a local pointer, which is a store outward
// as one through a parameter is, where a named local is often deliberate
// (a buffer lent for the length of a call); and a field of the local the
// store did not write.
fn lent(ctx: *S, n: u8) *S {
    var scratch: [4]u8 = @splat(n);
    scratch[0] = 0;
    const c: *S = ctx;
    c.bytes = &scratch;
    use(c);
    c.bytes = "";
    return c;
}
fn lentElements(names: [][]const u8, n: u8) [][]const u8 {
    var scratch: [4]u8 = @splat(n);
    scratch[0] = 0;
    const view: [][]const u8 = names;
    view[0] = &scratch;
    useNames(view);
    view[0] = "";
    return view;
}

const Inner = struct { first: []const u8 = "" };
const Pair = struct { first: []const u8 = "", rest: Inner = .{} };
fn firstOf(n: u8) []const u8 {
    var scratch: [1]u8 = .{n};
    scratch[0] = 0;
    var p: Pair = .{ .first = "static" };
    p.rest = .{ .first = &scratch };
    useInner(&p.rest);
    return p.first;
}

fn use(s: *S) void {
    _ = s;
}
fn useNames(names: [][]const u8) void {
    _ = names;
}
fn useInner(inner: *Inner) void {
    _ = inner;
}

comptime {
    _ = &ownField;
    _ = &fieldAddress;
    _ = &another;
    _ = &element;
    _ = &deeper;
    _ = &lent;
    _ = &lentElements;
    _ = &firstOf;
}

// error
//
// :13:15: error: slice of a field of local 's' made here leaves ownField through return
// :18:12: error: address of a field of local 's' made here leaves fieldAddress through return
// :25:15: error: address of local 'x' made here leaves another through return
// :32:16: error: address of local 'x' made here leaves element through return
// :39:21: error: address of local 'x' made here leaves deeper through return
