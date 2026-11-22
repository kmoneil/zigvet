//! Rule twenty-three, wrap: a test for unsigned wraparound after a plain
//! `+`, which cannot wrap.
//!
//!     const end = off.* + n;
//!     if (end < off.* or end > src.len) return null;
//!
//! `end < off.*` is C's test for a sum that wrapped. Zig's `+` does not
//! wrap: an overflow panics in Debug and ReleaseSafe and is undefined
//! behavior in ReleaseFast and ReleaseSmall, where LLVM, told the add does
//! not wrap, may delete the test. So the test is never true. On a 64-bit
//! target the sum seldom overflows and another check does the work; on a
//! 32-bit one (wasm32), the input the test was written for panics instead
//! of being refused.
//!
//! What is reported is a comparison `s < a`, `s < b`, `a > s` or `b > s`,
//! where `s` is `a + b`, written in place or as a local's initializer
//! (`const end = start + len;`), and `a` and `b` are names or places
//! (`off.*`, `self.pos`), compared by their tokens. Not when anything is
//! assigned to the operand or the local, or its address taken, between the
//! sum and the test (in a loop around the test and not the sum, anywhere
//! in that loop). The sum has to be shown unsigned and not signed or a
//! float, by what the syntax shows: a declared type (`usize`, `u32`,
//! through a pointer, `off: *usize`, or a field of a struct the file
//! declares), `.len`, `@as(u32, x)`, `std.mem.readInt(u32, ...)`, the
//! local's annotation, or the local used to slice or index. A signed `b`
//! makes `s < a` a real question, whether `b` was negative. `+%` and `+|`
//! are not `+`, and `s <= a` asks also whether `b` is 0.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const expect = @import("expect.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const ints = @import("ints.zig");
const types = @import("types.zig");
const Types = types.Types;

/// Appends a finding for every test of a plain sum for wraparound.
/// Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var t: ?Types = null;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const tag = tree.nodeTag(node);
        if (tag != .less_than and tag != .greater_than) continue;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        // `s < a` or `a > s`: the sum, then what it should be no less than.
        const sum_side, const operand_side = if (tag == .less_than) .{ lhs, rhs } else .{ rhs, lhs };
        const operand = unparen(tree, operand_side);
        if (!isPlace(tree, operand)) continue;
        if (t == null) t = try .init(arena, tree);
        const sum = sumOf(t.?, sum_side) orelse continue;
        const a, const b = tree.nodeData(sum.add).node_and_node;
        if (!sameTokens(tree, operand, unparen(tree, a)) and !sameTokens(tree, operand, unparen(tree, b))) continue;
        const function = enclosingFn(tree, t.?.parents, node) orelse continue;
        if (changedBetween(tree, t.?.parents, function, sum.add, node, operand, sum.local)) continue;
        if (!unsignedSum(t.?, sum, function)) continue;
        try findings.append(arena, .{
            .offset = tree.tokenStart(tree.firstToken(node)),
            .hint = hint,
            .detail = .{ .wrap = .{ .check = tree.getNodeSource(node), .sum = tree.getNodeSource(sum.add) } },
        });
    }
}

const hint = "test before adding, with `std.math.add` or `@addWithOverflow`, or sum in a wider type and compare that";

const Sum = struct {
    /// The `a + b`.
    add: Node.Index,
    /// The local it initializes, as named in the test; null for a sum
    /// written in the test.
    local: ?Node.Index,
};

/// `node` as a plain sum: `a + b` itself, or a local whose initializer it is.
fn sumOf(t: Types, node: Node.Index) ?Sum {
    const tree = t.tree;
    const n = unparen(tree, node);
    switch (tree.nodeTag(n)) {
        .add => return .{ .add = n, .local = null },
        .identifier => {
            const init = unparen(tree, t.localInit(n) orelse return null);
            if (tree.nodeTag(init) != .add) return null;
            return .{ .add = init, .local = n };
        },
        else => return null,
    }
}

