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
//! initializer with one as a field, either branch of an `if` or a
//! `switch` prong that gives one, either side of a `catch` or `orelse`,
//! what a `try` gives, or a `const` declared after the `defer` with one as
//! its value (`const items = x.items; return items;`).
//!
//! So is the value `std.json.parseFromSlice` or `parseFromSliceLeaky`
//! parses out of a view of `x` (#124). Their default,
//! `.allocate = .alloc_if_needed`, leaves a string with no escape in it as
//! a slice of the input, so the value reads right until the freed bytes
//! are used again, and an input whose strings each hold an escape is
//! copied and works. Not reported: options with `.allocate` set to
//! anything but `.alloc_if_needed`, options the function does not write
//! out (a parameter, a call; an initializer in a `const` it declares is
//! read), and a value of a number or `bool` type, which holds no string.
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
const expect = @import("expect.zig");
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
                var views: std.ArrayList(View) = .empty;
                const scope: Scope = .{ .nodes = nodes.items, .at = tree.nodeMainToken(node) };
                try viewsOf(arena, tree, value, name, scope, "", &views);
                for (views.items) |view| try findings.append(arena, try findingOf(arena, tree, view, name, call, operand));
            }
        }
    }
}

const hint_deinit = "hand the memory over instead: return what `toOwnedSlice` gives, which empties it so the defer frees nothing, or make the defer an errdefer";
const hint_free = "make the defer an errdefer, so it frees only when the function fails and the caller owns what it returns";
const hint_borrow = "pass `.allocate = .alloc_always`, so every string is copied into the parsed value's own memory, or keep the input alive as long as the value";

/// A view `viewsOf` finds, and the `const` that holds it until the
/// `return` when one does (`const parsed = ...; return parsed;`).
const View = struct { node: Node.Index, through: []const u8 };

/// Where a name a `return` gives is looked up: the nodes after the
/// `defer`, and the `return`'s token, which its `const` comes before.
const Scope = struct { nodes: []const Node.Index, at: Ast.TokenIndex };

/// The finding for `view`, returned while `call` frees `operand`, which is
/// `name` as written.
fn findingOf(arena: Allocator, tree: *const Ast, view: View, name: []const u8, call: Node.Index, operand: Node.Index) Allocator.Error!Finding {
    const offset = tree.tokenStart(tree.firstToken(view.node));
    const release = tree.getNodeSource(call);
    if (borrows(tree, view.node, name)) |input| {
        var buffer: [1]Node.Index = undefined;
        const parse = tree.fullCall(&buffer, view.node).?;
        return .{ .offset = offset, .hint = hint_borrow, .detail = .{ .freed = .{
            .returned = try std.fmt.allocPrint(arena, "{s}(...)", .{tree.getNodeSource(parse.ast.fn_expr)}),
            .release = release,
            .through = view.through,
            .borrowed = tree.getNodeSource(input),
        } } };
    }
    return .{ .offset = offset, .hint = if (deinits(tree, call, operand)) hint_deinit else hint_free, .detail = .{ .freed = .{
        .returned = tree.getNodeSource(view.node),
        .release = release,
        .through = view.through,
    } } };
}

/// Whether `call`, which frees `operand`, is `operand.deinit(...)` rather
/// than `a.free(operand)` and its kind.
fn deinits(tree: *const Ast, call: Node.Index, operand: Node.Index) bool {
    var buffer: [1]Node.Index = undefined;
    const full = tree.fullCall(&buffer, call).?;
    return tree.nodeData(full.ast.fn_expr).node_and_token[0] == operand;
}

