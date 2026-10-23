//! Rule seven, kept: an `errdefer` frees what the function has already
//! stored where its caller keeps it.
//!
//!     fn put(self: *Store, name: []const u8) !void {
//!         const owned = try self.gpa.dupe(u8, name);
//!         errdefer self.gpa.free(owned);
//!         try self.names.append(self.gpa, owned);
//!         try self.sizes.append(self.gpa, name.len);
//!     }
//!
//! When the second `append` fails, the errdefer frees `owned`, but
//! `self.names` already holds it, and `self` goes back to a caller that
//! still owns it: its `deinit` frees `owned` again, and anything that reads
//! `names` first reads freed memory. It compiles clean in every build mode
//! and goes wrong only when the step after the store fails, the path tests
//! seldom take. It is the third shape of one mistake, after refill and
//! owner: a failure that leaves what the caller owns holding freed memory.
//!
//! What frees is an `errdefer` of `x.free(name)`, `x.destroy(name)`,
//! `x.rawFree(name, ...)` or `name.deinit(...)`, alone or in a block. A
//! store is `name` itself handed to `append`, `appendAssumeCapacity`,
//! `insert`, `put`, `putAssumeCapacity` or `putNoClobber`, as an argument
//! or a field of one (`.{ .name = name }`), or assigned to a field or what
//! a pointer points at (`self.pty = name`, or in a field initializer),
//! where what holds it is reached through a parameter, or through a local
//! pointer made from one (`const self: *T = @ptrCast(@alignCast(ctx));`).
//! It is reported when, after the store and on its path, before the
//! errdefer's block ends, something makes the function fail with the
//! errdefer armed: a `try`, a `return error.X`, or a handler that returns
//! the error it caught.
//!
//! Not reported: a store into a local, which the failing function throws
//! away; a value made from `name` (`name.toOwnedSlice(...)`, `name.len`),
//! which is not what the errdefer frees; a store in a function that makes
//! what holds it, one named `init...` or one that writes it whole
//! (`self.* = .{ ... }`), whose caller holds nothing of it if it fails; a
//! store a `defer` or `errdefer` armed before the failure can undo, one
//! that names what holds it (`errdefer _ = self.names.pop();`,
//! `defer self.pending = null;`) or, declared after the store, hands
//! `name` to a call that does not free it (`errdefer self.disown(conn);`);
//! and a failure on a branch the store is not on, or after a `return`,
//! `break` or `continue` that ends its path.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const refill = @import("refill.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every errdefer that frees what its function has
/// stored where the caller keeps it before something fails. Everything is
/// allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"errdefer") continue;
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const name = freedName(tree, tree.nodeData(node).node) orelse continue;
        try rule.errdeferred(node, name);
    }
}

const hint = "make the store the last step that can fail (reserve with `ensureUnusedCapacity`, then `appendAssumeCapacity`), or undo it in an errdefer after it";

/// The methods that keep what they are handed.
const keeping: std.StaticStringMap(void) = .initComptime(.{
    .{"append"},
    .{"appendAssumeCapacity"},
    .{"insert"},
    .{"put"},
    .{"putAssumeCapacity"},
    .{"putNoClobber"},
});

