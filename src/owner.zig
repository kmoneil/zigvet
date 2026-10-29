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
//! `return error.X`. It takes it too when it releases `p` itself, or a
//! local copy of it (`var pushed = frame;`), by hand or in a `defer`, with
//! one of those calls or a call whose name says it releases, handed it as
//! its only argument or one after the first (`release(ctx, &pushed)`), and
//! fails after that on its path: a `try`, a `return error.X`, or a
//! `return` of what a `catch` or an `else |err|` caught, as in
//!
//!     fn push(frames: *std.ArrayList(Frame), frame: Frame) !void {
//!         var pushed = frame;
//!         frames.append(gpa, pushed) catch |err| {
//!             release(&pushed);
//!             return err;
//!         };
//!     }
//!
//! Either way it may take a field of `p` instead (`gpa.free(img.pixels)`).
//!
//! A call to it under `try`, or returned as it is (`return f(...)`, which
//! runs the caller's errdefers just as `try` does), is reported when the
//! argument for that parameter, the receiver for a method's first, is a
//! name that an `errdefer` of the caller, declared before the call in a
//! block around it, frees the same way, or carries one: its address
//! (`&list`), a field of an initializer, as deep as they nest
//! (`.{ .state = .{ .items = items } }`), or a local made from one of
//! those that nothing assigns to before the call
//! (`const img: Image = .{ .pixels = pixels };`). For a field the callee
//! takes, the argument has to carry the name in that field. The function
//! has to be the file's own, called by name, through its type
//! (`Store.keep(s, b)`), or as a method of a binding whose type the file
//! declares (`self.keep(b)`).
//!
//! Not reported: a call whose error is handled rather than returned with
//! `try` or `return`, which only the caller can judge; an `errdefer`
//! declared after the call; an argument that is neither a name nor carries
//! one; a field the callee frees of a name the caller's errdefer frees
//! whole (`destroy(frame)` against `frame.list.deinit()`), which is not
//! what the caller frees; a release that leaves the value empty
//! (`clearAndFree`); and one followed, before the failure, by an
//! assignment to what it released.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
const refill = @import("refill.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const twice = @import("twice.zig");
const types = @import("types.zig");
const Types = types.Types;

/// Appends a finding for every call that hands a function an allocation it
/// frees when it fails, from a caller whose own errdefer frees it too.
/// Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    const owners = try ownerNames(arena, tree);
    if (owners.count() == 0) return;
    // The names the file's errdefers free, and the calls under `try` to a
    // function that may free what it is handed whose arguments mention
    // one: the rest is costlier, so only those.
    var freed: std.StringHashMapUnmanaged(void) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"errdefer") continue;
        const deferred = tree.nodeData(@fromBackingInt(@intCast(i))).node;
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, deferred) orelse (&deferred)[0..1];
        for (statements) |statement| {
            _, const operand = refill.releaseCall(tree, statement) orelse continue;
            if (tree.nodeTag(operand) == .identifier) try freed.put(arena, tree.tokenSlice(tree.nodeMainToken(operand)), {});
        }
    }
    if (freed.count() == 0) return;
    // And the locals made from one, which carry it
    // (`const img: Image = .{ .pixels = pixels };`), or from those.
    var grew = true;
    while (grew) {
        grew = false;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            switch (tag) {
                .local_var_decl, .simple_var_decl, .aligned_var_decl => {},
                else => continue,
            }
            const decl = tree.fullVarDecl(@fromBackingInt(@intCast(i))).?;
            const name = tree.tokenSlice(decl.ast.mut_token + 1);
            if (freed.contains(name)) continue;
            const init = decl.ast.init_node.unwrap() orelse continue;
            if (!carries(tree, init) or !mentions(tree, init, freed)) continue;
            try freed.put(arena, name, {});
            grew = true;
        }
    }
    var calls: std.ArrayList(Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .@"try", .@"return" => {},
            else => continue,
        }
        const node: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, operandOf(tree, node) orelse continue) orelse continue;
        const name = switch (tree.nodeTag(call.ast.fn_expr)) {
            .identifier => tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr)),
            .field_access => tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]),
            else => continue,
        };
        if (!owners.contains(name)) continue;
        for (call.ast.params) |param| {
            if (mentions(tree, param, freed)) break;
        } else {
            // A method's receiver is an argument too.
            if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
            if (!mentions(tree, tree.nodeData(call.ast.fn_expr).node_and_token[0], freed)) continue;
        }
        try calls.append(arena, node);
    }
    if (calls.items.len == 0) return;
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings, .types = try .init(arena, tree) };
    for (calls.items) |node| {
        const operand = operandOf(tree, node).?;
        var buffer: [1]Node.Index = undefined;
        try rule.call(node, operand, tree.fullCall(&buffer, operand).?);
    }
}

