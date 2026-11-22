//! Rule twenty-five, counter: a counter narrower than 32 bits, stepped in a
//! `while` loop whose condition compares it with a `.len`.
//!
//!     var level: u8 = 0;
//!     while (level < line.len and line[level] == '#') level += 1;
//!
//! The comparison widens `level` to the `usize` of `line.len`, so on a
//! line longer than 255 bytes it holds for every value a `u8` has: at 255
//! it passes, and `level += 1` overflows, a panic in Debug and ReleaseSafe.
//! In ReleaseFast and ReleaseSmall the counter wraps to 0 and the loop may
//! never end.
//!
//! What is reported is `x += k` in a `while` loop's body or continue
//! expression, where the loop's condition, or one it joins with `and`, is
//! `x < e`, `x <= e`, `e > x` or `e >= x`, with `e` a `.len` or arithmetic
//! on one (`line.len - 1`), and `x` a name declared an unsigned integer
//! narrower than 32 bits (`u8`, `u16`; `ints.declaredType`). Only when the
//! loop walks that slice with `x`, indexing or slicing it with `x` or
//! arithmetic on it (`line[level]`): a counter that only counts the items
//! (a replica's number, passed on as a `u8`) has a range of its own. Not
//! when the loop also compares `x` with a number literal its type holds
//! (`i < 16 and i < s.len`, or `if (i == 15) break;` in its body), which
//! can bound it; nor when the `.len` is an array's whose type the file
//! writes, a length known where the code is written; nor `+%=`, which
//! wraps on purpose. Over the standard library, eleven application repos
//! and fourteen public projects it reports two loops, both bugs; `!=`,
//! `or` and `x = x + k` add one more there, not a bug.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const expect = @import("expect.zig");
const ints = @import("ints.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");
const Types = types.Types;

/// Appends a finding for every narrow counter stepped in a loop it bounds
/// only by a `.len`. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var t: ?Types = null;
    var tests: std.ArrayList(Node.Index) = .empty;
    var reported: std.AutoHashMapUnmanaged(usize, void) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const loop = tree.fullWhile(node) orelse continue;
        tests.clearRetainingCapacity();
        try conjuncts(arena, tree, loop.ast.cond_expr, &tests);
        for (tests.items) |comparison| {
            const finding = try counterIn(arena, tree, &t, node, comparison) orelse continue;
            // A loop inside another on the same counter finds the same step.
            if ((try reported.getOrPut(arena, finding.offset)).found_existing) continue;
            try findings.append(arena, finding);
        }
    }
}

/// The finding for `comparison`, one of the tests in the condition of
/// `loop`, when it compares a narrow counter with a `.len` and the loop
/// steps the counter and walks that slice with it. `t` is made the first
/// time it is needed.
fn counterIn(arena: Allocator, tree: *const Ast, t: *?Types, loop: Node.Index, comparison: Node.Index) Allocator.Error!?Finding {
    const x, const len = againstLen(tree, comparison) orelse return null;
    if (t.* == null) t.* = try .init(arena, tree);
    const declared = ints.declaredType(t.*.?, x, 0) orelse return null;
    const bits = ints.unsignedBits(tree, declared) orelse return null;
    if (bits >= 32) return null;
    const max = (@as(u64, 1) << @intCast(bits)) - 1;
    if (arrayLen(t.*.?, len)) return null;
    if (!walks(tree, loop, x, len)) return null;
    if (boundedIn(tree, loop, x, max)) return null;
    const step = stepIn(tree, tree.fullWhile(loop).?, x) orelse return null;
    const name = tree.getNodeSource(x);
    return .{
        .offset = tree.tokenStart(tree.firstToken(step)),
        .hint = try arena.print("declare `{s}` a `usize`, or bound it by its type's max as well (`{s} < std.math.maxInt({s})`)", .{
            name, name, tree.getNodeSource(declared),
        }),
        .detail = .{ .counter = .{
            .counter = name,
            .type = tree.getNodeSource(declared),
            .check = tree.getNodeSource(comparison),
            .len = tree.getNodeSource(len),
            .step = tree.getNodeSource(step),
            .max = max,
        } },
    };
}

