//! Rule twenty-four, narrow: a narrow unsigned integer plus or times a
//! constant as a slice's bound or an index, computed in its own narrow
//! type.
//!
//!     if (offset == 0 or @as(usize, offset) + 6 > sub.len) return null;
//!     if (std.mem.readInt(u16, sub[offset + 4 ..][0..2], .big) != 0x8000) return null;
//!
//! Zig computes `offset + 4` in `offset`'s type, `u16`, and widens only the
//! result to the `usize` the slice takes. The check above is widened and
//! passes for `offset` 0xFFFC to 0xFFFF in a slice of 64 KB or more; the
//! index is not, and overflows: a panic in Debug and ReleaseSafe, the
//! wrong bytes in ReleaseFast and ReleaseSmall.
//!
//! What is reported is `x + k`, `k + x`, `x * k` or `k * x`, with `k` a
//! number literal and `x` declared an unsigned integer narrower than 32
//! bits (`u8`, `u16`; `ints.declaredType`), anywhere in a slice's start or
//! end or an index (`sub[x + 4 ..]`, `points[start .. end + 1]`,
//! `table[i * 2]`), through the arithmetic around it but not into a call
//! or a cast. Only in a function that also treats `x` itself, the same
//! tokens, as an offset into a slice longer than its type counts: it
//! widens it (`@as(usize, x)`, or any wider unsigned type, or a local
//! declared wider with `x` as its initializer, `const end: usize = x;`),
//! or compares it with or subtracts it from a `.len` (`x > sub.len`,
//! `sub.len - x`). And not when the function compares `x` with a number
//! literal (`if (level > 6) return null;`), which bounds it. A narrow
//! index written alone is as often bounded by a loop or a table's size:
//! over the standard library, eleven application repos and fourteen
//! public projects, 29 of them, none a bug. Not `+%`, which wraps on
//! purpose.

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

/// Appends a finding for every narrow sum or product of a constant that
/// slices or indexes. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var t: ?Types = null;
    var candidates: std.ArrayList(Node.Index) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        candidates.clearRetainingCapacity();
        switch (tree.nodeTag(node)) {
            .slice_open, .slice, .slice_sentinel => {
                const full = tree.fullSlice(node).?;
                try arithmetic(arena, tree, full.ast.start, &candidates);
                if (full.ast.end.unwrap()) |end| try arithmetic(arena, tree, end, &candidates);
            },
            .array_access => try arithmetic(arena, tree, tree.nodeData(node).node_and_node[1], &candidates),
            else => continue,
        }
        for (candidates.items) |candidate| {
            const x, const k = withConstant(tree, candidate) orelse continue;
            if (t == null) t = try .init(arena, tree);
            const declared = ints.declaredType(t.?, x, 0) orelse continue;
            const bits = ints.unsignedBits(tree, declared) orelse continue;
            if (bits >= 32) continue;
            const function = enclosingFn(tree, t.?.parents, candidate) orelse continue;
            if (!offsetInto(t.?, function, x, bits)) continue;
            try findings.append(arena, .{
                .offset = tree.tokenStart(tree.firstToken(candidate)),
                .hint = try hint(arena, tree, candidate, x, k),
                .detail = .{ .narrow = .{
                    .expression = tree.getNodeSource(candidate),
                    .operand = tree.getNodeSource(x),
                    .type = tree.getNodeSource(declared),
                    .overflows_at = overflowsAt(tree, candidate, k, bits),
                } },
            });
        }
    }
}

/// The fix, written out: `@as(usize, offset) + 4` for `offset + 4`.
fn hint(arena: Allocator, tree: *const Ast, node: Node.Index, x: Node.Index, k: Node.Index) Allocator.Error![]const u8 {
    const op = tree.tokenSlice(tree.nodeMainToken(node));
    const name = tree.getNodeSource(x);
    const constant = tree.getNodeSource(k);
    const fixed = if (tree.firstToken(x) < tree.firstToken(k))
        try arena.print("@as(usize, {s}) {s} {s}", .{ name, op, constant })
    else
        try arena.print("{s} {s} @as(usize, {s})", .{ constant, op, name });
    return arena.print("widen it before the arithmetic, `{s}`, or declare `{s}` a `usize`", .{ fixed, name });
}

/// Appends `node` and every operand under it, through `+`, `-`, `*` and
/// parentheses, that is itself a plain `+` or `*`: what is computed in the
/// operands' own type before the index takes it. Not into a call or a
/// cast, whose result has a type of its own.
fn arithmetic(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    switch (tree.nodeTag(node)) {
        .grouped_expression => try arithmetic(arena, tree, tree.nodeData(node).node_and_token[0], out),
        .add, .mul => {
            try out.append(arena, node);
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            try arithmetic(arena, tree, lhs, out);
            try arithmetic(arena, tree, rhs, out);
        },
        .sub => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            try arithmetic(arena, tree, lhs, out);
            try arithmetic(arena, tree, rhs, out);
        },
        else => {},
    }
}

