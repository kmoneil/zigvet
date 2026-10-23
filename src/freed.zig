//! Rule thirteen, freed: a function returns what its own `defer` frees.
//!
//!     var list: std.ArrayList(u8) = .empty;
//!     defer list.deinit(gpa);
//!     try list.appendSlice(gpa, a);
//!     return list.items;
//!
//! The `defer` runs after the return value is made and before the caller
//! gets it, so the caller always gets freed memory. It compiles clean in
//! every build mode. The debugging allocator writes over what it frees, so
//! the first test that reads the result fails; a function no test reads
//! hands freed memory on, and a release build reads whatever the allocator
//! put there next.
//!
//! What frees is `defer x.deinit(...)`, `defer a.free(x)`,
//! `defer a.destroy(x)` or `defer a.rawFree(x, ...)`, alone or as the one
//! statement of a block, where `x` is a name or a field of one
//! (`self.list`). It is reported at a `return` later in the same block,
//! before anything assigns to `x` or to what holds it, whose value is a
//! view of `x`: `x` itself, `x.items`, `.ptr` of a view, a slice or `&` of
//! an element of one, `x.written()`, `x.keys()`, `x.values()` or
//! `x.slice()`, a `std.mem` or `std.fmt` call that returns part of its
//! argument (`std.mem.trim(u8, x.items, " ")`), a cast of one, an
//! initializer with one as a field, or either branch of an `if` or a
//! `switch` prong that gives one.
//!
//! Not reported: a call that takes `x` and returns something else
//! (`return parse(x.items)`, `return gpa.dupe(u8, x.items)`), or hands it
//! over (`toOwnedSlice`); a length or an element read out of it; an
//! `errdefer`, or a `defer` behind an `if`, which may not free on this path;
//! and a `return` after an assignment to `x`.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const escape = @import("escape.zig");
const kept = @import("kept.zig");
const refill = @import("refill.zig");
const report = @import("report.zig");
const Finding = report.Finding;

/// Appends a finding for every `return` of what a `defer` before it in its
/// block frees. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    for (0..tree.nodes.len) |i| {
        const block: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        for (statements, 0..) |statement, at| {
            if (tree.nodeTag(statement) != .@"defer") continue;
            var deferred = tree.nodeData(statement).node;
            // `defer { list.deinit(gpa); }` frees as well.
            var inner: [2]Node.Index = undefined;
            if (tree.blockStatements(&inner, deferred)) |one| {
                if (one.len != 1) continue;
                deferred = one[0];
            }
            const call, const operand = refill.releaseCall(tree, deferred) orelse continue;
            if (!isPlace(tree, operand)) continue;
            const name = tree.getNodeSource(operand);
            var nodes: std.ArrayList(Node.Index) = .empty;
            for (statements[at + 1 ..]) |next| try within(arena, tree, next, &nodes);
            // A `return` after `x` is given something else frees that, not
            // what it returns.
            var until: Ast.TokenIndex = std.math.maxInt(Ast.TokenIndex);
            for (nodes.items) |node| {
                if (tree.nodeTag(node) != .assign) continue;
                if (!overlaps(tree.getNodeSource(tree.nodeData(node).node_and_node[0]), name)) continue;
                until = @min(until, tree.nodeMainToken(node));
            }
            for (nodes.items) |node| {
                if (tree.nodeTag(node) != .@"return") continue;
                if (tree.nodeMainToken(node) > until) continue;
                const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
                var views: std.ArrayList(Node.Index) = .empty;
                try viewsOf(arena, tree, value, name, &views);
                for (views.items) |view| {
                    try findings.append(arena, .{
                        .offset = tree.tokenStart(tree.firstToken(view)),
                        .hint = if (deinits(tree, call, operand)) hint_deinit else hint_free,
                        .detail = .{ .freed = .{
                            .returned = tree.getNodeSource(view),
                            .release = tree.getNodeSource(call),
                        } },
                    });
                }
            }
        }
    }
}

const hint_deinit = "hand the memory over instead: return what `toOwnedSlice` gives, which empties it so the defer frees nothing, or make the defer an errdefer";
const hint_free = "make the defer an errdefer, so it frees only when the function fails and the caller owns what it returns";

/// Whether `call`, which frees `operand`, is `operand.deinit(...)` rather
/// than `a.free(operand)` and its kind.
fn deinits(tree: *const Ast, call: Node.Index, operand: Node.Index) bool {
    var buffer: [1]Node.Index = undefined;
    const full = tree.fullCall(&buffer, call).?;
    return tree.nodeData(full.ast.fn_expr).node_and_token[0] == operand;
}

