//! Rule eight, torn: an optional or union built in place by an
//! initializer that can fail, which `deinit` frees.
//!
//!     self.pending = .{
//!         .start = target.start,
//!         .removed = removed,
//!         .selections_before = try self.gpa.dupe(Selection, self.selections.items),
//!     };
//!
//! Zig builds an initializer straight in the place it is assigned to, a
//! field at a time, the mechanism alias is about, and an optional reads as
//! set, or a union as tagged, before any field is made. When the `try`
//! fails the place is left set over what was never made, and the caller
//! still owns it: the `deinit` that frees `pending` frees whatever
//! `selections_before` happens to hold. It compiles clean in every build
//! mode and reads as one step.
//!
//! What fails is a `try`, or a `catch` or `orelse` that returns, in a field
//! or element of the initializer, as deep as the initializers nest. The
//! place is a field whose type the file declares as an optional or a union,
//! reached through a parameter, a local pointer made from one, or what an
//! `if` or `while` captures from one, or is a container-level `var`; and a
//! function of the file named `deinit` names that field.
//!
//! Not reported: a place left half-written, the fields before what failed
//! new and the rest as they were, which is wrong only if something reads it
//! after the error, which the syntax cannot see; a place whose type the
//! file does not show; one a `deinit` does not name; a place that is a
//! local, or memory the function makes; a place an `errdefer` declared
//! before it resets (`errdefer self.pending = null;`); an assignment in a
//! function named `init...`, whose caller deinits nothing if it fails; and
//! a `catch` that falls back (`f() catch 0`), which cannot fail.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every initializer with a step that can fail,
/// assigned to a place the caller keeps. Everything is allocated with
/// `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var t: ?types.Types = null;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .assign) continue;
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const place, const rhs = tree.nodeData(node).node_and_node;
        const init = initializer(tree, rhs) orelse continue;
        const point = try firstFailure(arena, tree, init) orelse continue;
        if (t == null) t = try .init(arena, tree);
        if (!kept.callersKeep(tree, t.?.parents, place)) continue;
        if (!setFirst(t.?, place) or !freedByDeinit(tree, place)) continue;
        if (inInit(tree, t.?.parents, node)) continue;
        if (try resetOnError(arena, tree, t.?.parents, node, tree.getNodeSource(place))) continue;
        try findings.append(arena, .{
            .offset = tree.tokenStart(tree.firstToken(place)),
            .hint = hint,
            .detail = .{ .torn = .{
                .place = tree.getNodeSource(place),
                .fails = what(tree, point),
            } },
        });
    }
}

const hint = "make what can fail first (`const v = try ...;`), then assign the initializer, so a failure leaves the place as it was";

/// The struct or array initializer `node` is, through parentheses and
/// `@as(T, ...)`.
fn initializer(tree: *const Ast, node: Node.Index) ?Node.Index {
    var n = node;
    while (true) switch (tree.nodeTag(n)) {
        .grouped_expression => n = tree.nodeData(n).node_and_token[0],
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(n)), "@as")) return null;
            var buffer: [2]Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, n).?;
            if (params.len != 2) return null;
            n = params[1];
        },
        else => {
            var buffer: [2]Node.Index = undefined;
            if (tree.fullStructInit(&buffer, n) != null or tree.fullArrayInit(&buffer, n) != null) return n;
            return null;
        },
    };
}

/// The first `try`, or `catch` or `orelse` that returns, in `init`, not in
/// a nested function or type.
fn firstFailure(arena: Allocator, tree: *const Ast, init: Node.Index) Allocator.Error!?Node.Index {
    var pending: std.ArrayList(Node.Index) = .empty;
    try pending.append(arena, init);
    var first: ?Node.Index = null;
    while (pending.pop()) |node| {
        if (kept.isNested(tree.nodeTag(node))) continue;
        const fails = switch (tree.nodeTag(node)) {
            .@"try" => true,
            .@"catch", .@"orelse" => returns(tree, tree.nodeData(node).node_and_node[1]),
            else => false,
        };
        if (fails and (first == null or tree.nodeMainToken(node) < tree.nodeMainToken(first.?))) first = node;
        try children.append(arena, tree, node, &pending);
    }
    return first;
}

