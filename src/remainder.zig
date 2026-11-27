//! Rule thirty-one, remainder: a remainder taken by hand from a floor
//! division, whose product overflows where `@mod` does not.
//!
//!     return t - @divFloor(t, 86400) * 86400;
//!
//! For a `t` near its type's minimum that is no multiple of the divisor,
//! `@divFloor(t, 86400) * 86400` is below the minimum: a panic in Debug and
//! ReleaseSafe, undefined behavior in ReleaseFast. `@mod(t, 86400)` is the
//! same value everywhere else and cannot overflow. Calendar code does this
//! to split a timestamp into days and a time of day, and the timestamp is
//! often parsed from input, so the minimum is one request away.
//!
//! What is reported is `a - q * d` or `a - d * q`, with plain `-` and `*`,
//! where `q` is `@divFloor(a, d)`, written in place or as a local's
//! initializer (`const days = @divFloor(us, per_day);`), and `a` and `d`
//! are the same tokens in both. `a` has to be a parameter of the function,
//! or a place reached from one (`s.at`, `at.*`), declared a signed integer
//! by what the syntax shows of its type (`ints`), with nothing assigned to
//! it or to the local, nor either's address taken, between the division
//! and the subtraction.
//!
//! A parameter is what the function cannot bound: its caller picks it. A
//! local is what the function computed, and its range is the
//! computation's, which the syntax does not show. Of the hand-written
//! remainders in the corpus, the sixteen of a local are bounded by what
//! made them: the `z` and `y` of Howard Hinnant's date algorithms, from a
//! day count that is itself a quotient or a year widened from an i32, a
//! reading of the wall clock, and pixel offsets. Those are not reported.
//!
//! Also not reported: `@divTrunc`, whose product is never further from
//! zero than `a` and so cannot overflow; an unsigned `a`, a float, or one
//! whose type the file does not show; `-%` and `*%`, which say what
//! happens; and anything outside a function, which is evaluated at compile
//! time.

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
const wrap = @import("wrap.zig");

/// Appends a finding for every remainder taken by hand from a floor
/// division of a signed integer. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var t: ?Types = null;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .sub) continue;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        const product = ints.unparen(tree, rhs);
        if (tree.nodeTag(product) != .mul) continue;
        const a = ints.unparen(tree, lhs);
        if (t == null) t = try .init(arena, tree);
        const x, const y = tree.nodeData(product).node_and_node;
        const quotient = quotientOf(t.?, x, y, a) orelse quotientOf(t.?, y, x, a) orelse continue;
        const function = wrap.enclosingFn(tree, t.?.parents, node) orelse continue;
        if (!isParameter(tree, function, wrap.rootName(tree, a) orelse continue)) continue;
        if (!ints.isSignedInt(tree, ints.declaredType(t.?, a, 0) orelse continue)) continue;
        if (wrap.changedBetween(tree, t.?.parents, function, quotient.call, node, a, quotient.local)) continue;
        const dividend = tree.getNodeSource(a);
        const divisor = tree.getNodeSource(quotient.divisor);
        try findings.append(arena, .{
            .offset = tree.tokenStart(tree.firstToken(node)),
            .hint = try arena.print("write `@mod({s}, {s})`, the same value wherever this one does not overflow", .{ dividend, divisor }),
            .detail = .{ .remainder = .{ .expression = tree.getNodeSource(node), .dividend = dividend, .divisor = divisor } },
        });
    }
}

const Quotient = struct {
    /// The `@divFloor(a, d)`.
    call: Node.Index,
    /// The `d` of it.
    divisor: Node.Index,
    /// The local it initializes, as named in the product; null for a
    /// division written there.
    local: ?Node.Index,
};

/// `q` as the floor division of `a` by `d`: `@divFloor(a, d)` itself, or a
/// local whose initializer it is, with `a` and `d` the same tokens as its
/// operands.
fn quotientOf(t: Types, q: Node.Index, d: Node.Index, a: Node.Index) ?Quotient {
    const tree = t.tree;
    const n = ints.unparen(tree, q);
    const call, const local: ?Node.Index = switch (tree.nodeTag(n)) {
        .builtin_call_two, .builtin_call_two_comma => .{ n, null },
        .identifier => .{ ints.unparen(tree, t.localInit(n) orelse return null), n },
        else => return null,
    };
    var buffer: [2]Node.Index = undefined;
    const params = tree.builtinCallParams(&buffer, call) orelse return null;
    if (params.len != 2 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(call)), "@divFloor")) return null;
    if (!wrap.sameTokens(tree, ints.unparen(tree, params[0]), a)) return null;
    if (!wrap.sameTokens(tree, ints.unparen(tree, params[1]), ints.unparen(tree, d))) return null;
    return .{ .call = call, .divisor = params[1], .local = local };
}

