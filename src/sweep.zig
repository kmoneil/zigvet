//! Rule ten, sweep: a loop frees what a list holds, can fail part way, and
//! empties the list only after it.
//!
//!     for (self.queue.items) |m| {
//!         try self.send(m); // fails on a later turn: earlier turns' are freed and still held
//!         self.gpa.free(m);
//!     }
//!     self.queue.clearRetainingCapacity();
//!
//! When `send` fails on the third message, the first two are freed, the
//! `clearRetainingCapacity` never runs, and the queue still holds them: the
//! next flush sends freed memory and frees it again, and `deinit` frees it
//! once more. It compiles clean in every build mode and reads as tidy code,
//! free each, then clear. It is refill's mistake in a loop: freed, then a
//! failure before the place is reset.
//!
//! What frees is `x.free(e)`, `x.destroy(e)`, `x.rawFree(e, ...)` or
//! `e.deinit(...)`, where `e` is the loop's capture or reached through it,
//! or captured from it by a `switch` or an `if` (`.texture => |t|
//! t.deinit()`). The loop walks `p.items`, or a slice of it, where `p` is
//! reached as kept's stores are (through a parameter, a local pointer made
//! from one, or what an `if` or `while` captures from one, or a
//! container-level `var`). It is reported when the loop's body can fail,
//! with a `try`, or a `catch` or `orelse` that returns, so a later turn
//! fails after an earlier turn's free, and `p` is emptied after the loop
//! (`clearRetainingCapacity`, `clearAndFree`, `shrinkRetainingCapacity`,
//! `shrinkAndFree`, or `p.items.len = ...`).
//!
//! Not reported: a list taken apart as it is freed (`swapRemove`,
//! `orderedRemove` or `pop` on it in the loop); a list a local holds; and a
//! list an `errdefer` before the loop resets.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const kept = @import("kept.zig");
const refill = @import("refill.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every loop that frees what a list holds, can
/// fail part way, and empties the list only after it. Everything is
/// allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var parents: []const Node.OptionalIndex = &.{};
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .for_simple, .@"for" => {},
            else => continue,
        }
        const loop: Node.Index = @fromBackingInt(@intCast(i));
        const full = tree.fullFor(loop).?;
        if (full.ast.inputs.len != 1) continue;
        const list = listOf(tree, full.ast.inputs[0]) orelse continue;
        const capture = captureName(tree, full.payload_token) orelse continue;
        var body: std.ArrayList(Node.Index) = .empty;
        try within(arena, tree, full.ast.then_expr, &body);
        const free = try freeOf(arena, tree, body.items, capture) orelse continue;
        const point = failure(tree, body.items) orelse continue;
        const list_text = tree.getNodeSource(list);
        if (takesApart(tree, body.items, list_text)) continue;
        if (parents.len == 0) parents = (try types.Types.init(arena, tree)).parents;
        if (!kept.callersKeep(tree, parents, list)) continue;
        const reset = emptiedAfter(tree, parents, loop, list_text) orelse continue;
        if (try resetOnError(arena, tree, parents, loop, list_text)) continue;
        try findings.append(arena, .{
            .offset = tree.tokenStart(tree.firstToken(free)),
            .hint = hint,
            .detail = .{ .sweep = .{
                .list = list_text,
                .fails = what(tree, point),
                .reset = tree.getNodeSource(reset),
            } },
        });
    }
}

const hint = "take each out of the list as it is freed, or empty the list before the loop and free what it held";

/// `p` of a loop over `p.items` or a slice of it.
fn listOf(tree: *const Ast, input: Node.Index) ?Node.Index {
    var n = input;
    while (true) switch (tree.nodeTag(n)) {
        .grouped_expression => n = tree.nodeData(n).node_and_token[0],
        .slice_open, .slice, .slice_sentinel => n = tree.fullSlice(n).?.ast.sliced,
        .field_access => {
            const lhs, const field = tree.nodeData(n).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(field), "items")) return null;
            return lhs;
        },
        else => return null,
    };
}

/// The name a `for` captures its element as, `m` of `|m|` or `|*m|`.
fn captureName(tree: *const Ast, payload: Ast.TokenIndex) ?[]const u8 {
    const token = if (tree.tokenTag(payload) == .asterisk) payload + 1 else payload;
    if (tree.tokenTag(token) != .identifier) return null;
    return tree.tokenSlice(token);
}