/// A store of a name: the call or assignment, and what it hands the name
/// to (`self.names`, `self.pty`).
const Store = struct {
    node: Node.Index,
    holder: Node.Index,
};

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),
    /// Every node's parent, made at the first errdefer that frees a name.
    parents: []const Node.OptionalIndex = &.{},

    /// Reports `errdefer_node`, which frees `name`, if `name` is stored
    /// where the caller keeps it and something fails after the store with
    /// the errdefer armed.
    fn errdeferred(r: *Rule, errdefer_node: Node.Index, name: []const u8) Allocator.Error!void {
        const tree = r.tree;
        if (r.parents.len == 0) r.parents = (try types.Types.init(r.arena, tree)).parents;
        const block = r.parents[@backingInt(errdefer_node)].unwrap() orelse return;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try r.within(block, &nodes);
        for (nodes.items) |node| {
            // A store before the errdefer may be of another binding of the
            // name, a capture of a loop that ended before it was declared.
            if (tree.nodeMainToken(node) < tree.nodeMainToken(errdefer_node)) continue;
            const store = r.storeOf(node, name) orelse continue;
            if (!r.callersOwn(store.holder)) continue;
            if (try r.initializes(errdefer_node, store.holder)) continue;
            const holder = tree.getNodeSource(store.holder);
            const point = try r.failsAfter(store.node, block, tree.nodeMainToken(errdefer_node)) orelse continue;
            if (try r.undone(errdefer_node, store.node, name, holder, point)) continue;
            return r.findings.append(r.arena, .{
                .offset = tree.tokenStart(tree.nodeMainToken(errdefer_node)),
                .hint = hint,
                .detail = .{ .kept = .{
                    .name = name,
                    .holder = holder,
                    .fails = try r.what(point),
                } },
            });
        }
    }

    /// `node` as a store of `name`: `name`, or a field initializer holding
    /// it, handed to one of `keeping` called on something, or assigned to
    /// a field or what a pointer points at.
    fn storeOf(r: *Rule, node: Node.Index, name: []const u8) ?Store {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        if (tree.fullCall(&buffer, node)) |call| {
            if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
            const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
            if (!keeping.has(tree.tokenSlice(method))) return null;
            for (call.ast.params) |param| {
                if (holds(tree, param, name)) return .{ .node = node, .holder = receiver };
            }
            return null;
        }
        if (tree.nodeTag(node) != .assign) return null;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        if (tree.nodeTag(lhs) == .identifier or !holds(tree, rhs, name)) return null;
        return .{ .node = node, .holder = lhs };
    }

    /// Whether `holder` is reached through a parameter of the function
    /// around it, or through a local pointer made from one.
    fn callersOwn(r: *Rule, holder: Node.Index) bool {
        const tree = r.tree;
        const root = rootOf(tree, holder) orelse return false;
        const name = tree.tokenSlice(tree.nodeMainToken(root));
        // A local declared before it, in a block around it.
        var child = root;
        var up = r.parents[@backingInt(root)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = r.parents[@backingInt(parent)].unwrap();
        }) {
            if (tree.nodeTag(parent) == .fn_decl) return isParam(tree, parent, name);
            if (tree.nodeTag(parent) == .test_decl) return false;
            var buffer: [2]Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, parent) orelse continue;
            for (statements) |statement| {
                if (statement == child) break;
                const decl = tree.fullVarDecl(statement) orelse continue;
                if (!std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)) continue;
                const init = decl.ast.init_node.unwrap() orelse return false;
                return r.callersOwn(pointerFrom(tree, init) orelse return false);
            }
        }
        return false;
    }

    /// Whether the function around `node` makes what `holder` is reached
    /// through: it is named `init...`, or writes it whole
    /// (`self.* = .{ ... }`). Its caller holds nothing of it until it
    /// returns, and the errdefers are what free it when it fails.
    fn initializes(r: *Rule, node: Node.Index, holder: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        const root = tree.tokenSlice(tree.nodeMainToken(rootOf(tree, holder).?));
        var function = node;
        while (r.parents[@backingInt(function)].unwrap()) |parent| {
            function = parent;
            if (tree.nodeTag(function) == .fn_decl or tree.nodeTag(function) == .test_decl) break;
        }
        const body = switch (tree.nodeTag(function)) {
            .fn_decl => tree.nodeData(function).node_and_node[1],
            .test_decl => tree.nodeData(function).opt_token_and_node[1],
            else => return false,
        };
        // An `init` that fails leaves its caller nothing to deinit, so the
        // errdefers free what it made, whatever holds it.
        if (tree.nodeTag(function) == .fn_decl) {
            var buffer: [1]Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]).?;
            if (proto.name_token) |token| if (std.mem.startsWith(u8, tree.tokenSlice(token), "init")) return true;
        }
        var nodes: std.ArrayList(Node.Index) = .empty;
        try r.within(body, &nodes);
        for (nodes.items) |n| {
            if (tree.nodeTag(n) != .assign) continue;
            const lhs = tree.nodeData(n).node_and_node[0];
            if (tree.nodeTag(lhs) == .deref and isName(tree, tree.nodeData(lhs).node, root)) return true;
        }
        return false;
    }

    /// The first thing after `store`, on its path, that makes the function
    /// fail with the errdefer at `armed` armed, before `block`, the
    /// errdefer's, ends. Null if the path leaves first.
    fn failsAfter(r: *Rule, store: Node.Index, block: Node.Index, armed: Ast.TokenIndex) Allocator.Error!?Node.Index {
        const tree = r.tree;
        var child = store;
        var up = r.parents[@backingInt(store)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = r.parents[@backingInt(parent)].unwrap();
        }) {
            switch (tree.nodeTag(parent)) {
                .fn_decl, .test_decl => return null,
                else => {},
            }
            var buffer: [2]Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, parent) orelse continue;
            const at = std.mem.findScalar(Node.Index, statements, child) orelse return null;
            for (statements[at + 1 ..]) |statement| {
                if (try r.failing(statement, armed)) |point| return point;
                switch (tree.nodeTag(statement)) {
                    .@"return", .@"break", .@"continue" => return null,
                    else => {},
                }
            }
            if (parent == block) return null;
        }
        return null;
    }

    /// Whether a `defer` or `errdefer` of the function, other than
    /// `errdefer_node` and armed before `point`, can undo `store`: one that
    /// names `holder` (`errdefer _ = self.names.pop();`,
    /// `defer self.pending = null;`), or one after the store that hands
    /// `name` to a call that does not free it (`errdefer self.disown(conn);`).
    fn undone(r: *Rule, errdefer_node: Node.Index, store: Node.Index, name: []const u8, holder: []const u8, point: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        var function = errdefer_node;
        while (r.parents[@backingInt(function)].unwrap()) |parent| {
            function = parent;
            if (tree.nodeTag(function) == .fn_decl or tree.nodeTag(function) == .test_decl) break;
        }
        var errdefers: std.ArrayList(Node.Index) = .empty;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, tree, function, &nodes);
        for (nodes.items) |child| try r.errdefersIn(child, &errdefers);
        for (errdefers.items) |node| {
            if (node == errdefer_node or tree.nodeMainToken(node) > tree.nodeMainToken(point)) continue;
            if (std.mem.indexOf(u8, tree.getNodeSource(node), holder) != null) return true;
            if (tree.nodeMainToken(node) < tree.nodeMainToken(store)) continue;
            var deferred: std.ArrayList(Node.Index) = .empty;
            try r.withinAll(tree.nodeData(node).node, &deferred);
            for (deferred.items) |d| {
                var buffer: [1]Node.Index = undefined;
                const call = tree.fullCall(&buffer, d) orelse continue;
                if (refill.releaseCall(tree, d) != null) continue;
                for (call.ast.params) |param| if (isName(tree, param, name)) return true;
            }
        }
        return false;
    }

    /// The first node of `statement`, after token `armed`, that makes the
    /// function fail: a `try`, a `return error.X`, or a `return` of what a
    /// `catch` around it caught.
    fn failing(r: *Rule, statement: Node.Index, armed: Ast.TokenIndex) Allocator.Error!?Node.Index {
        const tree = r.tree;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try r.within(statement, &nodes);
        var first: ?Node.Index = null;
        for (nodes.items) |node| {
            if (tree.nodeMainToken(node) <= armed) continue;
            const fails = switch (tree.nodeTag(node)) {
                .@"try" => true,
                .@"return" => r.returnsError(node),
                else => false,
            };
            if (!fails) continue;
            if (first == null or tree.nodeMainToken(node) < tree.nodeMainToken(first.?)) first = node;
        }
        return first;
    }

    /// Whether `node`, a `return`, returns an error: `error.X`, or what the
    /// `catch |err|` around it caught.
    fn returnsError(r: *Rule, node: Node.Index) bool {
        const tree = r.tree;
        const value = tree.nodeData(node).opt_node.unwrap() orelse return false;
        if (tree.nodeTag(value) == .error_value) return true;
        if (tree.nodeTag(value) != .identifier) return false;
        const name = tree.tokenSlice(tree.nodeMainToken(value));
        var up = r.parents[@backingInt(node)].unwrap();
        while (up) |parent| : (up = r.parents[@backingInt(parent)].unwrap()) {
            switch (tree.nodeTag(parent)) {
                .fn_decl, .test_decl => return false,
                .@"catch" => {
                    const token = tree.nodeMainToken(parent);
                    if (tree.tokenTag(token + 1) == .pipe and std.mem.eql(u8, tree.tokenSlice(token + 2), name)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// What fails at `point`, as the message says it: `gpa.alloc fails`,
    /// or `it returns error.Busy`.
    fn what(r: *Rule, point: Node.Index) Allocator.Error![]const u8 {
        const tree = r.tree;
        if (tree.nodeTag(point) == .@"return") {
            return r.arena.print("it returns {s}", .{tree.getNodeSource(tree.nodeData(point).opt_node.unwrap().?)});
        }
        var operand = tree.nodeData(point).node;
        while (tree.nodeTag(operand) == .grouped_expression) operand = tree.nodeData(operand).node_and_token[0];
        var buffer: [1]Node.Index = undefined;
        const failing_expr = if (tree.fullCall(&buffer, operand)) |call| call.ast.fn_expr else operand;
        return r.arena.print("{s} fails", .{tree.getNodeSource(failing_expr)});
    }

    /// Appends `node` and every node under it, but not what nested
    /// functions and types hold, or what a `defer` or `errdefer` runs.
    fn within(r: *Rule, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
        if (isNested(r.tree.nodeTag(node))) return;
        switch (r.tree.nodeTag(node)) {
            .@"defer", .@"errdefer" => return,
            else => {},
        }
        try out.append(r.arena, node);
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, r.tree, node, &nodes);
        for (nodes.items) |child| try r.within(child, out);
    }

    /// Appends `node` and every node under it, but not what nested
    /// functions and types hold.
    fn withinAll(r: *Rule, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
        if (isNested(r.tree.nodeTag(node))) return;
        try out.append(r.arena, node);
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, r.tree, node, &nodes);
        for (nodes.items) |child| try r.withinAll(child, out);
    }

    /// Appends every `defer` and `errdefer` in `node`, but not in nested
    /// functions and types.
    fn errdefersIn(r: *Rule, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
        if (isNested(r.tree.nodeTag(node))) return;
        if (r.tree.nodeTag(node) == .@"errdefer" or r.tree.nodeTag(node) == .@"defer") return out.append(r.arena, node);
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, r.tree, node, &nodes);
        for (nodes.items) |child| try r.errdefersIn(child, out);
    }
};

fn isNested(tag: Node.Tag) bool {
    return switch (tag) {
        .fn_decl,
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => true,
        else => false,
    };
}

/// The name an errdefer's `deferred` frees: `x.free(name)`,
/// `x.destroy(name)`, `x.rawFree(name, ...)` or `name.deinit(...)`, alone or
/// as a statement of a block.
fn freedName(tree: *const Ast, deferred: Node.Index) ?[]const u8 {
    var buffer: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, deferred) orelse (&deferred)[0..1];
    for (statements) |statement| {
        _, const operand = refill.releaseCall(tree, statement) orelse continue;
        if (tree.nodeTag(operand) == .identifier) return tree.tokenSlice(tree.nodeMainToken(operand));
    }
    return null;
}

