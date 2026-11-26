//! Rule twenty-eight, buckets: a std `HashMap`'s `capacity()` compared
//! with a count of items, to decide whether an insert that assumes
//! capacity has room.
//!
//!     fn room(s: *Set, gpa: Allocator) !void {
//!         if (s.map.capacity() <= s.count) try s.map.ensureTotalCapacity(gpa, 2 * s.count + 16);
//!         s.count += 1;
//!     }
//!     ...
//!     try s.room(gpa);
//!     s.map.putAssumeCapacity(k, {});
//!
//! `capacity()` of a `HashMap` or `HashMapUnmanaged` is its bucket count,
//! and the map holds only its max load of them, 80% by default, before
//! `available` runs out. So the test passes while there is no room, and
//! the insert that cannot fail takes `available` below zero: a panic in
//! Debug, undefined behavior in ReleaseFast. It compiles clean, passes
//! every test that stays under 80% of a power of two, and reads correctly:
//! `ArrayList` and the array hash maps count items, and the managed
//! `HashMap.capacity` doc comment even says "the number of total elements
//! which may be present before it is no longer guaranteed that no
//! allocations will be performed" (#226).
//!
//! What is reported is a call of `capacity()` on a map whose type the file
//! writes as one of std's hash maps (`std.AutoHashMapUnmanaged(K, V)`,
//! `std.StringHashMap(V)`, `std.hash_map.HashMap(...)`, or a name declared
//! as one), compared (`<`, `<=`, `>`, `>=`), by itself or in a sum or a
//! difference, with anything but `0`, in the condition of an `if` or a
//! `while`, when the function around it grows the same map
//! (`ensureTotalCapacity`, `ensureUnusedCapacity`) or inserts into it with
//! a `...AssumeCapacity` call, and the file inserts into it so somewhere.
//!
//! Not reported: an array hash map, whose `capacity()` counts items; a
//! map type the file declares, or one from another file, which may count
//! either way; a comparison outside a condition (`assert(m.capacity() >=
//! n)`, which only says the buckets are there); a comparison with `0`,
//! which asks whether the map has memory at all; and a map nothing inserts
//! into with a call that assumes room, whose `put` grows when it must.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const expect = @import("expect.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every `capacity()` of a std hash map tested as
/// room for items. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    // Few files insert assuming capacity: look before reading a node.
    if (std.mem.find(u8, tree.source, "AssumeCapacity") == null) return;
    if (std.mem.find(u8, tree.source, ".capacity()") == null) return;
    const t: types.Types = try .init(arena, tree);
    var calls: std.ArrayList(Call) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (mapCall(t, node)) |call| try calls.append(arena, call);
    }
    for (calls.items) |call| {
        if (!std.mem.eql(u8, call.method, "capacity") or call.params != 0) continue;
        if (!tested(t, call.node)) continue;
        const insert = fills(tree, t.parents, calls.items, call) orelse continue;
        try findings.append(arena, .{
            .offset = tree.tokenStart(tree.firstToken(call.node)),
            .hint = hint,
            .detail = .{ .buckets = .{
                .map = tree.getNodeSource(call.receiver),
                .insert = insert,
            } },
        });
    }
}

const hint = "ask for room counted in items instead: `ensureUnusedCapacity(..., 1)` before the insert, or `ensureTotalCapacity` with the number of items it is to hold";

/// A call of a method on a std hash map.
const Call = struct {
    node: Node.Index,
    /// The map, as written: `s.map`.
    receiver: Node.Index,
    method: []const u8,
    params: usize,
    /// The map's type as the file writes it, which is one node for each
    /// field or binding: two calls with the same one are on the same map.
    map: Node.Index,
};

/// `node` as a call of a method on a std hash map.
fn mapCall(t: types.Types, node: Node.Index) ?Call {
    const tree = t.tree;
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
    const of = t.typeOf(receiver, 0) orelse return null;
    const map = types.pointee(tree, of) orelse of;
    if (!stdHashMap(t, map, 0)) return null;
    return .{ .node = node, .receiver = receiver, .method = tree.tokenSlice(method), .params = call.ast.params.len, .map = map };
}

/// std's hash maps whose `capacity()` counts buckets. The array hash
/// maps' counts items.
const bucket_maps: std.StaticStringMap(void) = .initComptime(.{
    .{"HashMap"},              .{"HashMapUnmanaged"}, .{"AutoHashMap"},
    .{"AutoHashMapUnmanaged"}, .{"StringHashMap"},    .{"StringHashMapUnmanaged"},
});

/// Whether `type_expr` is one of std's hash maps that count buckets: a
/// call of one reached from `std` (`std.AutoHashMapUnmanaged(K, V)`), or a
/// name declared in a container around it as one.
fn stdHashMap(t: types.Types, type_expr: Node.Index, depth: u8) bool {
    const tree = t.tree;
    if (depth > 4) return false;
    switch (tree.nodeTag(type_expr)) {
        .identifier => return stdHashMap(t, declared(t, type_expr) orelse return false, depth + 1),
        else => {},
    }
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, type_expr) orelse return false;
    const name = fromStd(t, call.ast.fn_expr, 0) orelse return false;
    return bucket_maps.has(name);
}