/// Whether anything is assigned to `operand` or to the sum's local, or
/// either's address taken, after `add` and before `test_node`, or anywhere
/// in a loop around the test and not around the sum, whose next turn runs
/// the test again.
fn changedBetween(tree: *const Ast, parents: []const Node.OptionalIndex, function: Node.Index, add: Node.Index, test_node: Node.Index, operand: Node.Index, local: ?Node.Index) bool {
    const start, const end = between(tree, parents, function, add, test_node);
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(node);
        if (at < start or at > end) continue;
        const target = switch (tree.nodeTag(node)) {
            .address_of => tree.nodeData(node).node,
            // What it assigns is not one place; any counts.
            .assign_destructure => return true,
            else => |tag| if (std.mem.startsWith(u8, @tagName(tag), "assign")) tree.nodeData(node).node_and_node[0] else continue,
        };
        if (overlaps(tree, unparen(tree, target), operand)) return true;
        if (local) |l| if (overlaps(tree, unparen(tree, target), l)) return true;
    }
    return false;
}

/// The tokens from `add` to `test_node`, widened to the whole of each loop
/// in `function` around the test and not around the sum.
fn between(tree: *const Ast, parents: []const Node.OptionalIndex, function: Node.Index, add: Node.Index, test_node: Node.Index) struct { Ast.TokenIndex, Ast.TokenIndex } {
    const sum_at = tree.firstToken(add);
    var start = sum_at;
    var end = tree.firstToken(test_node);
    var up = parents[@backingInt(test_node)].unwrap();
    while (up) |parent| : (up = parents[@backingInt(parent)].unwrap()) {
        if (parent == function) break;
        switch (tree.nodeTag(parent)) {
            .while_simple, .while_cont, .@"while", .for_simple, .@"for" => {
                const first = tree.firstToken(parent);
                const last = tree.lastToken(parent);
                if (sum_at >= first and sum_at <= last) continue;
                start = @min(start, first);
                end = @max(end, last);
            },
            else => {},
        }
    }
    return .{ start, end };
}

/// Whether a store to `target` can change `place`: both reached from the
/// same name, one a part of the other, or `target` all of what a pointer
/// points at (`self.* = ...`).
fn overlaps(tree: *const Ast, target: Node.Index, place: Node.Index) bool {
    const target_root = rootName(tree, target) orelse return false;
    const place_root = rootName(tree, place) orelse return false;
    if (!std.mem.eql(u8, target_root, place_root)) return false;
    const target_text = tree.getNodeSource(target);
    const place_text = tree.getNodeSource(place);
    return std.mem.startsWith(u8, place_text, target_text) or std.mem.startsWith(u8, target_text, place_text) or
        std.mem.endsWith(u8, target_text, ".*");
}

/// The name a place is reached from: `self` of `self.pos` or `off` of
/// `off.*`.
fn rootName(tree: *const Ast, node: Node.Index) ?[]const u8 {
    var n = node;
    while (true) switch (tree.nodeTag(n)) {
        .identifier => return tree.tokenSlice(tree.nodeMainToken(n)),
        .grouped_expression, .field_access, .unwrap_optional => n = tree.nodeData(n).node_and_token[0],
        .deref => n = tree.nodeData(n).node,
        .array_access => n = tree.nodeData(n).node_and_node[0],
        else => return null,
    };
}

/// Whether `node` is a name or a place reached from one through fields,
/// a pointer or an optional: what reads the same twice with nothing
/// assigned between.
fn isPlace(tree: *const Ast, node: Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .identifier => true,
        .grouped_expression, .field_access, .unwrap_optional => isPlace(tree, tree.nodeData(node).node_and_token[0]),
        .deref => isPlace(tree, tree.nodeData(node).node),
        else => false,
    };
}

/// Whether `a` and `b` are the same tokens.
fn sameTokens(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    const a_first = tree.firstToken(a);
    const b_first = tree.firstToken(b);
    const len = tree.lastToken(a) - a_first;
    if (tree.lastToken(b) - b_first != len) return false;
    for (0..len + 1) |k| {
        const x: Ast.TokenIndex = @intCast(a_first + k);
        const y: Ast.TokenIndex = @intCast(b_first + k);
        if (tree.tokenTag(x) != tree.tokenTag(y)) return false;
        if (!std.mem.eql(u8, tree.tokenSlice(x), tree.tokenSlice(y))) return false;
    }
    return true;
}

const unparen = ints.unparen;