/// What a `try` tries, or what a `return` returns, through parentheses:
/// an error union returned as it is runs the caller's errdefers just as
/// `try` does.
fn operandOf(tree: *const Ast, node: Node.Index) ?Node.Index {
    var operand = switch (tree.nodeTag(node)) {
        .@"try" => tree.nodeData(node).node,
        .@"return" => tree.nodeData(node).opt_node.unwrap() orelse return null,
        else => return null,
    };
    while (tree.nodeTag(operand) == .grouped_expression) operand = tree.nodeData(operand).node_and_token[0];
    return operand;
}

/// Whether `init`, a local's initializer, is one `Rule.carried` follows:
/// a name, an address, or an initializer.
fn carries(tree: *const Ast, init: Node.Index) bool {
    switch (tree.nodeTag(init)) {
        .identifier, .address_of, .grouped_expression => return true,
        else => {},
    }
    var buffer: [2]Node.Index = undefined;
    return tree.fullStructInit(&buffer, init) != null;
}

/// Whether a token of `node` is a name among `freed`.
fn mentions(tree: *const Ast, node: Node.Index, freed: std.StringHashMapUnmanaged(void)) bool {
    for (tree.firstToken(node)..tree.lastToken(node) + 1) |token| {
        if (tree.tokenTag(@intCast(token)) == .identifier and freed.contains(tree.tokenSlice(@intCast(token)))) return true;
    }
    return false;
}

/// The names of the functions that may free one of their parameters and
/// then fail, found from the tokens before anything costlier is made: a
/// release of a parameter, or of a copy of one, with a `try`, a
/// `return error.X` or a `return` of what a capture caught after it. Most
/// files have functions that free a parameter (every `deinit`); few can
/// fail after it.
fn ownerNames(arena: Allocator, tree: *const Ast) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var functions: std.ArrayList(Function) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const fn_decl: Node.Index = @fromBackingInt(@intCast(i));
        if (!canFail(tree, fn_decl)) continue;
        const body = tree.nodeData(fn_decl).node_and_node[1];
        try functions.append(arena, .{ .node = fn_decl, .first = tree.firstToken(body), .last = tree.lastToken(body) });
    }
    if (functions.items.len == 0) return names;
    std.mem.sort(Function, functions.items, {}, Function.before);
    // Each one's innermost function around it, through a stack of those
    // still open.
    var open: std.ArrayList(usize) = .empty;
    for (functions.items, 0..) |*function, index| {
        while (open.getLastOrNull()) |top| {
            if (functions.items[top].last >= function.first) break;
            _ = open.pop();
        }
        function.outer = open.getLastOrNull();
        try open.append(arena, index);
    }
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .call_one, .call_one_comma, .call, .call_comma => {},
            else => continue,
        }
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const function = innermost(functions.items, tree.nodeMainToken(node)) orelse continue;
        if (function.taken) continue;
        if (function.held == null) function.held = try heldTokens(arena, tree, function.*);
        if (releasesAny(tree, node, function.held.?) == null) continue;
        if (function.caught == null) function.caught = try caughtTokens(arena, tree, function.*);
        if (!failsLater(tree, tree.lastToken(node), function.*)) continue;
        function.taken = true;
        try names.put(arena, fnName(tree, function.node), {});
    }
    return names;
}