/// Appends `cond` and, through parentheses and `and`, every condition it
/// joins: each of which must hold for the loop to go on.
fn conjuncts(arena: Allocator, tree: *const Ast, cond: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    const n = ints.unparen(tree, cond);
    if (tree.nodeTag(n) == .bool_and) {
        const lhs, const rhs = tree.nodeData(n).node_and_node;
        try conjuncts(arena, tree, lhs, out);
        try conjuncts(arena, tree, rhs, out);
        return;
    }
    try out.append(arena, n);
}

/// `x` and the `.len` of `x < e`, `x <= e`, `e > x` or `e >= x`, with `x` a
/// name and `e` a `.len` or arithmetic on one.
fn againstLen(tree: *const Ast, comparison: Node.Index) ?struct { Node.Index, Node.Index } {
    const lhs, const rhs = switch (tree.nodeTag(comparison)) {
        .less_than, .less_or_equal => tree.nodeData(comparison).node_and_node,
        .greater_than, .greater_or_equal => swapped: {
            const l, const r = tree.nodeData(comparison).node_and_node;
            break :swapped .{ r, l };
        },
        else => return null,
    };
    const x = ints.unparen(tree, lhs);
    if (tree.nodeTag(x) != .identifier) return null;
    return .{ x, lenOf(tree, rhs) orelse return null };
}

/// The `.len` that `node` is, or that arithmetic on one starts from
/// (`s.len - 1`).
fn lenOf(tree: *const Ast, node: Node.Index) ?Node.Index {
    var n = ints.unparen(tree, node);
    while (true) switch (tree.nodeTag(n)) {
        .add, .sub, .mul, .div => n = ints.unparen(tree, tree.nodeData(n).node_and_node[0]),
        .field_access => return if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(n).node_and_token[1]), "len")) n else null,
        else => return null,
    };
}

/// Whether `len`, `a.len`, is the length of an array whose type the file
/// writes (`[16]u8`, `*const [N]u8`): known where the code is written, so
/// a counter that fits it is the author's choice and not an accident.
fn arrayLen(t: Types, len: Node.Index) bool {
    const tree = t.tree;
    const of = t.typeOf(tree.nodeData(len).node_and_token[0], 0) orelse return false;
    const array = types.pointee(tree, of) orelse of;
    return switch (tree.nodeTag(ints.unparen(tree, array))) {
        .array_type, .array_type_sentinel => true,
        else => false,
    };
}

/// Whether `loop` indexes or slices the value whose `.len` is `len` with
/// `x`, or arithmetic on it (`t[level]`, `s[i + 1 ..]`): the counter walks
/// that slice, so its length is what the counter has to reach. A counter
/// that only counts the items, a replica's number passed on as a `u8`, has
/// a range of its own.
fn walks(tree: *const Ast, loop: Node.Index, x: Node.Index, len: Node.Index) bool {
    const sliced = tree.nodeData(len).node_and_token[0];
    const first = tree.firstToken(loop);
    const last = tree.lastToken(loop);
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(node);
        if (at < first or at > last) continue;
        if (indexes(tree, node, sliced, x)) return true;
    }
    return false;
}

/// Whether `node` indexes or slices `sliced`, the same tokens, with `x` or
/// arithmetic on it.
fn indexes(tree: *const Ast, node: Node.Index, sliced: Node.Index, x: Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .array_access => {
            const lhs, const index = tree.nodeData(node).node_and_node;
            return sameTokens(tree, ints.unparen(tree, lhs), sliced) and mentions(tree, index, x);
        },
        .slice_open, .slice, .slice_sentinel => {
            const full = tree.fullSlice(node).?;
            if (!sameTokens(tree, ints.unparen(tree, full.ast.sliced), sliced)) return false;
            if (mentions(tree, full.ast.start, x)) return true;
            const end = full.ast.end.unwrap() orelse return false;
            return mentions(tree, end, x);
        },
        else => return false,
    }
}