/// `x` and `k` of `x + k`, `k + x`, `x * k` or `k * x`, with `k` a number
/// literal and `x` anything else.
fn withConstant(tree: *const Ast, node: Node.Index) ?struct { Node.Index, Node.Index } {
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    const l = ints.unparen(tree, lhs);
    const r = ints.unparen(tree, rhs);
    const l_literal = tree.nodeTag(l) == .number_literal;
    const r_literal = tree.nodeTag(r) == .number_literal;
    if (l_literal == r_literal) return null;
    return if (r_literal) .{ l, r } else .{ r, l };
}

/// The first value of the operand at which `node`, `x + k` or `x * k` in
/// a type of `bits` bits, overflows, when `k` reads as a number.
fn overflowsAt(tree: *const Ast, node: Node.Index, k: Node.Index, bits: u16) ?u64 {
    const constant = std.fmt.parseInt(u64, tree.tokenSlice(tree.nodeMainToken(k)), 0) catch return null;
    const max = (@as(u64, 1) << @intCast(bits)) - 1;
    if (constant == 0 or constant > max) return null;
    return switch (tree.nodeTag(node)) {
        .add => max - constant + 1,
        .mul => max / constant + 1,
        else => null,
    };
}

/// Whether `function` treats `x`, the same tokens, as an offset into a
/// slice longer than its type counts, and bounds it by no constant: it
/// widens `x` somewhere (`said`), or compares it with or subtracts it from
/// a `.len`, and never compares it with a number literal (`x > 6`).
fn offsetInto(t: Types, function: Node.Index, x: Node.Index, bits: u16) bool {
    const tree = t.tree;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    var offset = false;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(node);
        if (at < first or at > last) continue;
        switch (said(tree, node, x, bits)) {
            .nothing => {},
            .offset => offset = true,
            .bounded => return false,
        }
    }
    return offset;
}

/// What `node` says of `x`: that it is an offset into a slice, `@as(usize,
/// x)` (any wider unsigned type), a local declared wider with `x` as its
/// initializer, `x > sub.len` or `sub.len - x`; or that it is bounded by a
/// constant, `x > 6`, which keeps a small sum from overflowing.
fn said(tree: *const Ast, node: Node.Index, x: Node.Index, bits: u16) enum { nothing, offset, bounded } {
    const to, const value = switch (tree.nodeTag(node)) {
        .less_than, .greater_than, .less_or_equal, .greater_or_equal, .sub => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const l = ints.unparen(tree, lhs);
            const r = ints.unparen(tree, rhs);
            if (tree.nodeTag(node) != .sub and (literalAgainst(tree, l, r, x) or literalAgainst(tree, r, l, x))) return .bounded;
            return if (againstLen(tree, l, r, x) or againstLen(tree, r, l, x)) .offset else .nothing;
        },
        .builtin_call_two, .builtin_call_two_comma => as: {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as")) return .nothing;
            var buffer: [2]Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, node).?;
            if (params.len != 2) return .nothing;
            break :as .{ params[0], params[1] };
        },
        .simple_var_decl, .local_var_decl, .aligned_var_decl => decl: {
            const decl = tree.fullVarDecl(node).?;
            break :decl .{ decl.ast.type_node.unwrap() orelse return .nothing, decl.ast.init_node.unwrap() orelse return .nothing };
        },
        else => return .nothing,
    };
    if (!wider(tree, to, bits)) return .nothing;
    return if (sameTokens(tree, ints.unparen(tree, value), x)) .offset else .nothing;
}

/// Whether `side` is `x`, the same tokens, and `other` a number literal.
fn literalAgainst(tree: *const Ast, side: Node.Index, other: Node.Index, x: Node.Index) bool {
    return tree.nodeTag(other) == .number_literal and sameTokens(tree, side, x);
}

/// Whether `side` is `x`, the same tokens, and `other` a `.len`, or
/// arithmetic on one (`sub.len - 4`).
fn againstLen(tree: *const Ast, side: Node.Index, other: Node.Index, x: Node.Index) bool {
    if (!sameTokens(tree, side, x)) return false;
    var n = ints.unparen(tree, other);
    while (true) switch (tree.nodeTag(n)) {
        .add, .sub, .mul, .div => n = ints.unparen(tree, tree.nodeData(n).node_and_node[0]),
        .field_access => return std.mem.eql(u8, tree.tokenSlice(tree.nodeData(n).node_and_token[1]), "len"),
        else => return false,
    };
}

