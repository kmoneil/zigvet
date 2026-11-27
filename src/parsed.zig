//! Rule thirty-two, parsed: a full-width signed `parseInt` result in a
//! plain `-` or `+` with nothing bounding it first.
//!
//!     const at = std.fmt.parseInt(i64, timestamp, 10) catch return false;
//!     return @abs(now_s - at) <= tolerance_s;
//!
//! `at` is any value the text holds. For `x - p`, one of `p` at the type's
//! minimum and `p` at its maximum overflows for every `x` but -1, and for
//! `x + p` for every `x` but 0: so whoever writes the text picks an operand
//! that panics in Debug and ReleaseSafe and wraps unseen in ReleaseFast,
//! wherever `x` came from. When the text is a header, a query parameter or
//! a file, that is a remote panic, and a webhook's freshness check that
//! runs before its signature is checked had it.
//!
//! What is reported is `a - b` or `a + b`, with a plain operator, where
//! one operand is the result of a call named `parseInt` whose type is
//! `i64`, `isize` or `i128`: the call itself, under `try` or `catch`, or a
//! local it initializes. The other operand's type has to be no wider, by
//! what the syntax shows. Nothing may be assigned to the local between,
//! and the function may not compare it (`<`, `<=`, `>`, `>=`), hand it to
//! `@min`, `@max` or a `clamp`, or `switch` on it, before the arithmetic:
//! any of those bounds it at one end at least, and a timestamp no less
//! than zero can be taken from another.
//!
//! Not reported: a narrower type (`parseInt(i32, ...)`), whose sum with an
//! `i64` cannot overflow, or an unsigned one, which a later comparison
//! often checks; text of a fixed width under nineteen characters
//! (`text[0..4]`, a year), which cannot spell a value near either end;
//! `-|`, `+|`, `-%`, `+%` and `std.math.sub`, which say what happens; and
//! a parsed value that reaches the arithmetic through a field or another
//! function. A product is not read: `secs * 1000` overflows for more
//! values than a sum does, and the corpus has one, in a tool that reads
//! its own data.

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

/// Appends a finding for every plain sum or difference with an unbounded
/// full-width `parseInt` result as an operand. Everything is allocated
/// with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var t: ?Types = null;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const tag = tree.nodeTag(node);
        if (tag != .sub and tag != .add) continue;
        if (t == null) t = try .init(arena, tree);
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        const value = unbounded(t.?, node, lhs, rhs) orelse unbounded(t.?, node, rhs, lhs) orelse continue;
        const operator = tree.tokenSlice(tree.nodeMainToken(node));
        const operand = tree.getNodeSource(value.operand);
        try findings.append(arena, .{
            .offset = tree.tokenStart(tree.firstToken(node)),
            .hint = try arena.print("compare `{s}` against bounds first, parse a narrower type and widen it, or say what happens with `{s}|`, `{s}%` or `std.math.{s}`", .{
                operand, operator, operator, if (tag == .sub) "sub" else "add",
            }),
            .detail = .{ .parsed = .{
                .expression = tree.getNodeSource(node),
                .operand = operand,
                .type = tree.getNodeSource(value.type),
            } },
        });
    }
}

/// `side`, an operand of the sum or difference `node`, as a full-width
/// `parseInt` result nothing bounds before it: null when it is none, when
/// `other`, the other operand, is wider, or when the local that holds it
/// is assigned or bounded between the parse and `node`.
fn unbounded(t: Types, node: Node.Index, side: Node.Index, other: Node.Index) ?Parsed {
    const tree = t.tree;
    const value = parsedAt(t, ints.unparen(tree, side)) orelse return null;
    if (widerThan(t, other, value.bits)) return null;
    const local = value.local orelse return value;
    const function = wrap.enclosingFn(tree, t.parents, node) orelse return null;
    if (wrap.changedBetween(tree, t.parents, function, value.call, node, local, null)) return null;
    if (boundedBefore(tree, tree.tokenSlice(tree.nodeMainToken(local)), tree.lastToken(value.call), tree.firstToken(node))) return null;
    return value;
}

const Parsed = struct {
    /// The operand, as it stands in the arithmetic.
    operand: Node.Index,
    /// The `parseInt(T, ...)` call.
    call: Node.Index,
    /// Its `T`.
    type: Node.Index,
    /// How many bits `T` has; 64 for `isize`.
    bits: u16,
    /// The local the call initializes, as named in the arithmetic; null
    /// for a call written there.
    local: ?Node.Index,
};