/// Whether `node` is `x`, the same tokens, or arithmetic with it as an
/// operand (`i + 1`, `2 * i`).
fn mentions(tree: *const Ast, node: Node.Index, x: Node.Index) bool {
    const n = ints.unparen(tree, node);
    return switch (tree.nodeTag(n)) {
        .add, .sub, .mul, .add_wrap, .sub_wrap, .mul_wrap => {
            const lhs, const rhs = tree.nodeData(n).node_and_node;
            return mentions(tree, lhs, x) or mentions(tree, rhs, x);
        },
        else => sameTokens(tree, n, x),
    };
}

/// Whether `loop` compares `x`, the same tokens, with a number literal of
/// at most `max` anywhere in it, a test that can stop the counter short of
/// overflowing: `i < 16` in its condition, `if (i == 15) break;` in its
/// body.
fn boundedIn(tree: *const Ast, loop: Node.Index, x: Node.Index, max: u64) bool {
    const first = tree.firstToken(loop);
    const last = tree.lastToken(loop);
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(node)) {
            .less_than, .greater_than, .less_or_equal, .greater_or_equal, .equal_equal, .bang_equal => {},
            else => continue,
        }
        const at = tree.nodeMainToken(node);
        if (at < first or at > last) continue;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        const l = ints.unparen(tree, lhs);
        const r = ints.unparen(tree, rhs);
        if (literalAgainst(tree, l, r, x, max) or literalAgainst(tree, r, l, x, max)) return true;
    }
    return false;
}

/// Whether `side` is `x`, the same tokens, and `other` a number literal of
/// at most `max`, or one that does not read as a number.
fn literalAgainst(tree: *const Ast, side: Node.Index, other: Node.Index, x: Node.Index, max: u64) bool {
    if (tree.nodeTag(other) != .number_literal or !sameTokens(tree, side, x)) return false;
    const value = std.fmt.parseInt(u64, tree.tokenSlice(tree.nodeMainToken(other)), 0) catch return true;
    return value <= max;
}

/// The first `x += k` in `loop`'s continue expression or body, `x` the
/// same tokens.
fn stepIn(tree: *const Ast, loop: Ast.full.While, x: Node.Index) ?Node.Index {
    const first = tree.firstToken(loop.ast.cont_expr.unwrap() orelse loop.ast.then_expr);
    const last = tree.lastToken(loop.ast.then_expr);
    var step: ?Node.Index = null;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .assign_add) continue;
        const at = tree.nodeMainToken(node);
        if (at < first or at > last) continue;
        if (!sameTokens(tree, ints.unparen(tree, tree.nodeData(node).node_and_node[0]), x)) continue;
        if (step == null or at < tree.nodeMainToken(step.?)) step = node;
    }
    return step;
}