/// A function that can fail, by its body's first and last tokens, for
/// `ownerNames`.
const Function = struct {
    node: Node.Index,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    /// The index of the innermost function its body is in, if any.
    outer: ?usize = null,
    /// Its parameters and the copies of them it makes, found at the first
    /// call in it.
    held: ?[]const []const u8 = null,
    /// The names its errors are caught as (`catch |err|`,
    /// `else |err|`), found at the first release in it.
    caught: ?[]const []const u8 = null,
    /// Whether it is known to free one of them and then fail.
    taken: bool = false,

    fn before(_: void, a: Function, b: Function) bool {
        return a.first < b.first;
    }

    fn order(token: Ast.TokenIndex, function: Function) std.math.Order {
        return std.math.order(token, function.first);
    }
};

/// The innermost of `functions`, sorted by where they start, whose body
/// holds `token`.
fn innermost(functions: []Function, token: Ast.TokenIndex) ?*Function {
    const after = std.sort.upperBound(Function, functions, token, Function.order);
    var at: ?usize = if (after == 0) null else after - 1;
    while (at) |index| : (at = functions[index].outer) {
        if (functions[index].last >= token) return &functions[index];
    }
    return null;
}

/// `function`'s parameters, and the locals its body makes as copies of
/// one (`var pushed = frame;`), found from its tokens.
fn heldTokens(arena: Allocator, tree: *const Ast, function: Function) Allocator.Error![]const []const u8 {
    var held: std.ArrayList([]const u8) = .empty;
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function.node).node_and_node[0]).?;
    var params = proto.iterate(tree);
    while (params.next()) |param| try held.append(arena, tree.tokenSlice(param.name_token orelse continue));
    var token = function.first;
    while (token + 4 <= function.last) : (token += 1) {
        switch (tree.tokenTag(token)) {
            .keyword_var, .keyword_const => {},
            else => continue,
        }
        if (tree.tokenTag(token + 1) != .identifier) continue;
        // Past a type, if one is written, to the `=`.
        var equal = token + 2;
        if (tree.tokenTag(equal) == .colon) {
            while (equal < function.last and tree.tokenTag(equal) != .equal and tree.tokenTag(equal) != .semicolon) equal += 1;
        }
        if (tree.tokenTag(equal) != .equal or equal + 2 > function.last) continue;
        if (tree.tokenTag(equal + 1) != .identifier or tree.tokenTag(equal + 2) != .semicolon) continue;
        if (isIn(held.items, tree.tokenSlice(equal + 1))) try held.append(arena, tree.tokenSlice(token + 1));
    }
    return held.items;
}

/// Whether a token of `function` after `from` makes it fail: `try`,
/// `return error.X`, or a `return` of a name a `catch` in it captures.
fn failsLater(tree: *const Ast, from: Ast.TokenIndex, function: Function) bool {
    var token = from + 1;
    while (token < function.last) : (token += 1) {
        switch (tree.tokenTag(token)) {
            .keyword_try => return true,
            .keyword_return => switch (tree.tokenTag(token + 1)) {
                .keyword_error => return true,
                .identifier => if (isIn(function.caught.?, tree.tokenSlice(token + 1))) return true,
                else => {},
            },
            else => {},
        }
    }
    return false;
}

/// The names `function`'s errors are caught as: `name` of `catch |name|`,
/// or of an `if`'s or a `while`'s `else |name|`.
fn caughtTokens(arena: Allocator, tree: *const Ast, function: Function) Allocator.Error![]const []const u8 {
    var caught: std.ArrayList([]const u8) = .empty;
    var token = function.first;
    while (token + 2 <= function.last) : (token += 1) {
        switch (tree.tokenTag(token)) {
            .keyword_catch, .keyword_else => {},
            else => continue,
        }
        if (tree.tokenTag(token + 1) != .pipe) continue;
        try caught.append(arena, tree.tokenSlice(token + 2));
    }
    return caught.items;
}

