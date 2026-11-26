//! Rule thirty, hollow: an optional given a payload of `undefined`, then
//! unwrapped in place before anything defined is stored in it.
//!
//!     if (src.*) |*payload| {
//!         dst.* = @as([]const u8, undefined);
//!         try copySlice(gpa, payload, &dst.*.?);
//!     } else dst.* = null;
//!
//! `@as(T, undefined)` makes an optional non-null only when it keeps a flag
//! of its own. An optional of a pointer, a slice or an error set keeps
//! none: its null is a payload of 0, so the store leaves whether it is null
//! as undefined as the payload, and the `.?` after it branches on that.
//! Debug fills undefined memory with 0xaa, which reads as set, so every
//! Debug test passes; ReleaseSafe drops the store, and the optional reads
//! as null when the bytes there were zero, the payload written through it
//! lost (#232). It is the natural shape for copying a value in place where
//! its address matters, and in generic code, where the payload's type is a
//! parameter or the `child` of an optional's type info, it holds for every
//! type but these.
//!
//! What is reported is an assignment, or a local's declaration, of
//! `@as(T, undefined)`, where `T` is a pointer or slice type written out
//! (not `[*c]` or `allowzero`, which keep a flag), `anyerror` or an error
//! set, or a name declared as one, or generic: a parameter of a function
//! around it (`comptime T: type`), or a `child` (`o.child` of
//! `.optional => |o|`). Then the same place, as written, is unwrapped
//! later in the function: `.?`, an `if` or `while` that captures its
//! payload, `orelse`, or a comparison with `null`. The report is on the
//! place.
//!
//! Not reported: a payload type that keeps a flag (an integer, a struct,
//! an array), or one the file does not show (`Session`, from another
//! file); a place assigned whole, or whose address is taken (`&dst.*`),
//! before the unwrap, which may store a defined value; a store or an
//! unwrap in a `defer` or `errdefer`, which runs when the block is left;
//! and a generic payload whose type the function asks `@typeInfo` about,
//! as code that reads a pointer aside does
//! (`if (comptime @typeInfo(o.child) == .pointer)`).

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every optional given an undefined payload of a
/// type whose null is one of its values, then unwrapped. Everything is
/// allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    // Few files write `@as(T, undefined)`: look before reading a node.
    if (std.mem.find(u8, tree.source, "undefined)") == null) return;
    var t: ?types.Types = null;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const store = stored(tree, node) orelse continue;
        const payload = undefinedAs(tree, store.value) orelse continue;
        if (t == null) t = try .init(arena, tree);
        const kind = holdsNull(t.?, payload, 0) orelse continue;
        const body = bodyAround(tree, t.?.parents, node) orelse continue;
        if (kind == .generic and asksTypeInfo(tree, body, payload)) continue;
        const unwrap = try unwrapped(arena, tree, body, store, tree.lastToken(node)) orelse continue;
        try findings.append(arena, .{
            .offset = tree.tokenStart(store.first),
            .hint = hint,
            .detail = .{ .hollow = .{
                .place = tree.source[tree.tokenStart(store.first)..tokenEnd(tree, store.last)],
                .payload = tree.getNodeSource(payload),
                .unwrap = unwrap,
                .generic = kind == .generic,
            } },
        });
    }
}

const hint = "store a defined value in it first, as a copy of the source, then write the payload through `.?`; or build the payload in a local and assign the optional once";

/// A place given a value: its tokens, as written, and the value.
const Store = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    value: Node.Index,
};

/// `node` as a store: an assignment, or a local's declaration with a value.
fn stored(tree: *const Ast, node: Node.Index) ?Store {
    switch (tree.nodeTag(node)) {
        .assign => {
            const place, const value = tree.nodeData(node).node_and_node;
            return .{ .first = tree.firstToken(place), .last = tree.lastToken(place), .value = value };
        },
        .simple_var_decl, .local_var_decl, .aligned_var_decl => {
            const decl = tree.fullVarDecl(node).?;
            const name = decl.ast.mut_token + 1;
            return .{ .first = name, .last = name, .value = decl.ast.init_node.unwrap() orelse return null };
        },
        else => return null,
    }
}

