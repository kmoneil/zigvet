//! Rule six, owner: one allocation freed by two errdefers, the caller's and
//! the one in the function it hands the allocation to.
//!
//!     /// Takes `bytes`, even when it fails.
//!     fn keep(self: *Store, bytes: []u8) !void {
//!         errdefer self.gpa.free(bytes);
//!         try self.kept.append(self.gpa, bytes);
//!     }
//!
//!     fn save(self: *Store, text: []const u8) !void {
//!         const bytes = try self.gpa.dupe(u8, text);
//!         errdefer self.gpa.free(bytes);
//!         try self.keep(bytes);
//!     }
//!
//! `keep` frees `bytes` itself when it fails. So when `append` fails, both
//! errdefers run, `keep`'s and then `save`'s, and the second frees freed
//! memory. It compiles clean in every build mode, and each function reads
//! correctly on its own, which is why review passes it: the bug is where
//! the two meet. The debugging allocator says "double free" only when a
//! test makes that allocation fail; a release build corrupts the heap and
//! says nothing.
//!
//! A function takes a parameter on failure when its body has
//! `errdefer x.free(p)`, `errdefer x.destroy(p)`,
//! `errdefer x.rawFree(p, ...)` or `errdefer p.deinit(...)` for the
//! parameter `p`, and something after it can fail: a `try` or a
//! `return error.X`. A call to it under `try` is reported when the argument
//! for that parameter is a name that an `errdefer` of the caller, declared
//! before the call in a block around it, frees the same way. The function
//! has to be the file's own, called by name, through its type
//! (`Store.keep(s, b)`), or as a method of a binding whose type the file
//! declares (`self.keep(b)`).
//!
//! Not reported: a call whose error is handled rather than returned with
//! `try`, which only the caller can judge; an `errdefer` declared after the
//! call; and an argument that is not a plain name.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const refill = @import("refill.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");
const Types = types.Types;

/// Appends a finding for every call that hands a function an allocation it
/// frees when it fails, from a caller whose own errdefer frees it too.
/// Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    const owners = try ownerNames(arena, tree);
    if (owners.count() == 0) return;
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings, .types = try .init(arena, tree) };
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .@"try") continue;
        var operand = tree.nodeData(node).node;
        while (tree.nodeTag(operand) == .grouped_expression) operand = tree.nodeData(operand).node_and_token[0];
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, operand) orelse continue;
        const name = switch (tree.nodeTag(call.ast.fn_expr)) {
            .identifier => tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr)),
            .field_access => tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]),
            else => continue,
        };
        if (owners.contains(name)) try rule.call(node, operand, call);
    }
}