/// Whether `fn_decl` can return an error: its return type is `E!T` or
/// `!T`.
fn canFail(tree: *const Ast, fn_decl: Node.Index) bool {
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
    const return_type = proto.ast.return_type.unwrap() orelse return false;
    if (tree.nodeTag(return_type) == .error_union) return true;
    return tree.tokenTag(tree.firstToken(return_type) - 1) == .bang;
}

/// Appends to `held` the locals in `nodes` made as a copy of a name it
/// holds (`var pushed = frame;`), or of such a copy, in any order.
fn copies(arena: Allocator, tree: *const Ast, nodes: []const Node.Index, held: *std.ArrayList([]const u8)) Allocator.Error!void {
    var grew = true;
    while (grew) {
        grew = false;
        for (nodes) |node| {
            const decl = tree.fullVarDecl(node) orelse continue;
            const init = decl.ast.init_node.unwrap() orelse continue;
            if (tree.nodeTag(init) != .identifier) continue;
            const copy = tree.tokenSlice(decl.ast.mut_token + 1);
            if (isIn(held.items, copy) or !isIn(held.items, tree.tokenSlice(tree.nodeMainToken(init)))) continue;
            try held.append(arena, copy);
            grew = true;
        }
    }
}

fn isIn(names: []const []const u8, name: []const u8) bool {
    for (names) |held| if (std.mem.eql(u8, held, name)) return true;
    return false;
}

/// What `node` releases, if it is a call that releases one of `names` or a
/// field of one (`img.pixels`): `gpa.free(p)` or `p.deinit()`, or a call
/// whose name says it releases (`release(ctx, &p)`) handed it as its only
/// argument or one after the first, which is most often what it releases
/// into (`releasePages(pool, pages)`). A method's receiver is not taken as
/// released that way: `build_env.freeReports(reports)` frees `reports`.
fn releasesAny(tree: *const Ast, node: Node.Index, names: []const []const u8) ?Node.Index {
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (refill.releaseCall(tree, node)) |found| return if (isHeld(tree, found[1], names)) found[1] else null;
    const params = if (call.ast.params.len > 1) call.ast.params[1..] else call.ast.params;
    const released = for (params) |param| {
        if (isHeld(tree, param, names)) break param;
    } else return null;
    if (!twice.releases(tree, call.ast.fn_expr)) return null;
    // `clearAndFree` and the like leave the value empty, safe to free again.
    const name = switch (tree.nodeTag(call.ast.fn_expr)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr)),
        .field_access => tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]),
        else => return null,
    };
    return if (std.mem.startsWith(u8, name, "clear")) null else released;
}

/// Whether `node` is one of `names`, or a field of one, through `&`, `.*`
/// and parentheses.
fn isHeld(tree: *const Ast, node: Node.Index, names: []const []const u8) bool {
    var n = node;
    while (true) switch (tree.nodeTag(n)) {
        .address_of, .deref => n = tree.nodeData(n).node,
        .grouped_expression, .field_access => n = tree.nodeData(n).node_and_token[0],
        .identifier => break,
        else => return false,
    };
    return isIn(names, tree.tokenSlice(tree.nodeMainToken(n)));
}

/// The fields from the name `node` is reached from to `node`, one
/// `isHeld` took: none for the name itself, `pixels` for `img.pixels`.
fn fieldsTo(arena: Allocator, tree: *const Ast, node: Node.Index) Allocator.Error!Path {
    var fields: std.ArrayList([]const u8) = .empty;
    var n = node;
    while (true) switch (tree.nodeTag(n)) {
        .address_of, .deref => n = tree.nodeData(n).node,
        .grouped_expression => n = tree.nodeData(n).node_and_token[0],
        .field_access => {
            const lhs, const field = tree.nodeData(n).node_and_token;
            try fields.append(arena, tree.tokenSlice(field));
            n = lhs;
        },
        else => break,
    };
    std.mem.reverse([]const u8, fields.items);
    return fields.items;
}