/// The last name of `path` when it is reached from `std`, by itself or
/// through names declared in containers around it
/// (`const hash_map = std.hash_map;`): `AutoHashMap` of
/// `std.hash_map.AutoHashMap`, and an empty name for `std` itself.
fn fromStd(t: types.Types, path: Node.Index, depth: u8) ?[]const u8 {
    const tree = t.tree;
    if (depth > 8) return null;
    switch (tree.nodeTag(path)) {
        .field_access => {
            const lhs, const field = tree.nodeData(path).node_and_token;
            _ = fromStd(t, lhs, depth + 1) orelse return null;
            return tree.tokenSlice(field);
        },
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(path)), "@import")) return null;
            var buffer: [2]Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, path).?;
            if (params.len != 1 or !std.mem.eql(u8, tree.getNodeSource(params[0]), "\"std\"")) return null;
            return "";
        },
        .identifier => {
            if (declared(t, path)) |init| return fromStd(t, init, depth + 1);
            return if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(path)), "std")) "" else null;
        },
        else => return null,
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

/// Whether `capacity`, a call, is compared with something other than `0`,
/// by itself or in a sum or a difference, in the condition of an `if` or
/// a `while`.
fn tested(t: types.Types, capacity: Node.Index) bool {
    const tree = t.tree;
    var child = capacity;
    var up = t.parents[@backingInt(capacity)].unwrap();
    // Up to the comparison.
    while (up) |parent| : ({
        child = parent;
        up = t.parents[@backingInt(parent)].unwrap();
    }) {
        switch (tree.nodeTag(parent)) {
            .grouped_expression, .add, .sub, .add_wrap, .sub_wrap => continue,
            .builtin_call_two, .builtin_call_two_comma => if (converts(tree, parent)) continue else return false,
            .less_than, .less_or_equal, .greater_than, .greater_or_equal => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                const other = if (lhs == child) rhs else lhs;
                if (tree.nodeTag(other) == .number_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(other)), "0")) return false;
                child = parent;
                up = t.parents[@backingInt(parent)].unwrap();
                break;
            },
            else => return false,
        }
    } else return false;
    // Up to the condition it is in.
    while (up) |parent| : ({
        child = parent;
        up = t.parents[@backingInt(parent)].unwrap();
    }) {
        switch (tree.nodeTag(parent)) {
            .grouped_expression, .bool_and, .bool_or, .bool_not => continue,
            .if_simple, .@"if" => return tree.fullIf(parent).?.ast.cond_expr == child,
            .while_simple, .while_cont, .@"while" => return tree.fullWhile(parent).?.ast.cond_expr == child,
            else => return false,
        }
    }
    return false;
}

/// Whether `node`, a builtin call, converts its last argument
/// (`@as(u32, x)`, `@intCast(x)`, `@truncate(x)`).
fn converts(tree: *const Ast, node: Node.Index) bool {
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    for ([_][]const u8{ "@as", "@intCast", "@truncate" }) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}

/// The insert, among `calls`, that the test of `capacity` makes room for:
/// when the function around it grows the same map or inserts into it with
/// a call that assumes room, a `...AssumeCapacity` insert into that map,
/// the function's first, else the file's.
fn fills(tree: *const Ast, parents: []const Node.OptionalIndex, calls: []const Call, capacity: Call) ?[]const u8 {
    const body = bodyAround(tree, parents, capacity.node) orelse return null;
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    var grows = false;
    var here: ?[]const u8 = null;
    var anywhere: ?[]const u8 = null;
    for (calls) |call| {
        if (call.map != capacity.map) continue;
        const token = tree.firstToken(call.node);
        const inside = token >= first and token <= last;
        if (assumesRoom(call.method)) {
            if (anywhere == null) anywhere = call.method;
            if (inside and here == null) here = call.method;
        } else if (inside and std.mem.startsWith(u8, call.method, "ensure")) grows = true;
    }
    if (here) |method| return method;
    return if (grows) anywhere else null;
}