/// `T` of `@as(T, undefined)`, through parentheses.
fn undefinedAs(tree: *const Ast, value: Node.Index) ?Node.Index {
    var n = value;
    while (tree.nodeTag(n) == .grouped_expression) n = tree.nodeData(n).node_and_token[0];
    switch (tree.nodeTag(n)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(n)), "@as")) return null;
    var buffer: [2]Node.Index = undefined;
    const params = tree.builtinCallParams(&buffer, n).?;
    if (params.len != 2 or !isName(tree, params[1], "undefined")) return null;
    return params[0];
}

/// How a payload type's optional comes to keep its null in the payload:
/// always, for a type written as a pointer, a slice or an error set; or
/// for some types, when the type is a parameter.
const Kind = enum { written, generic };

/// Whether an optional of `type_expr` keeps its null in the payload's own
/// bits, and how the file shows it: a pointer or slice type written out
/// (`[*c]` and `allowzero` ones keep a flag), `anyerror`, an error set, a
/// name declared as one of these, or a type a generic function is given.
fn holdsNull(t: types.Types, type_expr: Node.Index, depth: u8) ?Kind {
    const tree = t.tree;
    if (depth > 4) return null;
    switch (tree.nodeTag(type_expr)) {
        .grouped_expression => return holdsNull(t, tree.nodeData(type_expr).node_and_token[0], depth + 1),
        .error_set_decl, .merge_error_sets => return .written,
        // `o.child` of `.optional => |o|`, or of `@typeInfo(T).pointer`:
        // whatever type the code is given.
        .field_access => {
            const field = tree.nodeData(type_expr).node_and_token[1];
            return if (std.mem.eql(u8, tree.tokenSlice(field), "child")) .generic else null;
        },
        .identifier => {
            if (isName(tree, type_expr, "anyerror")) return .written;
            if (t.localInit(type_expr)) |init| return holdsNull(t, init, depth + 1);
            if (declared(t, type_expr)) |init| return holdsNull(t, init, depth + 1);
            return if (typeParameter(t, type_expr)) .generic else null;
        },
        else => {
            const ptr = tree.fullPtrType(type_expr) orelse return null;
            if (ptr.size == .c or ptr.allowzero_token != null) return null;
            return .written;
        },
    }
}

/// The value of the constant `name` names, declared in a container around
/// it.
fn declared(t: types.Types, name: Node.Index) ?Node.Index {
    const tree = t.tree;
    const text = tree.tokenSlice(tree.nodeMainToken(name));
    var around = t.enclosingContainer(name);
    while (around) |container| : (around = t.enclosingContainer(container)) {
        const decl = types.memberDecl(tree, container, text) orelse continue;
        return tree.fullVarDecl(decl).?.ast.init_node.unwrap();
    }
    return null;
}

/// Whether `name`, the type of an `@as`, is a parameter of a function
/// around it, which then holds a type (`comptime T: type`): the function's
/// own, or one that returns the type it is declared in
/// (`fn Slot(comptime T: type) type { return struct { ... }; }`).
fn typeParameter(t: types.Types, name: Node.Index) bool {
    const tree = t.tree;
    const text = tree.tokenSlice(tree.nodeMainToken(name));
    var up = t.parents[@backingInt(name)].unwrap();
    while (up) |parent| : (up = t.parents[@backingInt(parent)].unwrap()) {
        if (tree.nodeTag(parent) != .fn_decl) continue;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(parent).node_and_node[0]).?;
        var params = proto.iterate(tree);
        while (params.next()) |param| {
            const name_token = param.name_token orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(name_token), text)) return true;
        }
    }
    return false;
}

/// Whether `body` asks `@typeInfo` about `payload`, written the same way:
/// code that decides by its kind, as one that reads a pointer aside does.
fn asksTypeInfo(tree: *const Ast, body: Node.Index, payload: Node.Index) bool {
    const first = tree.firstToken(payload);
    const last = tree.lastToken(payload);
    var token = tree.firstToken(body);
    while (token + 2 <= tree.lastToken(body)) : (token += 1) {
        if (tree.tokenTag(token) != .builtin or !std.mem.eql(u8, tree.tokenSlice(token), "@typeInfo")) continue;
        if (tree.tokenTag(token + 1) != .l_paren) continue;
        if (sameTokens(tree, token + 2, first, last) and tree.tokenTag(token + 2 + (last - first) + 1) == .r_paren) return true;
    }
    return false;
}