/// Appends the parts of `value`, a returned value, that are a view of the
/// memory `name` holds: `name` itself, `name.items`, a slice of either and
/// the rest the file comment lists. `through` is the `const` that holds
/// `value`, or empty.
fn viewsOf(arena: Allocator, tree: *const Ast, value: Node.Index, name: []const u8, scope: Scope, through: []const u8, out: *std.ArrayList(View)) Allocator.Error!void {
    if (isView(tree, value, name) or borrows(tree, value, name) != null) return out.append(arena, .{ .node = value, .through = through });
    switch (tree.nodeTag(value)) {
        .grouped_expression => return viewsOf(arena, tree, tree.nodeData(value).node_and_token[0], name, scope, through, out),
        .@"try" => return viewsOf(arena, tree, tree.nodeData(value).node, name, scope, through, out),
        .@"catch", .@"orelse" => {
            const lhs, const rhs = tree.nodeData(value).node_and_node;
            try viewsOf(arena, tree, lhs, name, scope, through, out);
            return viewsOf(arena, tree, rhs, name, scope, through, out);
        },
        // One `const` deep, declared after the defer: `return parsed;`.
        .identifier => {
            if (through.len != 0) return;
            const local = tree.tokenSlice(tree.nodeMainToken(value));
            const init = lastConst(tree, scope.nodes, local, 0, scope.at) orelse return;
            return viewsOf(arena, tree, init, name, scope, local, out);
        },
        .if_simple, .@"if" => {
            const full = tree.fullIf(value).?;
            try viewsOf(arena, tree, full.ast.then_expr, name, scope, through, out);
            if (full.ast.else_expr.unwrap()) |e| try viewsOf(arena, tree, e, name, scope, through, out);
            return;
        },
        .@"switch", .switch_comma => {
            const full = tree.fullSwitch(value).?;
            for (full.ast.cases) |case| try viewsOf(arena, tree, tree.fullSwitchCase(case).?.ast.target_expr, name, scope, through, out);
            return;
        },
        else => return partsOf(arena, tree, value, name, scope, through, out),
    }
}

/// Appends the views among the fields or elements of `value`, an
/// initializer, as `viewsOf` does.
fn partsOf(arena: Allocator, tree: *const Ast, value: Node.Index, name: []const u8, scope: Scope, through: []const u8, out: *std.ArrayList(View)) Allocator.Error!void {
    var buffer: [2]Node.Index = undefined;
    if (tree.fullStructInit(&buffer, value)) |init| {
        for (init.ast.fields) |field| try viewsOf(arena, tree, field, name, scope, through, out);
    } else if (tree.fullArrayInit(&buffer, value)) |init| {
        for (init.ast.elements) |element| try viewsOf(arena, tree, element, name, scope, through, out);
    }
}

/// The input of `node` when it is a `std.json.parseFromSlice` or
/// `parseFromSliceLeaky` call on a view of `name` whose value can hold a
/// string, with options that leave its strings pointing into the input.
fn borrows(tree: *const Ast, node: Node.Index, name: []const u8) ?Node.Index {
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (call.ast.params.len != 4 or tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
    const text = tree.tokenSlice(method);
    if (!std.mem.eql(u8, text, "parseFromSlice") and !std.mem.eql(u8, text, "parseFromSliceLeaky")) return null;
    const namespace = switch (tree.nodeTag(receiver)) {
        .identifier => tree.nodeMainToken(receiver),
        .field_access => tree.nodeData(receiver).node_and_token[1],
        else => return null,
    };
    if (!std.mem.eql(u8, tree.tokenSlice(namespace), "json")) return null;
    const of_type, _, const input, const options = call.ast.params[0..4].*;
    // `u32` or `bool` holds no string to point anywhere.
    if (tree.nodeTag(of_type) == .identifier and std.zig.primitives.isPrimitive(tree.tokenSlice(tree.nodeMainToken(of_type)))) return null;
    if (!isView(tree, input, name) or !borrowing(tree, node, options)) return null;
    return input;
}

/// Whether `options`, the `std.json.ParseOptions` of `call`, are written
/// out with `.allocate` left at `.alloc_if_needed`: an initializer, or a
/// `const` the function declares with one.
fn borrowing(tree: *const Ast, call: Node.Index, options: Node.Index) bool {
    const init = if (tree.nodeTag(options) == .identifier)
        constInFn(tree, call, tree.tokenSlice(tree.nodeMainToken(options))) orelse return false
    else
        options;
    var buffer: [2]Node.Index = undefined;
    const full = tree.fullStructInit(&buffer, init) orelse return false;
    for (full.ast.fields) |field| {
        if (!std.mem.eql(u8, tree.tokenSlice(tree.firstToken(field) - 2), "allocate")) continue;
        return tree.nodeTag(field) == .enum_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(field)), "alloc_if_needed");
    }
    return true;
}