/// Field names, outermost first: what a function releases of a parameter.
const Path = []const []const u8;

/// A parameter a function frees when it fails, by index, and the field of
/// it that it frees, if not the whole of it.
const Taken = struct {
    param: usize,
    path: Path,
};

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),
    types: Types,
    /// What each function frees when it fails, found once per function.
    taken: std.AutoHashMapUnmanaged(Node.Index, []const Taken) = .empty,

    /// Checks `try f(...)` or `return f(...)`, with `operand` the call and
    /// `full` its parts, when `f` is the file's own function and takes a
    /// parameter on failure.
    fn call(r: *Rule, node: Node.Index, operand: Node.Index, full: Ast.full.Call) Allocator.Error!void {
        const tree = r.tree;
        const fn_decl, const receiver = r.types.callee(full.ast.fn_expr) orelse return;
        for (try r.takes(fn_decl)) |taken| {
            // A method's receiver is its first parameter.
            const argument = if (taken.param < receiver)
                tree.nodeData(full.ast.fn_expr).node_and_token[0]
            else if (taken.param - receiver < full.ast.params.len)
                full.ast.params[taken.param - receiver]
            else
                continue;
            const name = r.carried(node, argument, taken.path, 0) orelse continue;
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

    /// The first name `argument` carries, at `path` in it, that an
    /// `errdefer` declared before `node` frees. For the whole of it: the
    /// argument itself, what its address is taken of (`&list`), or a field
    /// of an initializer, as deep as they nest
    /// (`.{ .state = .{ .items = items } }`). For a field: that field of an
    /// initializer. Through a local made from either, too, that nothing
    /// assigns to before `node` (`const img: Image = .{ .pixels = pixels };`).
    fn carried(r: *Rule, node: Node.Index, argument: Node.Index, path: Path, depth: u8) ?[]const u8 {
        const tree = r.tree;
        if (depth > 8) return null;
        switch (tree.nodeTag(argument)) {
            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(argument));
                // Freed whole by the caller, a field of it by the callee:
                // `destroy(frame)` does not free what `frame.list` holds.
                if (r.freedOnError(node, name)) return if (path.len == 0) name else null;
                const init = r.localMade(node, argument) orelse return null;
                return r.carried(node, init, path, depth + 1);
            },
            .address_of => return r.carried(node, tree.nodeData(argument).node, path, depth + 1),
            .grouped_expression => return r.carried(node, tree.nodeData(argument).node_and_token[0], path, depth + 1),
            else => {},
        }
        var buffer: [2]Node.Index = undefined;
        const init = tree.fullStructInit(&buffer, argument) orelse return null;
        for (init.ast.fields) |field| {
            if (path.len == 0) {
                if (r.carried(node, field, path, depth + 1)) |name| return name;
                continue;
            }
            // `.pixels = value`: the field's name is two tokens before it.
            if (!std.mem.eql(u8, tree.tokenSlice(tree.firstToken(field) - 2), path[0])) continue;
            return r.carried(node, field, path[1..], depth + 1);
        }
        return null;
    }

    /// The initializer of the local `use` names, if it is one `carried`
    /// follows and nothing assigns to the local between it and `node`.
    fn localMade(r: *Rule, node: Node.Index, use: Node.Index) ?Node.Index {
        const tree = r.tree;
        const init = r.types.localInit(use) orelse return null;
        if (!carries(tree, init)) return null;
        const decl_node = r.types.parents[@backingInt(init)].unwrap() orelse return null;
        const decl = tree.fullVarDecl(decl_node) orelse return null;
        if (tree.tokenTag(decl.ast.mut_token) == .keyword_const) return init;
        // A `var`: no assignment to it, or to a field of it, in between.
        const name = tree.tokenSlice(decl.ast.mut_token + 1);
        const from = tree.lastToken(decl_node);
        const to = tree.firstToken(node);
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            switch (tag) {
                .assign => {},
                else => continue,
            }
            const assign: Node.Index = @fromBackingInt(@intCast(i));
            const at = tree.nodeMainToken(assign);
            if (at <= from or at >= to) continue;
            const root = kept.rootOf(tree, tree.nodeData(assign).node_and_node[0]) orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(root)), name)) return null;
        }
        return init;
    }

    /// What `fn_decl` frees when it fails: each parameter, or field of
    /// one, that an `errdefer` in its body frees, with something after it
    /// in its block that can fail, or that it releases otherwise, itself
    /// or through a copy, before a failure on its path.
    fn takes(r: *Rule, fn_decl: Node.Index) Allocator.Error![]const Taken {
        if (r.taken.get(fn_decl)) |known| return known;
        const tree = r.tree;
        var found: std.ArrayList(Taken) = .empty;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
        const body = tree.nodeData(fn_decl).node_and_node[1];
        var nodes: std.ArrayList(Node.Index) = .empty;
        try within(r.arena, tree, body, &nodes);
        var params = proto.iterate(tree);
        var index: usize = 0;
        while (params.next()) |param| : (index += 1) {
            const name_token = param.name_token orelse continue;
            try r.takesParam(body, nodes.items, index, tree.tokenSlice(name_token), &found);
        }
        try r.taken.put(r.arena, fn_decl, found.items);
        return found.items;
    }

    /// Appends to `found` what the function whose body is `body`, with
    /// `nodes` in it, frees of its parameter `name`, the `index`th, when
    /// it fails.
    fn takesParam(r: *Rule, body: Node.Index, nodes: []const Node.Index, index: usize, name: []const u8, found: *std.ArrayList(Taken)) Allocator.Error!void {
        const tree = r.tree;
        for (nodes) |node| {
            if (tree.nodeTag(node) != .@"errdefer") continue;
            const deferred = tree.nodeData(node).node;
            var buffer: [2]Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, deferred) orelse (&deferred)[0..1];
            for (statements) |statement| {
                _, const operand = refill.releaseCall(tree, statement) orelse continue;
                if (!isHeld(tree, operand, &.{name}) or !try r.failsAfter(node)) continue;
                try found.append(r.arena, .{ .param = index, .path = try fieldsTo(r.arena, tree, operand) });
            }
        }
        var held: std.ArrayList([]const u8) = .empty;
        try held.append(r.arena, name);
        try copies(r.arena, tree, nodes, &held);
        for (nodes) |node| {
            const released = releasesAny(tree, node, held.items) orelse continue;
            // What the release is handed: a statement after it that assigns
            // to one of them leaves it something else to free.
            var call_buffer: [1]Node.Index = undefined;
            const release = tree.fullCall(&call_buffer, node).?;
            var handed: std.ArrayList(Node.Index) = .empty;
            try handed.appendSlice(r.arena, release.ast.params);
            if (tree.nodeTag(release.ast.fn_expr) == .field_access) try handed.append(r.arena, tree.nodeData(release.ast.fn_expr).node_and_token[0]);
            if (try twice.failsAfter(r.arena, tree, r.types.parents, node, body, handed.items) == null) continue;
            try found.append(r.arena, .{ .param = index, .path = try fieldsTo(r.arena, tree, released) });
        }
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
            try within(r.arena, tree, later, &nodes);
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
};