/// The first release in `body` of what the capture `name` holds: the
/// capture itself, what is reached through it, or what a `switch` or an
/// `if` captures from it.
fn freeOf(arena: Allocator, tree: *const Ast, body: []const Node.Index, name: []const u8) Allocator.Error!?Node.Index {
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(arena, name);
    // Captures taken from it: `switch (freed.space) { .texture => |t| ... }`.
    for (body) |node| {
        const condition, const payload = switch (tree.nodeTag(node)) {
            .switch_case_one, .switch_case, .switch_case_inline_one, .switch_case_inline => blk: {
                const prong = tree.fullSwitchCase(node).?;
                const payload = prong.payload_token orelse continue;
                const switch_node = for (body) |s| {
                    const full = tree.fullSwitch(s) orelse continue;
                    if (std.mem.indexOfScalar(Node.Index, full.ast.cases, node) != null) break full.ast.condition;
                } else continue;
                break :blk .{ switch_node, payload };
            },
            .if_simple, .@"if" => blk: {
                const full = tree.fullIf(node).?;
                break :blk .{ full.ast.cond_expr, full.payload_token orelse continue };
            },
            else => continue,
        };
        const root = kept.rootOf(tree, condition) orelse continue;
        const root_name = tree.tokenSlice(tree.nodeMainToken(root));
        const captured = captureName(tree, payload) orelse continue;
        for (names.items) |n| if (std.mem.eql(u8, n, root_name)) {
            try names.append(arena, captured);
            break;
        };
    }
    for (body) |node| {
        _, const operand = refill.releaseCall(tree, node) orelse continue;
        const root = kept.rootOf(tree, operand) orelse continue;
        const root_name = tree.tokenSlice(tree.nodeMainToken(root));
        for (names.items) |n| if (std.mem.eql(u8, n, root_name)) return node;
    }
    return null;
}

/// The first `try`, or `catch` or `orelse` that returns, in `body`.
fn failure(tree: *const Ast, body: []const Node.Index) ?Node.Index {
    var first: ?Node.Index = null;
    for (body) |node| {
        const fails = switch (tree.nodeTag(node)) {
            .@"try" => true,
            .@"catch", .@"orelse" => returns(tree, tree.nodeData(node).node_and_node[1]),
            else => false,
        };
        if (fails and (first == null or tree.nodeMainToken(node) < tree.nodeMainToken(first.?))) first = node;
    }
    return first;
}

fn returns(tree: *const Ast, node: Node.Index) bool {
    for (tree.firstToken(node)..tree.lastToken(node) + 1) |token| {
        if (tree.tokenTag(@intCast(token)) == .keyword_return) return true;
    }
    return false;
}

/// Whether `body` takes an element out of the list as it goes:
/// `swapRemove`, `orderedRemove` or `pop` called on it.
fn takesApart(tree: *const Ast, body: []const Node.Index, list: []const u8) bool {
    for (body) |node| {
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
        const name = tree.tokenSlice(method);
        if (!std.mem.eql(u8, name, "swapRemove") and !std.mem.eql(u8, name, "orderedRemove") and !std.mem.eql(u8, name, "pop")) continue;
        if (std.mem.eql(u8, tree.getNodeSource(receiver), list)) return true;
    }
    return false;
}

/// The statement after `loop`, in its block, that empties the list:
/// `clearRetainingCapacity`, `clearAndFree`, `shrinkRetainingCapacity` or
/// `shrinkAndFree` on it, or a store to its `items.len`. Null if the block
/// leaves before one.
fn emptiedAfter(tree: *const Ast, parents: []const Node.OptionalIndex, loop: Node.Index, list: []const u8) ?Node.Index {
    const block = parents[@backingInt(loop)].unwrap() orelse return null;
    var buffer: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return null;
    const at = std.mem.findScalar(Node.Index, statements, loop) orelse return null;
    for (statements[at + 1 ..]) |statement| {
        var call_buffer: [1]Node.Index = undefined;
        if (tree.fullCall(&call_buffer, statement)) |call| {
            if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
                const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
                const name = tree.tokenSlice(method);
                const empties = std.mem.eql(u8, name, "clearRetainingCapacity") or std.mem.eql(u8, name, "clearAndFree") or
                    std.mem.eql(u8, name, "shrinkRetainingCapacity") or std.mem.eql(u8, name, "shrinkAndFree");
                if (empties and std.mem.eql(u8, tree.getNodeSource(receiver), list)) return statement;
            }
        }
        if (tree.nodeTag(statement) == .assign) {
            const lhs = tree.nodeData(statement).node_and_node[0];
            const text = tree.getNodeSource(lhs);
            if (std.mem.startsWith(u8, text, list) and std.mem.eql(u8, text[list.len..], ".items.len")) return statement;
        }
        switch (tree.nodeTag(statement)) {
            .@"return", .@"break", .@"continue" => return null,
            else => {},
        }
    }
    return null;
}