/// Whether `name` is a parameter of `function`.
fn isParameter(tree: *const Ast, function: Node.Index, name: []const u8) bool {
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]).?;
    var params = proto.iterate(tree);
    while (params.next()) |param| {
        if (std.mem.eql(u8, tree.tokenSlice(param.name_token orelse continue), name)) return true;
    }
    return false;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col expression | dividend | divisor`, in source order.
fn expectRemainders(source: [:0]const u8, expected: []const u8) !void {
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
        const r = finding.detail.remainder;
        try out.writer.print("{d}:{d} {s} | {s} | {s}\n", .{ loc.line + 1, loc.column + 1, r.expression, r.dividend, r.divisor });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a remainder by hand from a floor division (#239)" {
    try expectRemainders(
        \\fn secondsOfDay(t: i64) i64 { return t - @divFloor(t, 86400) * 86400; }
        \\fn flipped(t: i64) i64 { return t - 86400 * @divFloor(t, 86400); }
        \\fn split(us: i64) u64 { const days = @divFloor(us, std.time.us_per_day); const rest: u64 = @intCast(us - days * std.time.us_per_day); return rest; }
        \\fn grouped(t: isize, d: isize) isize { return (t) - (@divFloor(t, d) * (d)); }
        \\fn field(s: *const Stamp) i64 { return s.at - @divFloor(s.at, day) * day; }
        \\fn pointed(at: *const i32) i32 { const q = @divFloor(at.*, 7); return at.* - q * 7; }
        \\const Stamp = struct { at: i64 };
    ,
        \\1:38 t - @divFloor(t, 86400) * 86400 | t | 86400
        \\2:33 t - 86400 * @divFloor(t, 86400) | t | 86400
        \\3:101 us - days * std.time.us_per_day | us | std.time.us_per_day
        \\4:47 (t) - (@divFloor(t, d) * (d)) | t | d
        \\5:40 s.at - @divFloor(s.at, day) * day | s.at | day
        \\6:71 at.* - q * 7 | at.* | 7
        \\
    );
}

test "not a remainder that overflows: truncated, unsigned, a float, unknown, a local, wrapping, another operand, changed between" {
    try expectRemainders(
        \\fn truncated(t: i64) i64 { return t - @divTrunc(t, 86400) * 86400; }
        \\fn unsigned(t: u64) u64 { return t - @divFloor(t, 86400) * 86400; }
        \\fn float(x: f64) f64 { return x - @divFloor(x, 360.0) * 360.0; }
        \\fn unknown(t: T) T { return t - @divFloor(t, 86400) * 86400; }
        \\fn wrappingSub(t: i64) i64 { return t -% @divFloor(t, 86400) * 86400; }
        \\fn wrappingMul(t: i64) i64 { return t - @divFloor(t, 86400) *% 86400; }
        \\fn otherDivisor(t: i64) i64 { return t - @divFloor(t, 86400) * 3600; }
        \\fn otherDividend(t: i64, u: i64) i64 { return u - @divFloor(t, 86400) * 86400; }
        \\fn sum(t: i64) i64 { return t + @divFloor(t, 86400) * 86400; }
        \\fn moved(s: *Stamp) i64 { const days = @divFloor(s.at, 86400); s.at += 1; return s.at - days * 86400; }
        \\fn reassigned(t: i64) i64 { var days = @divFloor(t, 86400); days = 0; return t - days * 86400; }
        \\fn widened(year: i32) u64 { const y: i64 = @as(i64, year) - 1; const era: i64 = @divFloor(y, 400); return @intCast(y - era * 400); }
        \\fn ofQuotient(us: i64) u64 { const z: i64 = @divFloor(us, per_day) + 719468; const era = @divFloor(z, 146097); return @intCast(z - era * 146097); }
        \\fn global() i64 { return epoch - @divFloor(epoch, 86400) * 86400; }
        \\const Stamp = struct { at: i64 };
        \\var epoch: i64 = 0;
        \\fn call(c: *Clock) i64 { return c.now() - @divFloor(c.now(), 86400) * 86400; }
        \\const at_comptime: i64 = big - @divFloor(big, 86400) * 86400;
        \\const big: i64 = 1 << 40;
    , "");
}