/// Appends `node` and every node under it, but not what nested functions
/// and types hold.
fn within(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    var pending: std.ArrayList(Node.Index) = .empty;
    try pending.append(arena, node);
    while (pending.pop()) |n| {
        if (kept.isNested(tree.nodeTag(n))) continue;
        try out.append(arena, n);
        try children.append(arena, tree, n, &pending);
    }
}

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
    try expect.findings(@src(), expected, out.written());
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

test "a function that frees what it is handed itself, or a copy of it, before it fails" {
    try expectOwners(
        \\fn release(frame: *Frame) void { gpa.free(frame.items); }
        \\fn push(frames: *List, frame: Frame) !void { var pushed = frame; frames.append(gpa, pushed) catch |err| { release(&pushed); return err; }; }
        \\fn begin(frames: *List, items: []u8) !void { errdefer gpa.free(items); const n = try count(); return try push(frames, .{ .n = n, .state = .{ .items = items } }); }
        \\fn keep(list: *List, bytes: []u8) !void { list.append(gpa, bytes) catch |err| { gpa.free(bytes); return err; }; }
        \\fn save(list: *List, text: []const u8) !void { const bytes = try gpa.dupe(u8, text); errdefer gpa.free(bytes); try keep(list, bytes); }
        \\fn check(gpa: Allocator, bytes: []u8) !void { if (bytes.len == 0) { gpa.free(bytes); return error.Empty; } }
        \\fn load(gpa: Allocator) !void { const bytes = try gpa.alloc(u8, 4); errdefer gpa.free(bytes); try check(gpa, bytes); }
        \\fn consume(gpa: Allocator, list: *List) !void { defer list.deinit(gpa); try flush(list); }
        \\fn run(gpa: Allocator) !void { var list: List = .empty; errdefer list.deinit(gpa); try consume(gpa, &list); }
        \\fn parsed(gpa: Allocator, bytes: []u8) !void { if (parse(bytes)) |_| {} else |err| { gpa.free(bytes); return err; } }
        \\fn read(gpa: Allocator) !void { const bytes = try gpa.alloc(u8, 4); errdefer gpa.free(bytes); try parsed(gpa, bytes); }
    ,
        \\3:106 push items
        \\5:116 keep bytes
        \\7:99 check bytes
        \\9:88 consume list
        \\11:99 parsed bytes
        \\
    );
}