/// Whether an `errdefer` of the function around `loop`, declared before
/// it, names `list`.
fn resetOnError(arena: Allocator, tree: *const Ast, parents: []const Node.OptionalIndex, loop: Node.Index, list: []const u8) Allocator.Error!bool {
    var function = loop;
    while (parents[@backingInt(function)].unwrap()) |parent| {
        function = parent;
        if (tree.nodeTag(function) == .fn_decl or tree.nodeTag(function) == .test_decl) break;
    }
    var pending: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, function, &pending);
    while (pending.pop()) |n| {
        if (kept.isNested(tree.nodeTag(n))) continue;
        if (tree.nodeTag(n) == .@"errdefer") {
            if (tree.nodeMainToken(n) < tree.nodeMainToken(loop) and std.mem.indexOf(u8, tree.getNodeSource(n), list) != null) return true;
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

/// Appends `node` and every node under it, but not what nested functions
/// and types hold, or what a `defer` or `errdefer` runs.
fn within(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    if (kept.isNested(tree.nodeTag(node))) return;
    switch (tree.nodeTag(node)) {
        .@"defer", .@"errdefer" => return,
        else => {},
    }
    try out.append(arena, node);
    var nodes: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, node, &nodes);
    for (nodes.items) |child| try within(arena, tree, child, out);
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col list <- what fails ; reset`, in source order.
fn expectSweep(source: [:0]const u8, expected: []const u8) !void {
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
        const s = finding.detail.sweep;
        try out.writer.print("{d}:{d} {s} <- {s} ; {s}\n", .{ loc.line + 1, loc.column + 1, s.list, s.fails, s.reset });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a loop frees what a list holds, can fail part way, and empties the list only after it (#65)" {
    try expectSweep(
        \\fn flush(self: *Queue) !void { for (self.queue.items) |m| { try self.send(m); self.gpa.free(m); } self.queue.clearRetainingCapacity(); }
        \\fn frame(self: *Images, gpa: Allocator) !void { var kept: usize = 0; for (self.quarantine.items) |freed| { if (freed.old) { switch (freed.space) { .span => |s| try self.free(gpa, s), .texture => |t| { t.deinit(); gpa.destroy(t); } } } else { self.quarantine.items[kept] = freed; kept += 1; } } self.quarantine.shrinkRetainingCapacity(kept); }
        \\fn lengths(q: *Queue) !void { for (q.items.items) |*it| { it.deinit(q.gpa); _ = q.next() orelse return error.Empty; } q.items.items.len = 0; }
    ,
        \\1:79 self.queue <- self.send ; self.queue.clearRetainingCapacity()
        \\2:202 self.quarantine <- self.free ; self.quarantine.shrinkRetainingCapacity(kept)
        \\3:59 q.items <- q.next ; q.items.items.len = 0
        \\
    );
}

test "not reported: taken apart, a local, no failure, not emptied after, reset on error" {
    try expectSweep(
        \\fn apart(self: *Queue) !void { for (self.queue.items) |m| { try self.send(m); self.gpa.free(m); _ = self.queue.pop(); } self.queue.clearRetainingCapacity(); }
        \\fn local(gpa: Allocator) !void { var q: List = .empty; for (q.items) |m| { try send(m); gpa.free(m); } q.clearRetainingCapacity(); }
        \\fn sure(self: *Queue) void { for (self.queue.items) |m| self.gpa.free(m); self.queue.clearRetainingCapacity(); }
        \\fn caught(self: *Queue) void { for (self.queue.items) |m| { self.send(m) catch {}; self.gpa.free(m); } self.queue.clearRetainingCapacity(); }
        \\fn kept(self: *Queue) !void { for (self.queue.items) |m| { try self.send(m); self.gpa.free(m); } }
        \\fn reset(self: *Queue) !void { errdefer self.queue.clearRetainingCapacity(); for (self.queue.items) |m| { try self.send(m); self.gpa.free(m); } self.queue.clearRetainingCapacity(); }
    , "");
}