/// Whether `method` inserts into a hash map assuming it has room:
/// `putAssumeCapacity`, `getOrPutAssumeCapacityAdapted` and the like.
fn assumesRoom(method: []const u8) bool {
    if (std.mem.find(u8, method, "AssumeCapacity") == null) return false;
    for ([_][]const u8{ "put", "getOrPut", "fetchPut" }) |prefix| {
        if (std.mem.startsWith(u8, method, prefix)) return true;
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

/// Runs the rule over `source` and compares one line per finding,
/// `line:col map insert`, in source order.
fn expectBuckets(source: [:0]const u8, expected: []const u8) !void {
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
        const b = finding.detail.buckets;
        try out.writer.print("{d}:{d} {s} {s}\n", .{ loc.line + 1, loc.column + 1, b.map, b.insert });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a hash map's capacity() tested as room for items before an insert that assumes it (#226)" {
    try expectBuckets(
        \\const std = @import("std");
        \\const Set = struct {
        \\    map: std.AutoHashMapUnmanaged(u32, void) = .empty,
        \\    count: u32 = 0,
        \\    fn room(s: *Set, gpa: std.mem.Allocator) !void { if (s.map.capacity() <= s.count) try s.map.ensureTotalCapacity(gpa, 2 * s.count + 16); s.count += 1; }
        \\    fn add(s: *Set, k: u32) void { s.map.putAssumeCapacity(k, {}); }
        \\};
        \\const Map = std.StringHashMap(u8);
        \\fn full(m: *Map, k: []const u8) !void { if (m.count() >= m.capacity()) return error.Full; m.putAssumeCapacityNoClobber(k, 0); }
        \\const hash_map = std.hash_map;
        \\fn spare(m: *hash_map.AutoHashMap(u8, u8), gpa: std.mem.Allocator, n: u32) !void { while ((m.capacity() - m.count()) < n) try m.ensureUnusedCapacity(gpa, 8); _ = m.getOrPutAssumeCapacity(1); }
        \\fn local(gpa: std.mem.Allocator) !void { var m: @import("std").HashMapUnmanaged(u8, u8, Ctx, 50) = .empty; if (n > 0 and @as(u32, m.capacity()) < n) try m.ensureTotalCapacity(gpa, n); m.putAssumeCapacity(1, 1); }
    ,
        \\5:58 s.map putAssumeCapacity
        \\9:58 m putAssumeCapacityNoClobber
        \\11:92 m getOrPutAssumeCapacity
        \\12:131 m putAssumeCapacity
        \\
    );
}

test "not reported: an array hash map, a map of the file's, an assert, a test of 0, no insert that assumes room" {
    try expectBuckets(
        \\const std = @import("std");
        \\fn array(m: *std.AutoArrayHashMapUnmanaged(u8, u8), gpa: std.mem.Allocator, n: u32) !void { if (m.capacity() < n) try m.ensureTotalCapacity(gpa, n); m.putAssumeCapacity(1, 1); }
        \\const Own = struct { fn capacity(o: Own) u32 { _ = o; return 0; } fn putAssumeCapacity(o: *Own) void { _ = o; } };
        \\fn own(o: *Own, n: u32) void { if (o.capacity() < n) return; o.putAssumeCapacity(); }
        \\fn other(m: *other_file.AutoHashMap(u8, u8), n: u32) void { if (m.capacity() < n) return; m.putAssumeCapacity(1, 1); }
        \\fn asserted(m: *std.AutoHashMapUnmanaged(u8, u8), gpa: std.mem.Allocator, n: u32) !void { try m.ensureTotalCapacity(gpa, n); std.debug.assert(m.capacity() >= n); m.putAssumeCapacity(1, 1); }
        \\fn empty(m: *std.AutoHashMapUnmanaged(u8, u8), gpa: std.mem.Allocator) !void { if (m.capacity() > 0) return; try m.ensureTotalCapacity(gpa, 4); m.putAssumeCapacity(1, 1); }
        \\fn grows(m: *std.AutoHashMapUnmanaged(u8, u8), gpa: std.mem.Allocator, n: u32) !void { if (m.capacity() < n) try m.ensureTotalCapacity(gpa, n); try m.put(gpa, 1, 1); }
        \\const Two = struct {
        \\    a: std.AutoHashMapUnmanaged(u8, u8) = .empty,
        \\    b: std.AutoHashMapUnmanaged(u8, u8) = .empty,
        \\    fn room(t: *Two, gpa: std.mem.Allocator, n: u32) !void { if (t.a.capacity() < n) try t.a.ensureTotalCapacity(gpa, n); t.b.putAssumeCapacity(1, 1); }
        \\    fn shrink(t: *Two, gpa: std.mem.Allocator) void { if (t.b.capacity() > 4096) t.b.clearAndFree(gpa); }
        \\};
    , "");
}

test "the message and the hint" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\const std = @import("std");
        \\fn room(m: *std.AutoHashMapUnmanaged(u32, void), gpa: std.mem.Allocator, n: u32) !void { if (m.capacity() <= n) try m.ensureTotalCapacity(gpa, 2 * n); m.putAssumeCapacity(n, {}); }
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
        \\`m.capacity()` counts buckets, and a hash map fills only its max load of them, 80% by default, before an insert must grow: tested as room for items, it says there is room when there is none, and putAssumeCapacity takes the map's `available` below zero, a panic in Debug and undefined behavior in ReleaseFast
        \\ask for room counted in items instead: `ensureUnusedCapacity(..., 1)` before the insert, or `ensureTotalCapacity` with the number of items it is to hold
        \\
    , out.written());
}