/// The body of the function or test around `node`.
fn bodyAround(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) ?Node.Index {
    var up = parents[@backingInt(node)].unwrap();
    while (up) |parent| : (up = parents[@backingInt(parent)].unwrap()) {
        switch (tree.nodeTag(parent)) {
            .fn_decl => return tree.nodeData(parent).node_and_node[1],
            .test_decl => return tree.nodeData(parent).opt_token_and_node[1],
            else => {},
        }
    }
    return null;
}

/// What `body` does first with `store`'s place after token `after`, when
/// that is to unwrap it: the unwrap as a message names it (`dst.*.?`,
/// `if (dst.*)`). Null when the first is a store of the whole place or a
/// taking of its address, or when nothing after unwraps it.
fn unwrapped(arena: Allocator, tree: *const Ast, body: Node.Index, store: Store, after: Ast.TokenIndex) Allocator.Error!?[]const u8 {
    var first: ?struct { at: Ast.TokenIndex, node: Node.Index, by: By } = null;
    var pending: std.ArrayList(Node.Index) = .empty;
    try pending.append(arena, body);
    while (pending.pop()) |node| {
        if (kept.isNested(tree.nodeTag(node))) continue;
        // Run when the block is left, not where they are written.
        if (tree.nodeTag(node) == .@"defer" or tree.nodeTag(node) == .@"errdefer") continue;
        try children.append(arena, tree, node, &pending);
        const use = useOf(tree, node) orelse continue;
        if (!isPlace(tree, use.operand, store)) continue;
        const at = tree.firstToken(use.operand);
        if (at <= after) continue;
        if (first) |f| if (f.at <= at) continue;
        first = .{ .at = at, .node = node, .by = use.by };
    }
    const f = first orelse return null;
    return named(arena, tree, f.node, f.by, tree.source[tree.tokenStart(store.first)..tokenEnd(tree, store.last)]);
}

/// The unwrap `node` makes of `place`, as a message names it, or null for
/// a store or a taking of its address.
fn named(arena: Allocator, tree: *const Ast, node: Node.Index, by: By, place: []const u8) Allocator.Error!?[]const u8 {
    return switch (by) {
        .store, .address => null,
        .unwrap, .compare => tree.getNodeSource(node),
        .@"orelse" => try std.fmt.allocPrint(arena, "{s} orelse", .{place}),
        .@"if" => try std.fmt.allocPrint(arena, "if ({s})", .{place}),
        .@"while" => try std.fmt.allocPrint(arena, "while ({s})", .{place}),
    };
}

/// What a node does with an optional it is given: stores to it whole,
/// takes its address, or unwraps it in one of five ways.
const By = enum { store, address, unwrap, @"orelse", compare, @"if", @"while" };

/// What `node` does with which of its operands, when that may be an
/// optional's place: `dst.*` of `dst.* = x`, `&dst.*`, `dst.*.?`,
/// `dst.* orelse`, `dst.* == null`, `if (dst.*) |p|`, `while (dst.*) |p|`.
fn useOf(tree: *const Ast, node: Node.Index) ?struct { operand: Node.Index, by: By } {
    const data = tree.nodeData(node);
    return switch (tree.nodeTag(node)) {
        .assign => .{ .operand = data.node_and_node[0], .by = .store },
        .address_of => .{ .operand = data.node, .by = .address },
        .unwrap_optional => .{ .operand = data.node_and_token[0], .by = .unwrap },
        .@"orelse" => .{ .operand = data.node_and_node[0], .by = .@"orelse" },
        .equal_equal, .bang_equal => .{ .operand = comparedWithNull(tree, node) orelse return null, .by = .compare },
        .if_simple, .@"if" => .{ .operand = captured(tree.fullIf(node).?) orelse return null, .by = .@"if" },
        .while_simple, .while_cont, .@"while" => .{ .operand = captured(tree.fullWhile(node).?) orelse return null, .by = .@"while" },
        else => null,
    };
}

/// What `node`, `==` or `!=`, compares with `null`.
fn comparedWithNull(tree: *const Ast, node: Node.Index) ?Node.Index {
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    if (isName(tree, rhs, "null")) return lhs;
    if (isName(tree, lhs, "null")) return rhs;
    return null;
}