fn enclosingFn(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) ?Node.Index {
    var up = parents[@backingInt(node)].unwrap();
    while (up) |parent| : (up = parents[@backingInt(parent)].unwrap()) {
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

/// Whether the syntax shows `sum` unsigned, and nothing in it signed or a
/// float: by its operands (`ints.signOf`), the local's annotation, or the
/// local used, in `function`, to slice or index, which takes a `usize`.
fn unsignedSum(t: Types, sum: Sum, function: Node.Index) bool {
    const tree = t.tree;
    const a, const b = tree.nodeData(sum.add).node_and_node;
    var sign = ints.signOf(t, a, 0).with(ints.signOf(t, b, 0));
    if (sum.local) |local| {
        if (t.bindingType(local, 0)) |declared| sign = sign.with(ints.signOfType(tree, declared));
        if (sign == .unknown and indexes(tree, function, tree.tokenSlice(tree.nodeMainToken(local)), tree.firstToken(sum.add))) sign = .unsigned;
    }
    return sign == .unsigned;
}

/// Whether the name `name` is a slice's bound or an index in `function`
/// after token `after`.
fn indexes(tree: *const Ast, function: Node.Index, name: []const u8, after: Ast.TokenIndex) bool {
    const last = tree.lastToken(function);
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(node);
        if (at <= after or at > last) continue;
        var bounds: [3]?Node.Index = .{ null, null, null };
        switch (tree.nodeTag(node)) {
            .slice_open, .slice, .slice_sentinel => {
                const full = tree.fullSlice(node).?;
                bounds = .{ full.ast.start, full.ast.end.unwrap(), null };
            },
            .array_access => bounds[0] = tree.nodeData(node).node_and_node[1],
            else => continue,
        }
        for (bounds) |bound| {
            const n = ints.unparen(tree, bound orelse continue);
            if (tree.nodeTag(n) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(n)), name)) return true;
        }
    }
    return false;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col check | sum`, in source order.
fn expectWraps(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var findings: std.ArrayList(Finding) = .empty;
    try check(arena_state.allocator(), &tree, &findings);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (findings.items) |finding| {
        const loc = report.location(source, finding.offset);
        const w = finding.detail.wrap;
        try out.writer.print("{d}:{d} {s} | {s}\n", .{ loc.line + 1, loc.column + 1, w.check, w.sum });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a wraparound test after a plain + (#198)" {
    try expectWraps(
        \\fn take(src: []const u8, off: *usize, n: u32) ?[]const u8 {
        \\    const end = off.* + n;
        \\    if (end < off.* or end > src.len) return null;
        \\    const s = src[off.*..end];
        \\    off.* = end;
        \\    return s;
        \\}
        \\fn inPlace(a: usize, b: usize) bool { return a + b < a; }
        \\fn flipped(a: u32, b: u32) bool { return b > (a + b); }
        \\fn annotated(a: A, b: B) bool { const s: u64 = a + b; return s < b; }
        \\fn indexed(buf: []const u8, a: A, b: B) u8 { const s = a + b; if (s < a) return 0; return buf[s]; }
        \\fn local(xs: []const u8, at: usize) bool { const end = at + xs.len; return end < at; }
    ,
        \\3:9 end < off.* | off.* + n
        \\8:46 a + b < a | a + b
        \\9:42 b > (a + b) | a + b
        \\10:62 s < b | a + b
        \\11:67 s < a | a + b
        \\12:76 end < at | at + xs.len
        \\
    );
}

test "not a wraparound test: signed, unknown, wrapping, or changed between" {
    try expectWraps(
        \\fn signed(a: usize, d: isize) bool { const s = a + d; return s < a; }
        \\fn float(x: f64, y: f64) bool { return x + y < x; }
        \\fn unknown(a: A, b: B) bool { const s = a + b; return s < a; }
        \\fn wrapping(a: u32, b: u32) bool { return a +% b < a; }
        \\fn saturating(a: u32, b: u32) bool { return a +| b < a; }
        \\fn orEqual(a: u32, b: u32) bool { return a + b <= a; }
        \\fn other(a: u32, b: u32, c: u32) bool { return a + b < c; }
        \\fn moved(a: *u32, b: u32) bool { const s = a.* + b; a.* = 0; return s < a.*; }
        \\fn grown(a: u32, b: u32) bool { var x = a; const s = x + b; x += 1; return s < x; }
        \\fn pointed(a: u32, b: u32) bool { var x = a; const s = x + b; bump(&x); return s < x; }
        \\fn looped(n: u32, b: u32) void { var x: u32 = 0; const s = x + b; while (x < n) { if (s < x) break; x += 1; } }
        \\fn reassigned(a: u32, b: u32) bool { var s = a + b; s = 0; return s < a; }
        \\fn call(a: u32, b: u32) bool { return a + b < f(a); }
    , "");
}