/// Whether `type_expr` is `usize` or an unsigned type of more than `bits`
/// bits.
fn wider(tree: *const Ast, type_expr: Node.Index, bits: u16) bool {
    if (ints.unsignedBits(tree, type_expr)) |b| return b > bits;
    const n = ints.unparen(tree, type_expr);
    return tree.nodeTag(n) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(n)), "usize");
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

fn enclosingFn(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) ?Node.Index {
    var up = parents[@backingInt(node)].unwrap();
    while (up) |parent| : (up = parents[@backingInt(parent)].unwrap()) {
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col expression (operand type, overflows at n)`, in source order.
fn expectNarrows(source: [:0]const u8, expected: []const u8) !void {
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
        const n = finding.detail.narrow;
        try out.writer.print("{d}:{d} {s} ({s} {s}, overflows at {?d})\n", .{ loc.line + 1, loc.column + 1, n.expression, n.operand, n.type, n.overflows_at });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a narrow sum or product as a bound or an index, widened elsewhere (#197)" {
    try expectNarrows(
        \\pub fn tagged(sub: []const u8, offset: u16) ?u32 {
        \\    if (offset == 0 or @as(usize, offset) + 6 > sub.len) return null;
        \\    if (std.mem.readInt(u16, sub[offset + 4 ..][0..2], .big) != 0x8000) return null;
        \\    return std.mem.readInt(u32, sub[offset..][0..4], .big);
        \\}
        \\pub fn contours(points: []const u8, ends: []const u16, out: []usize) void {
        \\    var start: usize = 0;
        \\    for (ends, 0..) |end, i| {
        \\        out[i] = points[start .. end + 1].len;
        \\        start = @as(usize, end) + 1;
        \\    }
        \\}
        \\fn product(t: []const u8, i: u8) u8 { const w: u32 = i; return t[w + i * 2]; }
        \\fn read(b: []const u8) u8 { const n = std.mem.readInt(u16, b[0..2], .little); _ = @as(u64, n); return b[2 + n]; }
        \\fn at(sub: []const u8, off: u16) ?u16 {
        \\    if (off > sub.len or sub.len - off < 4) return null;
        \\    return std.mem.readInt(u16, sub[off + 2 ..][0..2], .big);
        \\}
    ,
        \\3:34 offset + 4 (offset u16, overflows at 65532)
        \\9:34 end + 1 (end u16, overflows at 65535)
        \\13:70 i * 2 (i u8, overflows at 128)
        \\14:105 2 + n (n u16, overflows at 65534)
        \\17:37 off + 2 (off u16, overflows at 65534)
        \\
    );
}

test "not a narrow sum: widened, wide, wrapping, never widened, or not an index" {
    try expectNarrows(
        \\fn wide(sub: []const u8, offset: u16) u8 { return sub[@as(usize, offset) + 4]; }
        \\fn usizes(sub: []const u8, offset: usize) u8 { _ = @as(usize, offset); return sub[offset + 4]; }
        \\fn words(sub: []const u8, offset: u32) u8 { _ = @as(u64, offset); return sub[offset + 4]; }
        \\fn wrapping(sub: []const u8, i: u8) u8 { _ = @as(usize, i); return sub[i +% 1]; }
        \\fn alone(sub: []const u8, i: u8) u8 { return sub[i + 1]; }
        \\fn other(sub: []const u8, i: u8, j: u8) u8 { _ = @as(usize, j); return sub[i + 1]; }
        \\fn notIndex(i: u16) u16 { _ = @as(usize, i); return i + 1; }
        \\fn signed(sub: []const u8, i: i16) u8 { _ = @as(isize, i); return sub[@intCast(i + 1)]; }
        \\fn narrower(sub: []const u8, i: u16) u8 { _ = @as(u8, @truncate(i)); return sub[i + 1]; }
        \\fn called(sub: []const u8, i: u16) u8 { _ = @as(usize, i); return sub[f(i + 1)]; }
        \\fn bounded(t: []const u8, level: u8) u8 { if (level < t.len and level > 6) return 0; return t[level + 1]; }
        \\fn literalFirst(t: []const u8, level: u8) u8 { if (6 < level or level >= t.len) return 0; return t[level + 1]; }
        \\fn lenOfOther(t: []const u8, i: u8, j: u8) u8 { if (j > t.len) return 0; return t[i + 1]; }
        \\fn sameWidth(t: []const u8, i: u16) u8 { _ = @as(u16, i); return t[i + 1]; }
    , "");
}