/// The names of the functions with an `errdefer` that frees one of their
/// parameters, found by where each `errdefer` is, before anything costlier
/// is made: most files have errdefers, few free a parameter in one.
fn ownerNames(arena: Allocator, tree: *const Ast) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    // Every function, with its first and last token, made at the first
    // errdefer.
    const Function = struct { node: Node.Index, first: Ast.TokenIndex, last: Ast.TokenIndex };
    var functions: std.ArrayList(Function) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"errdefer") continue;
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (functions.items.len == 0) {
            for (tree.nodes.items(.tag), 0..) |t, j| {
                if (t != .fn_decl) continue;
                const f: Node.Index = @fromBackingInt(@intCast(j));
                try functions.append(arena, .{ .node = f, .first = tree.firstToken(f), .last = tree.lastToken(f) });
            }
        }
        // The innermost function around it.
        const at = tree.nodeMainToken(node);
        var around: ?Function = null;
        for (functions.items) |f| {
            if (at < f.first or at > f.last) continue;
            if (around == null or f.first > around.?.first) around = f;
        }
        const function = (around orelse continue).node;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]).?;
        var params = proto.iterate(tree);
        while (params.next()) |param| {
            const name_token = param.name_token orelse continue;
            if (frees(tree, tree.nodeData(node).node, tree.tokenSlice(name_token))) {
                try names.put(arena, fnName(tree, function), {});
            }
        }
    }
    return names;
}

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),
    types: Types,
    /// The parameters each function frees when it fails, by index, found
    /// once per function.
    taken: std.AutoHashMapUnmanaged(Node.Index, []const usize) = .empty,

    /// Checks `try f(...)`, with `operand` the call and `full` its parts,
    /// when `f` is the file's own function and takes a parameter on
    /// failure.
    fn call(r: *Rule, try_node: Node.Index, operand: Node.Index, full: Ast.full.Call) Allocator.Error!void {
        const tree = r.tree;
        const fn_decl, const receiver = r.types.callee(full.ast.fn_expr) orelse return;
        for (try r.takes(fn_decl)) |param| {
            // A method's receiver is its first parameter.
            if (param < receiver) continue;
            const at = param - receiver;
            if (at >= full.ast.params.len) continue;
            const argument = full.ast.params[at];
            if (tree.nodeTag(argument) != .identifier) continue;
            const name = tree.tokenSlice(tree.nodeMainToken(argument));
            if (!r.freedOnError(try_node, name)) continue;
            const function = fnName(tree, fn_decl);
            return r.findings.append(r.arena, .{
                .offset = tree.tokenStart(tree.firstToken(operand)),
                .hint = try r.arena.print("free it in one place: drop the errdefer here, or have {s} leave '{s}' to its caller when it fails", .{ function, name }),
                .detail = .{ .owner = .{
                    .callee = tree.getNodeSource(full.ast.fn_expr),
                    .argument = name,
                } },
            });
        }
    }

    /// The parameters `fn_decl` frees when it fails: each one an `errdefer`
    /// in its body frees, with something after it in its block that can
    /// fail.
    fn takes(r: *Rule, fn_decl: Node.Index) Allocator.Error![]const usize {
        if (r.taken.get(fn_decl)) |known| return known;
        const tree = r.tree;
        var found: std.ArrayList(usize) = .empty;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try r.within(tree.nodeData(fn_decl).node_and_node[1], &nodes);
        for (nodes.items) |node| {
            if (tree.nodeTag(node) != .@"errdefer") continue;
            var params = proto.iterate(tree);
            var index: usize = 0;
            while (params.next()) |param| : (index += 1) {
                const name_token = param.name_token orelse continue;
                if (!frees(tree, tree.nodeData(node).node, tree.tokenSlice(name_token))) continue;
                if (try r.failsAfter(node)) try found.append(r.arena, index);
            }
        }
        try r.taken.put(r.arena, fn_decl, found.items);
        return found.items;
    }

    /// Whether a statement after `statement` in its block can make the
    /// function fail: a `try` or a `return error.X`.
    fn failsAfter(r: *Rule, statement: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        const block = r.types.parents[@backingInt(statement)].unwrap() orelse return false;
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse return false;
        const at = std.mem.findScalar(Node.Index, statements, statement) orelse return false;
        for (statements[at + 1 ..]) |later| {
            var nodes: std.ArrayList(Node.Index) = .empty;
            try r.within(later, &nodes);
            for (nodes.items) |node| switch (tree.nodeTag(node)) {
                .@"try" => return true,
                .@"return" => {
                    const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
                    if (tree.nodeTag(value) == .error_value) return true;
                },
                else => {},
            };
        }
        return false;
    }

    /// Whether an `errdefer` that frees `name` is declared before `node`
    /// in a block around it, in the same function.
    fn freedOnError(r: *Rule, node: Node.Index, name: []const u8) bool {
        const tree = r.tree;
        var child = node;
        var up = r.types.parents[@backingInt(node)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = r.types.parents[@backingInt(parent)].unwrap();
        }) {
            if (tree.nodeTag(parent) == .fn_decl or tree.nodeTag(parent) == .test_decl) return false;
            var buffer: [2]Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, parent) orelse continue;
            for (statements) |statement| {
                if (statement == child) break;
                if (tree.nodeTag(statement) == .@"errdefer" and frees(tree, tree.nodeData(statement).node, name)) return true;
            }
        }
        return false;
    }

    /// Appends `node` and every node under it, but not what nested
    /// functions and types hold.
    fn within(r: *Rule, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
        switch (r.tree.nodeTag(node)) {
            .fn_decl,
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            => return,
            else => {},
        }
        try out.append(r.arena, node);
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, r.tree, node, &nodes);
        for (nodes.items) |child| try r.within(child, out);
    }
};

/// Whether `deferred`, what an `errdefer` runs, frees `name`: a release
/// of it (`x.free(name)`, `x.destroy(name)`, `name.deinit(...)`) alone or
/// as one statement of a block.
fn frees(tree: *const Ast, deferred: Node.Index, name: []const u8) bool {
    var buffer: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, deferred) orelse (&deferred)[0..1];
    for (statements) |statement| {
        _, const operand = refill.releaseCall(tree, statement) orelse continue;
        if (tree.nodeTag(operand) != .identifier) continue;
        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(operand)), name)) return true;
    }
    return false;
}