/// Appends the parts of `value`, a returned value, that are a view of the
/// memory `name` holds: `name` itself, `name.items`, a slice of either and
/// the rest the file comment lists.
fn viewsOf(arena: Allocator, tree: *const Ast, value: Node.Index, name: []const u8, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    if (isView(tree, value, name)) return out.append(arena, value);
    switch (tree.nodeTag(value)) {
        .grouped_expression => return viewsOf(arena, tree, tree.nodeData(value).node_and_token[0], name, out),
        .if_simple, .@"if" => {
            const full = tree.fullIf(value).?;
            try viewsOf(arena, tree, full.ast.then_expr, name, out);
            if (full.ast.else_expr.unwrap()) |e| try viewsOf(arena, tree, e, name, out);
            return;
        },
        .@"switch", .switch_comma => {
            const full = tree.fullSwitch(value).?;
            for (full.ast.cases) |case| try viewsOf(arena, tree, tree.fullSwitchCase(case).?.ast.target_expr, name, out);
            return;
        },
        else => {},
    }
    var buffer: [2]Node.Index = undefined;
    if (tree.fullStructInit(&buffer, value)) |init| {
        for (init.ast.fields) |field| try viewsOf(arena, tree, field, name, out);
    } else if (tree.fullArrayInit(&buffer, value)) |init| {
        for (init.ast.elements) |element| try viewsOf(arena, tree, element, name, out);
    }
}

/// Whether `node` reaches the memory `name` holds, as `viewsOf` says.
fn isView(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    switch (tree.nodeTag(node)) {
        .identifier => return isName(tree, node, name),
        .grouped_expression => return isView(tree, tree.nodeData(node).node_and_token[0], name),
        .field_access => {
            if (isName(tree, node, name)) return true;
            const receiver, const field = tree.nodeData(node).node_and_token;
            const text = tree.tokenSlice(field);
            if (std.mem.eql(u8, text, "ptr")) return isView(tree, receiver, name);
            return std.mem.eql(u8, text, "items") and isName(tree, receiver, name);
        },
        .slice_open, .slice, .slice_sentinel => return isView(tree, tree.fullSlice(node).?.ast.sliced, name),
        // `&x.items[0]`, but not `&x`, a local's own address, which is
        // escape's to judge.
        .address_of => {
            const operand = tree.nodeData(node).node;
            if (tree.nodeTag(operand) != .array_access) return false;
            return isView(tree, tree.nodeData(operand).node_and_node[0], name);
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const builtin = tree.tokenSlice(tree.nodeMainToken(node));
            var buffer: [2]Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, node).?;
            if (params.len != 1) return false;
            for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast" }) |cast| {
                if (std.mem.eql(u8, builtin, cast)) return isView(tree, params[0], name);
            }
            return false;
        },
        else => {},
    }
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
    const text = tree.tokenSlice(method);
    // `aw.written()`, `map.keys()`: the memory itself, by a method.
    for ([_][]const u8{ "written", "getWritten", "keys", "values", "slice" }) |view| {
        if (std.mem.eql(u8, text, view) and call.ast.params.len == 0) return isName(tree, receiver, name);
    }
    // `std.mem.trim(u8, x.items, " ")`: part of an argument.
    const view = escape.std_view_fns.get(text) orelse return false;
    const namespace = switch (tree.nodeTag(receiver)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(receiver)),
        .field_access => tree.tokenSlice(tree.nodeData(receiver).node_and_token[1]),
        else => return false,
    };
    if (!std.mem.eql(u8, namespace, view.namespace) or view.argument >= call.ast.params.len) return false;
    return isView(tree, call.ast.params[view.argument], name);
}

/// Whether `node` is `name` as written, `name` being a name or a field of
/// one.
fn isName(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    return isPlace(tree, node) and std.mem.eql(u8, tree.getNodeSource(node), name);
}

/// Whether `node` is a name or a field of one: `list`, `self.list`.
fn isPlace(tree: *const Ast, node: Node.Index) bool {
    var n = node;
    while (tree.nodeTag(n) == .field_access) n = tree.nodeData(n).node_and_token[0];
    return tree.nodeTag(n) == .identifier;
}