/// Whether `a` and `b` are the same tokens.
fn sameTokens(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    const a_first = tree.firstToken(a);
    const b_first = tree.firstToken(b);
    const len = tree.lastToken(a) - a_first;
    if (tree.lastToken(b) - b_first != len) return false;
    for (0..len + 1) |k| {
        const p: Ast.TokenIndex = @intCast(a_first + k);
        const q: Ast.TokenIndex = @intCast(b_first + k);
        if (tree.tokenTag(p) != tree.tokenTag(q)) return false;
        if (!std.mem.eql(u8, tree.tokenSlice(p), tree.tokenSlice(q))) return false;
    }
    return true;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col step (counter type, check)`, in source order.
fn expectCounters(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var findings: std.ArrayList(Finding) = .empty;
    try check(arena_state.allocator(), &tree, &findings);
    std.mem.sort(Finding, findings.items, {}, struct {
        fn before(_: void, a: Finding, b: Finding) bool {
            return a.offset < b.offset;
        }
    }.before);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (findings.items) |finding| {
        const loc = report.location(source, finding.offset);
        const c = finding.detail.counter;
        try out.writer.print("{d}:{d} {s} ({s} {s}, {s})\n", .{ loc.line + 1, loc.column + 1, c.step, c.counter, c.type, c.check });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a narrow counter stepped while it is less than a .len (#204)" {
    try expectCounters(
        \\fn headingLevel(line: []const u8) ?u8 {
        \\    var level: u8 = 0;
        \\    while (level < line.len and line[level] == '#') level += 1;
        \\    if (level == 0 or level > 6) return null;
        \\    return level;
        \\}
        \\fn cont(s: []const u8) u16 {
        \\    var i: u16 = 0;
        \\    while (i < s.len) : (i += 1) { _ = s[i]; }
        \\    return i;
        \\}
        \\fn reversed(s: []const u8) void {
        \\    var i: u8 = 0;
        \\    while (s.len - 1 >= i) { _ = (s)[(i + 1)..]; i += 2; }
        \\}
        \\fn made(s: []const u8) void {
        \\    var i = @as(u16, 0);
        \\    while ((i <= s.len)) : ({ i += 1; }) { _ = s[0 .. 2 * i]; }
        \\}
        \\fn nested(s: []const u8) void {
        \\    var i: u8 = 0;
        \\    while (i < s.len) {
        \\        while (i < s.len and s[i] == ' ') i += 1;
        \\        i += 1;
        \\    }
        \\}
        \\fn outOfRange(s: []const u8) void { var i: u8 = 0; while (i < 300 and i < s.len) : (i += 1) { _ = s[i]; } }
        \\fn field(self: *Screen) void { var i: u16 = 0; while (i < self.buf.len) { const c = self.buf[i]; i += c.width; } }
    ,
        \\3:53 level += 1 (level u8, level < line.len)
        \\9:26 i += 1 (i u16, i < s.len)
        \\14:50 i += 2 (i u8, s.len - 1 >= i)
        \\18:31 i += 1 (i u16, i <= s.len)
        \\23:43 i += 1 (i u8, i < s.len)
        \\27:85 i += 1 (i u8, i < s.len)
        \\28:98 i += c.width (i u16, i < self.buf.len)
        \\
    );
}

test "not a narrow counter: wide, wrapping, bounded, an array's length, not walking the slice, or no step" {
    try expectCounters(
        \\fn wide(s: []const u8) void { var i: usize = 0; while (i < s.len) : (i += 1) { _ = s[i]; } }
        \\fn words(s: []const u8) void { var i: u32 = 0; while (i < s.len) : (i += 1) { _ = s[i]; } }
        \\fn signed(s: []const u8) void { var i: i8 = 0; while (i < s.len) : (i += 1) { _ = s[i]; } }
        \\fn wrapping(s: []const u8) void { var i: u8 = 0; while (i < s.len) : (i +%= 1) { _ = s[i]; } }
        \\fn bounded(s: []const u8) void { var i: u8 = 0; while (i < 16 and i < s.len) : (i += 1) { _ = s[i]; } }
        \\fn inBody(s: []const u8) void { var i: u8 = 0; while (i < s.len) : (i += 1) { if (i == 15) break; _ = s[i]; } }
        \\fn array(a: [16]u8) void { var i: u8 = 0; while (i < a.len) : (i += 1) { _ = a[i]; } }
        \\fn pointer(a: *const [16]u8) void { var i: u8 = 0; while (i < a.len) : (i += 1) { _ = a[i]; } }
        \\fn noStep(s: []const u8) void { var i: u8 = 0; while (i < s.len) : (j += 1) { _ = s[i]; } }
        \\fn other(s: []const u8) void { var i: u8 = 0; var j: usize = 0; while (j < s.len) : (i += 1) { _ = s[i]; } }
        \\fn notLen(s: []const u8, n: usize) void { var i: u8 = 0; while (i < n) : (i += 1) { _ = s[i]; } }
        \\fn counts(c: *const Cluster) void { var r: u8 = 0; while (r < c.replicas.len) : (r += 1) { c.log(r); } }
        \\fn otherSlice(v: View, p: []const u8) void { var x: u16 = 0; while (x < v.len) : (x += 1) { _ = p[x]; } }
        \\fn called(s: []const u8) void { var i: u8 = 0; while (i < s.len) : (i += 1) { _ = s[f(i)]; } }
    , "");
}