/// Whether `node` holds a `return`.
fn returns(tree: *const Ast, node: Node.Index) bool {
    for (tree.firstToken(node)..tree.lastToken(node) + 1) |token| {
        if (tree.tokenTag(@intCast(token)) == .keyword_return) return true;
    }
    return false;
}

/// Whether `place`'s type, as the file shows it, is an optional or a union:
/// written as set, or tagged, before any of its fields is made.
fn setFirst(t: types.Types, place: Node.Index) bool {
    const tree = t.tree;
    const type_expr = t.typeOf(place, 0) orelse return false;
    if (tree.nodeTag(type_expr) == .optional_type) return true;
    const container = t.containerOf(type_expr, 0) orelse return false;
    var buffer: [2]Node.Index = undefined;
    const decl = tree.fullContainerDecl(&buffer, container) orelse return false;
    return tree.tokenTag(decl.ast.main_token) == .keyword_union;
}

/// Whether a function of the file named `deinit` names `place`'s field
/// (`.pending` of `self.pending`).
pub fn freedByDeinit(tree: *const Ast, place: Node.Index) bool {
    if (tree.nodeTag(place) != .field_access) return false;
    const field = tree.tokenSlice(tree.nodeData(place).node_and_token[1]);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const fn_decl: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
        const name = proto.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name), "deinit")) continue;
        const body = tree.nodeData(fn_decl).node_and_node[1];
        for (tree.firstToken(body)..tree.lastToken(body)) |token| {
            if (tree.tokenTag(@intCast(token)) == .period and std.mem.eql(u8, tree.tokenSlice(@intCast(token + 1)), field)) return true;
        }
    }
    return false;
}

/// Whether the function around `node` is named `init...`.
fn inInit(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) bool {
    var function = node;
    while (parents[@backingInt(function)].unwrap()) |parent| {
        function = parent;
        if (tree.nodeTag(function) != .fn_decl) continue;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]).?;
        const name = proto.name_token orelse return false;
        return std.mem.startsWith(u8, tree.tokenSlice(name), "init");
    }
    return false;
}

/// Whether an `errdefer` of the function around `node`, declared before it,
/// names `place`, as one that resets it does (`errdefer self.pending = null;`).
fn resetOnError(arena: Allocator, tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index, place: []const u8) Allocator.Error!bool {
    var function = node;
    while (parents[@backingInt(function)].unwrap()) |parent| {
        function = parent;
        if (tree.nodeTag(function) == .fn_decl or tree.nodeTag(function) == .test_decl) break;
    }
    var pending: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, function, &pending);
    while (pending.pop()) |n| {
        if (kept.isNested(tree.nodeTag(n))) continue;
        if (tree.nodeTag(n) == .@"errdefer") {
            if (tree.nodeMainToken(n) < tree.nodeMainToken(node) and std.mem.indexOf(u8, tree.getNodeSource(n), place) != null) return true;
            continue;
        }
        try children.append(arena, tree, n, &pending);
    }
    return false;
}