/// Whether an assignment to `target` changes `place`: the same, or one
/// holds the other (`self.list.items`, `self`).
fn overlaps(target: []const u8, place: []const u8) bool {
    const short, const long = if (target.len <= place.len) .{ target, place } else .{ place, target };
    if (!std.mem.startsWith(u8, long, short)) return false;
    return long.len == short.len or long[short.len] == '.' or long[short.len] == '[';
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
/// `line:col returned <- release`, then `(errdefer)` for the hint that
/// says only to make the defer one, in source order.
fn expectFreed(source: [:0]const u8, expected: []const u8) !void {
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
        const f = finding.detail.freed;
        const errdefer_only = std.mem.eql(u8, finding.hint, hint_free);
        try out.writer.print("{d}:{d} {s} <- {s}{s}\n", .{ loc.line + 1, loc.column + 1, f.returned, f.release, if (errdefer_only) " (errdefer)" else "" });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a function returns what its own defer frees (#54)" {
    try expectFreed(
        \\fn joined(gpa: Allocator, a: []const u8) ![]const u8 { var list: List = .empty; defer list.deinit(gpa); try list.appendSlice(gpa, a); return list.items; }
        \\fn freedBuf(gpa: Allocator) ![]u8 { const buf = try gpa.alloc(u8, 8); defer gpa.free(buf); fill(buf); return buf[0..4]; }
        \\fn whole(gpa: Allocator) !List { var list: List = .empty; defer list.deinit(gpa); try list.append(gpa, 1); return list; }
        \\fn trimmed(gpa: Allocator) ![]const u8 { var list: List = .empty; defer { list.deinit(gpa); } try fill(&list); return std.mem.trim(u8, list.items, " "); }
        \\fn written(gpa: Allocator) ![]const u8 { var aw: Allocating = .init(gpa); defer aw.deinit(); try aw.writer.writeAll("x"); return aw.written(); }
        \\fn held(gpa: Allocator) !Result { var list: List = .empty; defer list.deinit(gpa); try fill(&list); return .{ .rows = list.items, .count = list.items.len }; }
        \\fn branch(gpa: Allocator, ok: bool) ![]const u8 { var list: List = .empty; defer list.deinit(gpa); if (ok) { try fill(&list); return if (list.items.len > 0) list.items[1..] else &.{}; } return ""; }
        \\fn first(gpa: Allocator) !*u8 { var list: List = .empty; defer list.deinit(gpa); try fill(&list); return &list.items[0]; }
        \\fn raw(gpa: Allocator) ![*]u8 { const p = try gpa.create([4]u8); defer gpa.destroy(p); return @ptrCast(p); }
        \\fn field(self: *Self, gpa: Allocator) []u8 { defer self.list.deinit(gpa); return self.list.items; }
    ,
        \\1:142 list.items <- list.deinit(gpa)
        \\2:110 buf[0..4] <- gpa.free(buf) (errdefer)
        \\3:115 list <- list.deinit(gpa)
        \\4:119 std.mem.trim(u8, list.items, " ") <- list.deinit(gpa)
        \\5:130 aw.written() <- aw.deinit()
        \\6:119 list.items <- list.deinit(gpa)
        \\7:158 list.items[1..] <- list.deinit(gpa)
        \\8:106 &list.items[0] <- list.deinit(gpa)
        \\9:95 @ptrCast(p) <- gpa.destroy(p) (errdefer)
        \\10:82 self.list.items <- self.list.deinit(gpa)
        \\
    );
}

test "not reported: handed over, copied, read, an errdefer, a guarded defer, assigned first" {
    try expectFreed(
        \\fn owned(gpa: Allocator) ![]u8 { var list: List = .empty; defer list.deinit(gpa); try fill(&list); return list.toOwnedSlice(gpa); }
        \\fn copied(gpa: Allocator) ![]u8 { var list: List = .empty; defer list.deinit(gpa); try fill(&list); return gpa.dupe(u8, list.items); }
        \\fn parsed(gpa: Allocator) !u32 { var list: List = .empty; defer list.deinit(gpa); try fill(&list); return parse(list.items); }
        \\fn counted(gpa: Allocator) !usize { var list: List = .empty; defer list.deinit(gpa); try fill(&list); return list.items.len; }
        \\fn element(gpa: Allocator) !u8 { var list: List = .empty; defer list.deinit(gpa); try fill(&list); return list.items[0]; }
        \\fn failing(gpa: Allocator) ![]u8 { var list: List = .empty; errdefer list.deinit(gpa); try fill(&list); return list.items; }
        \\fn guarded(gpa: Allocator) ![]u8 { var list: List = .empty; var ok = false; defer if (!ok) list.deinit(gpa); try fill(&list); ok = true; return list.items; }
        \\fn assigned(gpa: Allocator, other: []u8) ![]u8 { var buf = try gpa.alloc(u8, 4); defer gpa.free(buf); const kept_buf = buf; buf = other; return kept_buf; }
        \\fn later(gpa: Allocator) ![]u8 { var list: List = .empty; { defer list.deinit(gpa); try fill(&list); } return list.items; }
        \\fn reset(self: *Self, gpa: Allocator) []u8 { defer self.list.deinit(gpa); self.list = .empty; return self.list.items; }
        \\fn other(self: *Self, gpa: Allocator) []u8 { defer self.list.deinit(gpa); return self.lists.items; }
        \\fn nested(gpa: Allocator) void { var list: List = .empty; defer list.deinit(gpa); const S = struct { fn f(l: List) []u8 { return l.items; } }; _ = S; }
    , "");
}