fn fnName(tree: *const Ast, fn_decl: Node.Index) []const u8 {
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
    return tree.tokenSlice(proto.name_token.?);
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col callee argument`, in source order.
fn expectOwners(source: [:0]const u8, expected: []const u8) !void {
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
        const o = finding.detail.owner;
        try out.writer.print("{d}:{d} {s} {s}\n", .{ loc.line + 1, loc.column + 1, o.callee, o.argument });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "an allocation freed by the caller's errdefer and the callee's (#40)" {
    try expectOwners(
        \\const Store = struct {
        \\    gpa: Allocator,
        \\    fn keep(self: *Store, bytes: []u8) !void { errdefer self.gpa.free(bytes); try self.kept.append(self.gpa, bytes); }
        \\    fn save(self: *Store, text: []const u8) !void { const bytes = try self.gpa.dupe(u8, text); errdefer self.gpa.free(bytes); try self.keep(bytes); }
        \\    fn typed(s: *Store, b: []u8) !void { errdefer s.gpa.free(b); if (b.len > 0) { try Store.keep(s, b); } }
        \\};
        \\fn adopt(gpa: Allocator, node: *Node) !void { errdefer gpa.destroy(node); if (node.bad) return error.Bad; }
        \\fn make(gpa: Allocator) !void { const node = try gpa.create(Node); errdefer gpa.destroy(node); try adopt(gpa, node); }
        \\fn hold(list: List) !void { errdefer { log(); list.deinit(); } try check(); }
        \\fn give(gpa: Allocator) !void { var list: List = .empty; errdefer list.deinit(); try hold(list); _ = gpa; }
        \\fn adoptRaw(gpa: Allocator, buf: []u8) !void { errdefer gpa.rawFree(buf, .@"1", 0); if (buf.len == 0) return error.Empty; }
        \\fn makeRaw(gpa: Allocator) !void { const buf = (gpa.rawAlloc(4, .@"1", 0) orelse return error.OutOfMemory)[0..4]; errdefer gpa.rawFree(buf, .@"1", 0); try adoptRaw(gpa, buf); }
    ,
        \\4:131 self.keep bytes
        \\5:87 Store.keep b
        \\8:100 adopt node
        \\10:86 hold list
        \\12:156 adoptRaw buf
        \\
    );
}

test "not reported: one errdefer, a handled error, an errdefer after the call, nothing to fail" {
    try expectOwners(
        \\const Store = struct {
        \\    gpa: Allocator,
        \\    fn keep(self: *Store, bytes: []u8) !void { errdefer self.gpa.free(bytes); try self.kept.append(self.gpa, bytes); }
        \\    fn handOver(self: *Store, text: []const u8) !void { try self.keep(try self.gpa.dupe(u8, text)); }
        \\    fn noErrdefer(self: *Store, text: []const u8) !void { const bytes = try self.gpa.dupe(u8, text); try self.keep(bytes); }
        \\    fn handled(self: *Store, text: []const u8) !void { const bytes = try self.gpa.dupe(u8, text); errdefer self.gpa.free(bytes); self.keep(bytes) catch {}; try more(); }
        \\    fn later(self: *Store, text: []const u8) !void { const bytes = try self.gpa.dupe(u8, text); try self.keep(bytes); errdefer self.gpa.free(bytes); try more(); }
        \\    fn otherArg(self: *Store, text: []const u8) !void { const bytes = try self.gpa.dupe(u8, text); errdefer self.gpa.free(bytes); try self.keep(self.spare); }
        \\    fn lastly(self: *Store, bytes: []u8) !void { try self.kept.append(self.gpa, bytes); errdefer self.gpa.free(bytes); }
        \\    fn useLastly(self: *Store, text: []const u8) !void { const bytes = try self.gpa.dupe(u8, text); errdefer self.gpa.free(bytes); try self.lastly(bytes); }
        \\    fn scoped(self: *Store, text: []const u8) !void { const bytes = try self.gpa.dupe(u8, text); { errdefer self.gpa.free(bytes); try more(); } try self.keep(bytes); }
        \\};
        \\fn borrow(gpa: Allocator, node: *Node) !void { try use(gpa, node); }
        \\fn lend(gpa: Allocator) !void { const node = try gpa.create(Node); errdefer gpa.destroy(node); try borrow(gpa, node); }
    , "");
}