/// `operand` as a full-width signed `parseInt` result: the call, under a
/// `try` or a `catch`, or a local whose initializer that is.
fn parsedAt(t: Types, operand: Node.Index) ?Parsed {
    const tree = t.tree;
    const local: ?Node.Index = if (tree.nodeTag(operand) == .identifier) operand else null;
    const made = if (local) |name| ints.unparen(tree, t.localInit(name) orelse return null) else operand;
    const call = ints.unparen(tree, switch (tree.nodeTag(made)) {
        .@"try" => tree.nodeData(made).node,
        .@"catch" => tree.nodeData(made).node_and_node[0],
        else => made,
    });
    var buffer: [1]Node.Index = undefined;
    const full = tree.fullCall(&buffer, call) orelse return null;
    const name = switch (tree.nodeTag(full.ast.fn_expr)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(full.ast.fn_expr)),
        .field_access => tree.tokenSlice(tree.nodeData(full.ast.fn_expr).node_and_token[1]),
        else => return null,
    };
    if (!std.mem.eql(u8, name, "parseInt") or full.ast.params.len < 2) return null;
    const bits = fullWidth(tree, full.ast.params[0]) orelse return null;
    if (shortText(tree, full.ast.params[1])) return null;
    return .{ .operand = operand, .call = call, .type = full.ast.params[0], .bits = bits, .local = local };
}

/// Whether `text` is a slice of a fixed width too short to spell a value
/// near either end of an `i64`, whose minimum is nineteen digits and a
/// sign: `text[0..4]`, with both bounds numbers.
fn shortText(tree: *const Ast, text: Node.Index) bool {
    const slice = tree.fullSlice(ints.unparen(tree, text)) orelse return false;
    const start = number(tree, slice.ast.start) orelse return false;
    const end = number(tree, slice.ast.end.unwrap() orelse return false) orelse return false;
    return end >= start and end - start < 19;
}

/// What the number literal `node` says, when it is one.
fn number(tree: *const Ast, node: Node.Index) ?u64 {
    if (tree.nodeTag(node) != .number_literal) return null;
    return std.fmt.parseInt(u64, tree.tokenSlice(tree.nodeMainToken(node)), 0) catch null;
}

/// The bits of `type_expr` when it names a signed integer no narrower than
/// a pointer: `i64` and `i128`, and `isize`, taken as 64.
fn fullWidth(tree: *const Ast, type_expr: Node.Index) ?u16 {
    const bits = intBits(tree, type_expr, 'i') orelse return null;
    return if (bits >= 64) bits else null;
}

/// The bits of the integer type `type_expr` names with the letter `sign`
/// (`i` or `u`): `i64` is 64, and `isize` and `usize` 64 too.
fn intBits(tree: *const Ast, type_expr: Node.Index, sign: u8) ?u16 {
    const n = ints.unparen(tree, type_expr);
    if (tree.nodeTag(n) != .identifier) return null;
    const name = tree.tokenSlice(tree.nodeMainToken(n));
    if (name.len < 2 or name[0] != sign) return null;
    if (std.mem.eql(u8, name[1..], "size")) return 64;
    return std.fmt.parseInt(u16, name[1..], 10) catch null;
}

/// Whether the syntax shows `other`, the arithmetic's other operand, an
/// integer of more than `bits` bits, which the sum is then computed in.
fn widerThan(t: Types, other: Node.Index, bits: u16) bool {
    const declared = ints.declaredType(t, other, 0) orelse return false;
    const width = intBits(t.tree, declared, 'i') orelse intBits(t.tree, declared, 'u') orelse return false;
    return width > bits;
}

/// Whether anything between tokens `after` and `before` bounds the local
/// `name`: an ordering comparison with it as an operand, `@min`, `@max`
/// or a call named `clamp` with it as an argument, or a `switch` on it.
fn boundedBefore(tree: *const Ast, name: []const u8, after: Ast.TokenIndex, before: Ast.TokenIndex) bool {
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(node);
        if (at <= after or at >= before) continue;
        if (bounds(tree, node, name)) return true;
    }
    return false;
}

/// Whether `node` bounds the local `name`, at one end at least.
fn bounds(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    switch (tree.nodeTag(node)) {
        .less_than, .less_or_equal, .greater_than, .greater_or_equal => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return isName(tree, lhs, name) or isName(tree, rhs, name);
        },
        .@"switch", .switch_comma => return isName(tree, tree.fullSwitch(node).?.ast.condition, name),
        else => {},
    }
    var buffer: [2]Node.Index = undefined;
    const arguments = limited(tree, &buffer, node) orelse return false;
    for (arguments) |argument| if (isName(tree, argument, name)) return true;
    return false;
}

/// The arguments of `node` when it is a call that gives back one of them,
/// or something between them: `@min`, `@max`, or a call named `clamp`.
fn limited(tree: *const Ast, buffer: *[2]Node.Index, node: Node.Index) ?[]const Node.Index {
    if (tree.builtinCallParams(buffer, node)) |params| {
        const builtin = tree.tokenSlice(tree.nodeMainToken(node));
        return if (std.mem.eql(u8, builtin, "@min") or std.mem.eql(u8, builtin, "@max")) params else null;
    }
    const call = tree.fullCall(buffer[0..1], node) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]), "clamp")) return null;
    return call.ast.params;
}