/// Whether `value` is `name`, or an initializer with `name` as a field.
fn holds(tree: *const Ast, value: Node.Index, name: []const u8) bool {
    if (isName(tree, value, name)) return true;
    var buffer: [2]Node.Index = undefined;
    const init = tree.fullStructInit(&buffer, value) orelse return false;
    for (init.ast.fields) |field| if (isName(tree, field, name)) return true;
    return false;
}

fn isName(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

/// The variable `node` is reached from: `self` of `self.names.items`.
fn rootOf(tree: *const Ast, node: Node.Index) ?Node.Index {
    var n = node;
    while (true) switch (tree.nodeTag(n)) {
        .identifier => return n,
        .field_access, .unwrap_optional, .grouped_expression => n = tree.nodeData(n).node_and_token[0],
        .array_access => n = tree.nodeData(n).node_and_node[0],
        .deref => n = tree.nodeData(n).node,
        else => return null,
    };
}

/// What a local pointer's initializer points into: `ctx` of
/// `@ptrCast(@alignCast(ctx))`, or `self.items` of `&self.items`. Null for
/// anything else, such as a call's result or a copy.
fn pointerFrom(tree: *const Ast, init: Node.Index) ?Node.Index {
    var n = init;
    var pointer = false;
    while (true) switch (tree.nodeTag(n)) {
        .grouped_expression => n = tree.nodeData(n).node_and_token[0],
        .address_of => {
            pointer = true;
            n = tree.nodeData(n).node;
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const builtin = tree.tokenSlice(tree.nodeMainToken(n));
            var buffer: [2]Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, n).?;
            if (std.mem.eql(u8, builtin, "@ptrCast") or std.mem.eql(u8, builtin, "@alignCast") or std.mem.eql(u8, builtin, "@constCast")) {
                if (params.len != 1) return null;
                pointer = true;
                n = params[0];
            } else if (std.mem.eql(u8, builtin, "@fieldParentPtr")) {
                if (params.len != 2) return null;
                pointer = true;
                n = params[1];
            } else return null;
        },
        .identifier, .field_access, .unwrap_optional, .deref, .array_access => return if (pointer) n else null,
        else => return null,
    };
}