test "not reported: a release that leaves it empty, assigned after, not failed after, or of another parameter" {
    try expectOwners(
        \\fn emptied(gpa: Allocator, list: *List) !void { list.clearAndFree(gpa); try more(); }
        \\fn a(gpa: Allocator) !void { var list: List = .empty; errdefer list.deinit(gpa); try emptied(gpa, &list); }
        \\fn refilled(gpa: Allocator, list: *List) !void { list.deinit(gpa); list.* = .empty; try more(); }
        \\fn b(gpa: Allocator) !void { var list: List = .empty; errdefer list.deinit(gpa); try refilled(gpa, &list); }
        \\fn done(gpa: Allocator, bytes: []u8) !void { try more(); gpa.free(bytes); }
        \\fn c(gpa: Allocator) !void { const bytes = try gpa.alloc(u8, 4); errdefer gpa.free(bytes); try done(gpa, bytes); }
        \\fn plain(gpa: Allocator, bytes: []u8) !void { if (bytes.len == 0) { gpa.free(bytes); return; } try more(); }
        \\fn d(gpa: Allocator) !void { const bytes = try gpa.alloc(u8, 4); errdefer gpa.free(bytes); try plain(gpa, bytes); }
        \\fn other(gpa: Allocator, frame: Frame, spare: []u8) !void { gpa.free(spare); try more(frame); }
        \\fn e(gpa: Allocator, spare: []u8) !void { const items = try gpa.alloc(u8, 4); errdefer gpa.free(items); try other(gpa, .{ .items = items }, spare); }
        \\fn fields(frame: *Frame) !void { errdefer frame.list.deinit(gpa); try more(); }
        \\fn f(gpa: Allocator) !void { const frame = try gpa.create(Frame); errdefer gpa.destroy(frame); try fields(frame); }
        \\fn pooled(pool: *Pool, pages: []u8) !void { errdefer releasePages(pool, pages); try more(); }
        \\fn g(gpa: Allocator) !void { var pool = try Pool.init(gpa); errdefer pool.deinit(); try pooled(&pool, &.{}); }
        \\fn drained(env: *Env, reports: []u8) !void { defer env.freeReports(reports); try more(); }
        \\fn h(gpa: Allocator) !void { var env = try Env.init(gpa); errdefer env.deinit(); try drained(&env, &.{}); }
    , "");
}