/// What fails at `point`, as written: the function a `try`, `catch` or
/// `orelse` calls, or the expression.
fn what(tree: *const Ast, point: Node.Index) []const u8 {
    var operand = switch (tree.nodeTag(point)) {
        .@"try" => tree.nodeData(point).node,
        else => tree.nodeData(point).node_and_node[0],
    };
    while (tree.nodeTag(operand) == .grouped_expression) operand = tree.nodeData(operand).node_and_token[0];
    var buffer: [1]Node.Index = undefined;
    if (tree.fullCall(&buffer, operand)) |call| return tree.getNodeSource(call.ast.fn_expr);
    return tree.getNodeSource(operand);
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col place <- what fails`, in source order.
fn expectTorn(source: [:0]const u8, expected: []const u8) !void {
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
        const f = finding.detail.torn;
        try out.writer.print("{d}:{d} {s} <- {s}\n", .{ loc.line + 1, loc.column + 1, f.place, f.fails });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "an optional or union built in place by an initializer that can fail, which deinit frees (#67)" {
    try expectTorn(
        \\const Pending = struct { start: usize, removed: []u8, before: []u8 };
        \\const Notice = union(enum) { set: []u8, gone: void };
        \\const Nav = struct {
        \\    notice: Notice,
        \\    last: ?Notice = null,
        \\    fn deinit(nav: *Nav, gpa: Allocator) void { switch (nav.notice) { .set => |s| gpa.free(s), .gone => {} } if (nav.last) |l| gpa.free(l.set); }
        \\    fn tagged(nav: *Nav, gpa: Allocator) !void { nav.notice = .{ .set = try make(gpa) }; nav.last = .{ .set = try make(gpa) }; }
        \\};
        \\const Editor = struct {
        \\    gpa: Allocator,
        \\    pending: ?Pending = null,
        \\    fn deinit(self: *Editor) void { if (self.pending) |p| self.gpa.free(p.before); }
        \\    fn begin(self: *Editor, removed: []u8) !void { errdefer self.gpa.free(removed); self.pending = .{ .start = 7, .removed = removed, .before = try self.gpa.dupe(u8, "x") }; }
        \\    fn first(self: *Editor) !void { self.pending = .{ .start = try count(), .removed = &.{}, .before = &.{} }; }
        \\    fn orelsed(self: *Editor) !void { self.pending = .{ .start = 1, .removed = &.{}, .before = self.take() orelse return error.Empty }; }
        \\};
    ,
        \\7:50 nav.notice <- make
        \\7:90 nav.last <- make
        \\13:85 self.pending <- self.gpa.dupe
        \\14:37 self.pending <- count
        \\15:39 self.pending <- self.take
        \\
    );
}

test "not reported: half-written, a type not shown, no deinit, a local, made here, reset, init, a fallback" {
    try expectTorn(
        \\const Pending = struct { start: usize, removed: []u8, before: []u8 };
        \\const Editor = struct {
        \\    pair: Pair,
        \\    pending: ?Pending = null,
        \\    fn deinit(self: *Editor) void { if (self.pending) |p| free(p.before); free(self.pair.b); }
        \\    fn half(self: *Editor) !void { self.pair = .{ .a = 1, .b = try f() }; }
        \\    fn reset(self: *Editor) !void { errdefer self.pending = null; self.pending = .{ .start = 1, .removed = &.{}, .before = try dup() }; }
        \\    fn init(self: *Editor) !void { self.* = .{ .pair = .{} }; self.pending = .{ .start = 1, .removed = &.{}, .before = try dup() }; }
        \\    fn fallback(self: *Editor) void { self.pending = .{ .start = 1, .removed = &.{}, .before = dup() catch &.{} }; }
        \\};
        \\const Undeinit = struct { slot: ?Pending = null, fn fill(self: *Undeinit) !void { self.slot = .{ .start = 1, .removed = &.{}, .before = try dup() }; } };
        \\fn send(req: Req, arena: Allocator) !void { if (req.head_out) |out| out.* = .{ .status = req.status, .headers = try copy(arena, req.headers) }; }
        \\fn local() !void { var x: ?Pending = null; x = .{ .start = 1, .removed = &.{}, .before = try dup() }; _ = x; }
        \\fn fresh(gpa: Allocator) !*Editor { const e = try gpa.create(Editor); e.pending = .{ .start = 1, .removed = &.{}, .before = try dup() }; return e; }
    , "");
}