fn isParam(tree: *const Ast, fn_decl: Node.Index, name: []const u8) bool {
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
    var params = proto.iterate(tree);
    while (params.next()) |param| {
        const token = param.name_token orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(token), name)) return true;
    }
    return false;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col name holder <- what fails`, in source order.
fn expectKept(source: [:0]const u8, expected: []const u8) !void {
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
        const k = finding.detail.kept;
        try out.writer.print("{d}:{d} {s} {s} <- {s}\n", .{ loc.line + 1, loc.column + 1, k.name, k.holder, k.fails });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "an errdefer frees what the function stored where its caller keeps it (#63)" {
    try expectKept(
        \\fn put(self: *Store, name: []const u8) !void { const owned = try self.gpa.dupe(u8, name); errdefer self.gpa.free(owned); try self.names.append(self.gpa, owned); try self.sizes.append(self.gpa, name.len); }
        \\fn named(self: *Gen, prefix: []const u8, id: u64) !Sym { const name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ prefix, id }); errdefer self.allocator.free(name); try self.names.append(self.allocator, name); return try self.addSymbol(name); }
        \\fn restart(self: *Term) !void { var pty = try Pty.init(); errdefer pty.deinit(self.io); self.pty = pty; self.mode = .{}; try self.spawn(); }
        \\fn open(self: *Popup, menu: *const Menu) !void { const level = try self.allocator.create(Level); errdefer self.allocator.destroy(level); try self.levels.ensureUnusedCapacity(self.allocator, 1); self.levels.appendAssumeCapacity(level); if (menu.on_open) |*cmd| try cmd.send(); }
        \\fn write(ctx: ?*anyopaque, path: []const u8) !void { const self: *Rec = @ptrCast(@alignCast(ctx.?)); const recorded = try self.allocator.dupe(u8, path); errdefer self.allocator.free(recorded); try self.written.append(self.allocator, recorded); try self.put(path); }
        \\fn keyed(self: *Map, k: u32, v: []const u8) !void { const owned = try self.gpa.dupe(u8, v); errdefer self.gpa.free(owned); try self.map.put(self.gpa, k, .{ .text = owned, .at = 0 }); if (k == 0) return error.Zero; }
        \\fn caught(self: *Store, v: []const u8) !void { const owned = try self.gpa.dupe(u8, v); errdefer self.gpa.free(owned); self.last = owned; self.flush() catch |err| return err; }
    ,
        \\1:91 owned self.names <- self.sizes.append fails
        \\2:139 name self.names <- self.addSymbol fails
        \\3:59 pty self.pty <- self.spawn fails
        \\4:98 level self.levels <- cmd.send fails
        \\5:154 recorded self.written <- self.put fails
        \\6:93 owned self.map <- it returns error.Zero
        \\7:88 owned self.last <- it returns err
        \\
    );
}

test "not reported: a local, a value made from it, undone, or a failure off the store's path" {
    try expectKept(
        \\fn local(gpa: Allocator, v: []const u8) !List { var list: List = .empty; const owned = try gpa.dupe(u8, v); errdefer gpa.free(owned); try list.append(gpa, owned); try more(); return list; }
        \\fn made(self: *S) !void { var refs: List = .empty; errdefer refs.deinit(self.gpa); try refs.append(self.gpa, 1); self.refs = try refs.toOwnedSlice(self.gpa); try more(); }
        \\fn popped(self: *Store, v: []const u8) !void { const owned = try self.gpa.dupe(u8, v); errdefer self.gpa.free(owned); try self.names.append(self.gpa, owned); errdefer _ = self.names.pop(); try more(); }
        \\fn shrunk(self: *Store, v: []const u8) !void { const n = self.names.items.len; errdefer self.names.shrinkRetainingCapacity(n); const owned = try self.gpa.dupe(u8, v); errdefer self.gpa.free(owned); try self.names.append(self.gpa, owned); try more(); }
        \\fn last(self: *Store, v: []const u8) !void { try more(); const owned = try self.gpa.dupe(u8, v); errdefer self.gpa.free(owned); try self.names.append(self.gpa, owned); }
        \\fn branch(self: *Store, v: []const u8, found: bool) !void { const owned = try self.gpa.dupe(u8, v); errdefer self.gpa.free(owned); if (found) { self.names.items[0] = owned; return; } try more(); }
        \\fn other(self: *Store, v: []const u8, found: bool) !void { const owned = try self.gpa.dupe(u8, v); errdefer self.gpa.free(owned); if (found) self.last = owned else try more(); }
        \\fn fresh(gpa: Allocator, v: []const u8) !*Node { const node = try gpa.create(Node); errdefer gpa.destroy(node); const name = try gpa.dupe(u8, v); errdefer gpa.free(name); node.name = name; try more(); return node; }
        \\fn copy(self: *Store, v: []const u8) !void { var names = self.names; const owned = try self.gpa.dupe(u8, v); errdefer self.gpa.free(owned); try names.append(self.gpa, owned); try more(); }
        \\fn handled(self: *Store, v: []const u8) !void { const owned = try self.gpa.dupe(u8, v); errdefer self.gpa.free(owned); try self.names.append(self.gpa, owned); self.flush() catch {}; }
        \\fn init(self: *Term, gpa: Allocator) !void { const buf = try gpa.alloc(u8, 4); errdefer gpa.free(buf); self.* = .{ .buf = buf }; try self.spawn(); }
        \\fn initFields(self: *Term, gpa: Allocator) !void { self.* = .{}; const buf = try gpa.alloc(u8, 4); errdefer gpa.free(buf); self.buf = buf; try self.spawn(); }
        \\fn initOwned(self: *Term, gpa: Allocator) !void { const buf = try gpa.alloc(u8, 4); errdefer gpa.free(buf); self.buf = buf; try self.spawn(); }
        \\fn deferred(self: *Store, v: []const u8) !void { const staging = try self.gpa.dupe(u8, v); errdefer self.gpa.free(staging); self.pending = staging; defer self.pending = null; try more(); }
        \\fn disowned(self: *Pool) !void { const conn = try self.pool.create(self.gpa); errdefer self.pool.destroy(conn); self.list.insert(conn); errdefer self.disown(conn); try more(); }
        \\fn shadowed(self: *Pool, items: []*Entry) !void { for (items) |entry| self.kept.appendAssumeCapacity(entry); const entry = try self.gpa.create(Entry); errdefer self.gpa.destroy(entry); try more(); return; }
    , "");
}