/// The condition of `full`, an `if` or a `while`, when it captures an
/// optional's payload: a capture and no `else |err|`, which an error
/// union's takes.
fn captured(full: anytype) ?Node.Index {
    if (full.payload_token == null or full.error_token != null) return null;
    return full.ast.cond_expr;
}

/// Whether `node` is `store`'s place, written with the same tokens.
fn isPlace(tree: *const Ast, node: Node.Index, store: Store) bool {
    var n = node;
    while (tree.nodeTag(n) == .grouped_expression) n = tree.nodeData(n).node_and_token[0];
    if (tree.lastToken(n) - tree.firstToken(n) != store.last - store.first) return false;
    return sameTokens(tree, tree.firstToken(n), store.first, store.last);
}

/// Whether the tokens from `at` are those from `first` to `last`.
fn sameTokens(tree: *const Ast, at: Ast.TokenIndex, first: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    if (at + (last - first) >= tree.tokens.len) return false;
    for (0..last - first + 1) |k| {
        const x: Ast.TokenIndex = @intCast(at + k);
        const y: Ast.TokenIndex = @intCast(first + k);
        if (tree.tokenTag(x) != tree.tokenTag(y)) return false;
        if (!std.mem.eql(u8, tree.tokenSlice(x), tree.tokenSlice(y))) return false;
    }
    return true;
}