test "a call returned as it is, the receiver that carries it, a field the callee frees (#111)" {
    try expectOwners(
        \\const Image = struct {
        \\    pixels: []u8,
        \\    other: []u8,
        \\    fn turned(img: Image, gpa: Allocator) !Image { defer gpa.free(img.pixels); const out = try gpa.alloc(u8, 4); return .{ .pixels = out }; }
        \\    fn drop(img: Image, gpa: Allocator) !void { defer img.deinit(gpa); try more(); }
        \\    fn swap(img: *Image, gpa: Allocator) !void { errdefer gpa.free(img.pixels); try more(); }
        \\};
        \\fn keep(list: *List, bytes: []u8) !void { errdefer gpa.free(bytes); try list.append(gpa, bytes); }
        \\fn eat(gpa: Allocator, frame: Frame) !void { defer gpa.free(frame.state.items); try more(); }
        \\fn a(gpa: Allocator, n: usize) !Image { const pixels = try gpa.alloc(u8, n); errdefer gpa.free(pixels); const img: Image = .{ .pixels = pixels }; return img.turned(gpa); }
        \\fn b(gpa: Allocator, list: *List) !void { const bytes = try gpa.alloc(u8, 4); errdefer gpa.free(bytes); return (keep(list, bytes)); }
        \\fn c(gpa: Allocator) !void { const pixels = try gpa.alloc(u8, 4); errdefer gpa.free(pixels); const img: Image = .{ .pixels = pixels }; try img.drop(gpa); }
        \\fn d(gpa: Allocator) !void { const pixels = try gpa.alloc(u8, 4); errdefer gpa.free(pixels); var img: Image = .{ .pixels = pixels }; try img.swap(gpa); }
        \\fn e(gpa: Allocator) !void { const items = try gpa.alloc(u8, 4); errdefer gpa.free(items); const state = .{ .items = items }; try eat(gpa, .{ .state = state }); }
    ,
        \\10:154 img.turned pixels
        \\11:113 keep bytes
        \\12:140 img.drop pixels
        \\13:138 img.swap pixels
        \\14:131 eat items
        \\
    );
}

test "not reported: another field, a field of what the caller frees whole, a local assigned before, an error handled" {
    try expectOwners(
        \\const Image = struct {
        \\    pixels: []u8,
        \\    other: []u8,
        \\    fn turned(img: Image, gpa: Allocator) !Image { defer gpa.free(img.other); const out = try gpa.alloc(u8, 4); return .{ .pixels = out }; }
        \\    fn swap(img: *Image, gpa: Allocator) !void { errdefer gpa.free(img.pixels); try more(); }
        \\};
        \\fn keep(list: *List, bytes: []u8) !void { errdefer gpa.free(bytes); try list.append(gpa, bytes); }
        \\fn a(gpa: Allocator) !Image { const pixels = try gpa.alloc(u8, 4); errdefer gpa.free(pixels); const img: Image = .{ .pixels = pixels, .other = &.{} }; return img.turned(gpa); }
        \\fn b(gpa: Allocator) !void { const img: *Image = try gpa.create(Image); errdefer gpa.destroy(img); try img.swap(gpa); }
        \\fn c(gpa: Allocator, spare: []u8) !void { const pixels = try gpa.alloc(u8, 4); errdefer gpa.free(pixels); var img: Image = .{ .pixels = pixels }; img.pixels = spare; try img.swap(gpa); }
        \\fn d(gpa: Allocator, spare: []u8) !void { const pixels = try gpa.alloc(u8, 4); errdefer gpa.free(pixels); var img: Image = .{ .pixels = pixels }; img = .{ .pixels = spare }; try img.swap(gpa); }
        \\fn e(gpa: Allocator, list: *List) !void { const bytes = try gpa.alloc(u8, 4); errdefer gpa.free(bytes); return keep(list, bytes) catch |err| log(err); }
        \\fn f(gpa: Allocator, list: *List) !void { const bytes = try gpa.alloc(u8, 4); errdefer gpa.free(bytes); { const img: Image = .{ .pixels = bytes }; _ = img; } return; }
    , "");
}