/// The value of the `const name` that the function around `node` declares
/// before it, if it declares one.
fn constInFn(tree: *const Ast, node: Node.Index, name: []const u8) ?Node.Index {
    const at = tree.nodeMainToken(node);
    var body_start: ?Ast.TokenIndex = null;
    for (0..tree.nodes.len) |i| {
        const fn_decl: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(fn_decl) != .fn_decl) continue;
        const body = tree.nodeData(fn_decl).node_and_node[1];
        const first = tree.firstToken(body);
        if (first >= at or tree.lastToken(body) <= at) continue;
        // The innermost function around it.
        if (body_start == null or first > body_start.?) body_start = first;
    }
    return lastConst(tree, null, name, body_start orelse return null, at);
}

/// The value of the last `const name` declared between the tokens `from`
/// and `to`, among `nodes`, or among every node in the file when null.
fn lastConst(tree: *const Ast, nodes: ?[]const Node.Index, name: []const u8, from: Ast.TokenIndex, to: Ast.TokenIndex) ?Node.Index {
    var found: ?Node.Index = null;
    var found_at = from;
    const count = if (nodes) |list| list.len else tree.nodes.len;
    for (0..count) |i| {
        const node: Node.Index = if (nodes) |list| list[i] else @fromBackingInt(@intCast(i));
        const decl = tree.fullVarDecl(node) orelse continue;
        const at = decl.ast.mut_token;
        if (at <= found_at or at >= to) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(at), "const") or !std.mem.eql(u8, tree.tokenSlice(at + 1), name)) continue;
        found = decl.ast.init_node.unwrap() orelse continue;
        found_at = at;
    }
    return found;
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
/// says only to make the defer one, in source order. `as name` follows
/// what a `const` holds until the `return`, and `from input` a parse.
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
        try out.writer.print("{d}:{d} {s}", .{ loc.line + 1, loc.column + 1, f.returned });
        if (f.through.len != 0) try out.writer.print(" as {s}", .{f.through});
        if (f.borrowed.len != 0) try out.writer.print(" from {s}", .{f.borrowed});
        try out.writer.print(" <- {s}{s}\n", .{ f.release, if (errdefer_only) " (errdefer)" else "" });
    }
    try expect.findings(@src(), expected, out.written());
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
        \\fn kept_var(gpa: Allocator, other: []u8) ![]u8 { var list: List = .empty; defer list.deinit(gpa); var items = list.items; items = other; return items; }
    , "");
}

test "what a try, a catch or a const gives (#124)" {
    try expectFreed(
        \\fn printed(gpa: Allocator) ![]u8 { const buf = try gpa.alloc(u8, 8); defer gpa.free(buf); return try std.fmt.bufPrint(buf, "{d}", .{1}); }
        \\fn fallback(gpa: Allocator, ok: ?[]u8) ![]u8 { var list: List = .empty; defer list.deinit(gpa); return ok orelse list.items; }
        \\fn local(gpa: Allocator) ![]u8 { var list: List = .empty; defer list.deinit(gpa); try fill(&list); const items = list.items; return items; }
        \\fn wrapped(gpa: Allocator) !Result { var list: List = .empty; defer list.deinit(gpa); const rows = list.items[1..]; return .{ .rows = rows }; }
    ,
        \\1:102 std.fmt.bufPrint(buf, "{d}", .{1}) <- gpa.free(buf) (errdefer)
        \\2:114 list.items <- list.deinit(gpa)
        \\3:114 list.items as items <- list.deinit(gpa)
        \\4:100 list.items[1..] as rows <- list.deinit(gpa)
        \\
    );
}