fn isName(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    const n = ints.unparen(tree, node);
    return tree.nodeTag(n) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(n)), name);
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col expression | operand | type`, in source order.
fn expectParsed(source: [:0]const u8, expected: []const u8) !void {
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
        const p = finding.detail.parsed;
        try out.writer.print("{d}:{d} {s} | {s} | {s}\n", .{ loc.line + 1, loc.column + 1, p.expression, p.operand, p.type });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a full-width parseInt result in a plain - or + before anything bounds it (#235)" {
    try expectParsed(
        \\fn fresh(timestamp: []const u8, now_s: i64) bool { const at = std.fmt.parseInt(i64, timestamp, 10) catch return false; return @abs(now_s - at) <= tolerance_s; }
        \\fn tried(s: []const u8, base: i64) !i64 { const n = try std.fmt.parseInt(i64, s, 10); return base + n; }
        \\fn first(s: []const u8) !isize { const off = try fmt.parseInt(isize, s, 0); return off - 1; }
        \\fn inPlace(s: []const u8, now: i64) !i64 { return now - (try parseInt(i64, s, 10)); }
        \\fn orZero(s: []const u8, now: i128) i128 { const at = std.fmt.parseInt(i128, s, 10) catch 0; return (at) + now; }
        \\fn laterBound(s: []const u8, now: i64) !bool { const at = try std.fmt.parseInt(i64, s, 10); const age = now - at; return at > 0 and age < 300; }
        \\fn longText(text: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i64, text[0..20], 10); return now - at; }
        \\fn openText(text: []const u8, i: usize, now: i64) !i64 { const at = try std.fmt.parseInt(i64, text[i..], 10); return now - at; }
    ,
        \\1:132 now_s - at | at | i64
        \\2:94 base + n | n | i64
        \\3:84 off - 1 | off | isize
        \\4:51 now - (try parseInt(i64, s, 10)) | try parseInt(i64, s, 10) | i64
        \\5:101 (at) + now | at | i128
        \\6:105 now - at | at | i64
        \\7:110 now - at | at | i64
        \\8:118 now - at | at | i64
        \\
    );
}

test "not reported: bounded first, a narrower or unsigned parse, a wider sum, an operator that says, assigned between (#235)" {
    try expectParsed(
        \\fn compared(s: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i64, s, 10); if (at < now - 300 or at > now + 300) return error.Stale; return now - at; }
        \\fn oneEnd(s: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i64, s, 10); if (0 > at) return error.Negative; return now - at; }
        \\fn asserted(s: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i64, s, 10); std.debug.assert(at >= 0); return now - at; }
        \\fn clamped(s: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i64, s, 10); const c = std.math.clamp(at, 0, now); return now - at + c; }
        \\fn least(s: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i64, s, 10); const m = @max(at, 0); return now - at + m; }
        \\fn switched(s: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i64, s, 10); switch (at) { 0...9 => {}, else => return error.Range } return now - at; }
        \\fn narrower(s: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i32, s, 10); return now - at; }
        \\fn narrowSum(s: []const u8, base: i32) !i32 { const n = try std.fmt.parseInt(i32, s, 10); return base + n; }
        \\fn unsigned(s: []const u8, now: u64) !u64 { const at = try std.fmt.parseInt(u64, s, 10); return now - at; }
        \\fn generic(comptime T: type, s: []const u8, now: T) !T { const at = try std.fmt.parseInt(T, s, 10); return now - at; }
        \\fn widened(s: []const u8, now: i128) !i128 { const at = try std.fmt.parseInt(i64, s, 10); return now - at; }
        \\fn cast(s: []const u8, now: i64) !i128 { const at = try std.fmt.parseInt(i64, s, 10); return @as(i128, now) - at; }
        \\fn saturating(s: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i64, s, 10); return now -| at; }
        \\fn wrapping(s: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i64, s, 10); return now +% at; }
        \\fn checked(s: []const u8, now: i64) !i64 { const at = try std.fmt.parseInt(i64, s, 10); return std.math.sub(i64, now, at); }
        \\fn reassigned(s: []const u8, now: i64) !i64 { var at = try std.fmt.parseInt(i64, s, 10); at = 0; return now - at; }
        \\fn product(s: []const u8) !i64 { const secs = try std.fmt.parseInt(i64, s, 10); return secs * 1000; }
        \\fn other(s: []const u8, now: i64) !i64 { const at = try parse(i64, s); return now - at; }
        \\fn year(text: []const u8) !i64 { const y = try std.fmt.parseInt(i64, text[0..4], 10); return y - 1; }
        \\fn float(s: []const u8, now: f64) !f64 { const at = try std.fmt.parseFloat(f64, s); return now - at; }
    , "");
}