/// Whether `node` is the identifier `name`.
fn isName(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

/// The byte just past `token`.
fn tokenEnd(tree: *const Ast, token: Ast.TokenIndex) usize {
    return tree.tokenStart(token) + tree.tokenSlice(token).len;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col place = payload, unwrap`, with `(generic)` after a generic
/// payload, in source order.
fn expectHollow(source: [:0]const u8, expected: []const u8) !void {
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
        const h = finding.detail.hollow;
        try out.writer.print("{d}:{d} {s} = {s}, {s}{s}\n", .{ loc.line + 1, loc.column + 1, h.place, h.payload, h.unwrap, if (h.generic) " (generic)" else "" });
    }
    try expect.findings(@src(), expected, out.written());
}

test "an optional given an undefined pointer, slice or error set, then unwrapped (#232)" {
    try expectHollow(
        \\fn copyOptional(a: Allocator, src: *const ?[]const u8, dst: *?[]const u8) !void {
        \\    if (src.*) |*payload| {
        \\        dst.* = @as([]const u8, undefined);
        \\        try copySlice(a, payload, &dst.*.?);
        \\    } else dst.* = null;
        \\}
        \\const Node = struct { next: ?*Node, err: ?anyerror, fail: ?error{Full}, name: ?[:0]const u8 };
        \\fn link(n: *Node, to: *Node) void { n.next = @as(*Node, undefined); n.next.? = to; }
        \\fn fail(n: *Node) void { n.err = (@as(anyerror, undefined)); if (n.err) |*e| e.* = error.Boom; }
        \\fn full(n: *Node) void { n.fail = @as(error{Full}, undefined); _ = n.fail orelse return; }
        \\const Name = [:0]const u8;
        \\fn name(n: *Node) void { n.name = @as(Name, undefined); if (n.name != null) fill(&n.name.?); }
        \\fn local() void { var slot: ?[*]u8 = @as([*]u8, undefined); while (slot) |s| { _ = s; slot = null; } }
        \\fn later(n: *Node) void { n.next = @as(*Node, undefined); defer n.next = null; if (null == n.next) return; }
    ,
        \\3:9 dst.* = []const u8, dst.*.?
        \\8:37 n.next = *Node, n.next.?
        \\9:26 n.err = anyerror, if (n.err)
        \\10:26 n.fail = error{Full}, n.fail orelse
        \\12:26 n.name = Name, n.name != null
        \\13:23 slot = [*]u8, while (slot)
        \\14:27 n.next = *Node, null == n.next
        \\
    );
}

test "a payload a generic function is given: a type parameter, or the child of an optional's type info" {
    try expectHollow(
        \\fn set(comptime T: type, dst: *?T, v: T) void { dst.* = @as(T, undefined); dst.*.? = v; }
        \\fn parseInto(comptime T: type, c: *Ctx, out: *T) !void {
        \\    switch (@typeInfo(T)) {
        \\        .optional => |o| {
        \\            out.* = @as(o.child, undefined);
        \\            return parseInto(o.child, c, &out.*.?);
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\fn Slot(comptime T: type) type { return struct { v: ?T = null, fn take(s: *@This()) *T { s.v = @as(T, undefined); return &s.v.?; } }; }
    ,
        \\1:49 dst.* = T, dst.*.? (generic)
        \\5:13 out.* = o.child, out.*.? (generic)
        \\11:90 s.v = T, s.v.? (generic)
        \\
    );
}

test "not reported: a payload with a flag of its own, or not shown, a store or address first, a pointer read aside, no unwrap" {
    try expectHollow(
        \\const Rec = struct { n: ?u32, s: ?Session, a: ?[4]u8, c: ?[*c]u8, z: ?*allowzero u8, p: ?*u8 };
        \\fn int(r: *Rec) void { r.n = @as(u32, undefined); r.n.? = 7; }
        \\fn other(r: *Rec) void { r.s = @as(Session, undefined); r.s.?.open(); }
        \\fn module(r: *Rec) void { r.s = @as(other.Session, undefined); r.s.?.open(); }
        \\fn array(r: *Rec) void { r.a = @as([4]u8, undefined); r.a.?[0] = 1; }
        \\fn cptr(r: *Rec) void { r.c = @as([*c]u8, undefined); r.c.? = undefined; }
        \\fn zero(r: *Rec) void { r.z = @as(*allowzero u8, undefined); r.z.? = undefined; }
        \\fn whole(r: *Rec, b: *u8) void { r.p = @as(*u8, undefined); r.p = b; r.p.?.* = 1; }
        \\fn address(r: *Rec) void { r.p = @as(*u8, undefined); fill(&r.p); _ = r.p.?; }
        \\fn other_place(r: *Rec, q: *Rec) void { r.p = @as(*u8, undefined); _ = q.p.?; }
        \\fn before(r: *Rec) void { _ = r.p.?; r.p = @as(*u8, undefined); }
        \\fn never(r: *Rec) void { r.p = @as(*u8, undefined); }
        \\fn plain(r: *Rec) void { r.p = undefined; _ = r.p.?; }
        \\fn parseInto(comptime T: type, c: *Ctx, out: *T) !void {
        \\    switch (@typeInfo(T)) {
        \\        .optional => |o| {
        \\            if (comptime @typeInfo(o.child) == .pointer) {
        \\                var v: o.child = undefined;
        \\                try parseInto(o.child, c, &v);
        \\                out.* = v;
        \\                return;
        \\            }
        \\            out.* = @as(o.child, undefined);
        \\            return parseInto(o.child, c, &out.*.?);
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\fn result(r: *Rec, e: *anyerror!*u8) void { e.* = @as(*u8, undefined); if (e.*) |*v| v.* = r.p.? else |_| {} }
    , "");
}

test "the message and the hint" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\fn copy(dst: *?[]const u8, src: []const u8) void { dst.* = @as([]const u8, undefined); dst.*.? = src; }
        \\fn set(comptime T: type, dst: *?T, v: T) void { dst.* = @as(T, undefined); dst.*.? = v; }
    , .{});
    defer tree.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var findings: std.ArrayList(Finding) = .empty;
    try check(arena_state.allocator(), &tree, &findings);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (findings.items) |finding| {
        try report.writeMessage(&out.writer, finding);
        try out.writer.print("\n{s}\n", .{finding.hint});
    }
    try expect.findings(@src(),
        \\`dst.*` is given `@as([]const u8, undefined)`, then unwrapped by `dst.*.?`: an optional of a pointer, a slice or an error set keeps its null in the payload's own bits, which this leaves undefined: Debug's 0xaa fill reads as set, and a release build may drop the store and read as null what the bytes held before
        \\store a defined value in it first, as a copy of the source, then write the payload through `.?`; or build the payload in a local and assign the optional once
        \\`dst.*` is given `@as(T, undefined)`, then unwrapped by `dst.*.?`: when `T` is a pointer, a slice or an error set, its optional keeps its null in the payload's own bits, which this leaves undefined: Debug's 0xaa fill reads as set, and a release build may drop the store and read as null what the bytes held before
        \\store a defined value in it first, as a copy of the source, then write the payload through `.?`; or build the payload in a local and assign the optional once
        \\
    , out.written());
}