test "a std.json value parsed out of what the defer frees (#124)" {
    try expectFreed(
        \\fn load(gpa: Allocator, text: []const u8) !std.json.Parsed(Config) { const json = try gpa.dupe(u8, text); defer gpa.free(json); return std.json.parseFromSlice(Config, gpa, json, .{}); }
        \\fn leaky(arena: Allocator, gpa: Allocator) !Config { const text = try read(gpa); defer gpa.free(text); return try std.json.parseFromSliceLeaky(Config, arena, text, .{ .ignore_unknown_fields = true }); }
        \\fn held(gpa: Allocator) !std.json.Parsed(Config) { var list: List = .empty; defer list.deinit(gpa); try fill(&list); const parsed = try json.parseFromSlice(Config, gpa, list.items, .{}); return parsed; }
        \\fn named(gpa: Allocator, text: []const u8) !std.json.Parsed(Config) { const options: std.json.ParseOptions = .{ .allocate = .alloc_if_needed }; const json = try gpa.dupe(u8, text); defer gpa.free(json); return std.json.parseFromSlice(Config, gpa, json, options) catch |err| return err; }
        \\fn value(gpa: Allocator, text: []const u8) !std.json.Parsed(std.json.Value) { const json = try gpa.dupe(u8, text); defer gpa.free(json); return std.json.parseFromSlice(std.json.Value, gpa, json[1..], .{}); }
    ,
        \\1:136 std.json.parseFromSlice(...) from json <- gpa.free(json)
        \\2:115 std.json.parseFromSliceLeaky(...) from text <- gpa.free(text)
        \\3:137 json.parseFromSlice(...) as parsed from list.items <- list.deinit(gpa)
        \\4:211 std.json.parseFromSlice(...) from json <- gpa.free(json)
        \\5:145 std.json.parseFromSlice(...) from json[1..] <- gpa.free(json)
        \\
    );
}

test "not reported: a json value that copies its strings, or can hold none" {
    try expectFreed(
        \\fn always(gpa: Allocator, text: []const u8) !std.json.Parsed(Config) { const json = try gpa.dupe(u8, text); defer gpa.free(json); return std.json.parseFromSlice(Config, gpa, json, .{ .allocate = .alloc_always }); }
        \\fn named(gpa: Allocator, text: []const u8) !std.json.Parsed(Config) { const options = std.json.ParseOptions{ .allocate = .alloc_always }; const json = try gpa.dupe(u8, text); defer gpa.free(json); return std.json.parseFromSlice(Config, gpa, json, options); }
        \\fn elsewhere(gpa: Allocator) !void { const options: std.json.ParseOptions = .{}; try use(gpa, options); }
        \\fn given(gpa: Allocator, text: []const u8, options: std.json.ParseOptions) !std.json.Parsed(Config) { const json = try gpa.dupe(u8, text); defer gpa.free(json); return std.json.parseFromSlice(Config, gpa, json, options); }
        \\fn number(gpa: Allocator, text: []const u8) !std.json.Parsed(u32) { const json = try gpa.dupe(u8, text); defer gpa.free(json); return std.json.parseFromSlice(u32, gpa, json, .{}); }
        \\fn other(gpa: Allocator, text: []const u8, kept_text: []const u8) !std.json.Parsed(Config) { const json = try gpa.dupe(u8, text); defer gpa.free(json); return std.json.parseFromSlice(Config, gpa, kept_text, .{}); }
        \\fn used(gpa: Allocator, text: []const u8) !u32 { const json = try gpa.dupe(u8, text); defer gpa.free(json); const parsed = try std.json.parseFromSlice(Config, gpa, json, .{}); defer parsed.deinit(); return parsed.value.port; }
        \\fn reader(gpa: Allocator, r: *std.json.Reader) !std.json.Parsed(Config) { var list: List = .empty; defer list.deinit(gpa); return std.json.parseFromTokenSource(Config, gpa, r, .{}); }
    , "");
}
