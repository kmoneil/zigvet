//! Rule fourteen, grow: a pointer into a list's items, kept across a call
//! that can move them.
//!
//!     const first = &list.items[0];
//!     try list.append(gpa, x);
//!     first.* = 7; // append moved the items when the list was full
//!
//! `append` reallocates when the list has no room, and `first` is left
//! pointing at freed memory. The same holds for `getPtr`, or `getOrPut`'s
//! `value_ptr`, kept across a `put` on the same map, and for a `for` over
//! `list.items` whose body appends to `list`: the loop took the slice once
//! and walks on through the old memory. It compiles clean in every build
//! mode, and it works whenever the list happened to have room, which is
//! most test runs.
//!
//! What points in is a local made with `&x.items[...]`, `x.items` or a
//! slice of it, `x.addOne(...)` and its kind when the file shows `x` is an
//! `ArrayList`, or `x.getPtr(...)`, `x.getOrPut(...)`, `x.getEntry(...)`
//! and their kind when it shows `x` is a hash map, as escape finds types;
//! what an `if` captures from such a `getPtr`; and a `for` over `x.items`
//! or a slice of it. What moves is a call on the same `x`, as written,
//! that can reallocate: `append`, `appendSlice`, `insert`, `addOne`,
//! `resize`, `ensureTotalCapacity` and the rest for a list, `put`,
//! `getOrPut`, `fetchPut`, `ensureTotalCapacity` and the rest for a map.
//! It is reported when, on a path after the call, the local is used, or
//! the `for` goes on to its next turn: later in the same block, after the
//! loop or block a `break` leaves, or on the next turn of a loop around
//! the call that the local was declared outside of, with no `return`,
//! `break` or `continue` that leaves first.
//!
//! Not reported: the `AssumeCapacity` calls, which cannot move anything; a
//! use in another branch of the `if` or another prong of the `switch` the
//! call is in, or after a `continue` to a loop the local is declared in,
//! which takes it again; a pointer taken again before the use; a length,
//! or `found_existing` or `index`, read out of it, which are copies; a
//! `getOrPut` that makes a new entry only on a path that leaves at once,
//! when a `getOrPut` made the pointer and so left a free slot; a list or
//! map handed to a call (`try fill(&list)`), which only the callee can
//! judge; and a type the file does not show, such as `std.SegmentedList`,
//! whose elements never move.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every call that can move what a pointer kept
/// across it points into. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings };
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(node)) {
            .for_simple, .@"for" => try rule.loop(node),
            .if_simple, .@"if" => try rule.captured(node),
            else => {},
        }
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, node) orelse continue;
        for (statements, 0..) |statement, at| {
            const decl = tree.fullVarDecl(statement) orelse continue;
            const init = decl.ast.init_node.unwrap() orelse continue;
            var into = try rule.pointsInto(init) orelse continue;
            // Only when the pointer's own `getOrPut` found its key on the
            // path that goes on: a new entry may take the last free slot.
            if (into.slot_left) into.slot_left = try rule.insertsOnlyToLeave(if (tree.nodeTag(init) == .@"try") tree.nodeData(init).node else init);
            try rule.across(node, statements[at + 1 ..], into, tree.tokenSlice(decl.ast.mut_token + 1));
        }
    }
}

const hint_list = "keep the index and take the pointer again after it, or reserve first with `ensureUnusedCapacity` and grow with an `AssumeCapacity` call, which cannot move anything";
const hint_map = "look it up again after it, or reserve first with `ensureUnusedCapacity` and use `putAssumeCapacity` or `getOrPutAssumeCapacity`, which cannot move anything";
const hint_loop = "walk an index (`while (i < list.items.len)`) so each turn reads the items afresh, or reserve first with `ensureUnusedCapacity` and grow with an `AssumeCapacity` call";

/// What a pointer points into: the list or map, as written.
const Into = struct {
    owner: Node.Index,
    kind: Kind,
    /// Made by a `getOrPut` that found its key, which grows the map first
    /// if it has no free slot and takes none, so one is left after it.
    slot_left: bool = false,
};

const Kind = enum { list, map };

/// What a path after a moving call is watched for: a use of `name`, the
/// pointer, unless it is empty, before the end of `scope`, the block that
/// declares it; or, with `loop`, the next turn of `scope`, a `for` over the
/// items.
const Watch = struct {
    name: []const u8,
    scope: Node.Index,
    loop: bool,
};

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),
    t: ?types.Types = null,

    fn lazyTypes(r: *Rule) Allocator.Error!types.Types {
        if (r.t == null) r.t = try .init(r.arena, r.tree);
        return r.t.?;
    }

    /// The list or map a local's initializer points into: `&x.items[i]`,
    /// `x.items[a..]`, `try x.addOne(gpa)` or `x.getPtr(k)`.
    fn pointsInto(r: *Rule, init: Node.Index) Allocator.Error!?Into {
        const tree = r.tree;
        var n = init;
        while (true) switch (tree.nodeTag(n)) {
            .@"try" => n = tree.nodeData(n).node,
            .grouped_expression, .unwrap_optional => n = tree.nodeData(n).node_and_token[0],
            // `map.getPtr(k) orelse return`.
            .@"orelse" => n = tree.nodeData(n).node_and_node[0],
            else => break,
        };
        switch (tree.nodeTag(n)) {
            .address_of => {
                const operand = tree.nodeData(n).node;
                if (tree.nodeTag(operand) != .array_access) return null;
                const owner = itemsOf(tree, tree.nodeData(operand).node_and_node[0]) orelse return null;
                return .{ .owner = owner, .kind = .list };
            },
            .field_access => return .{ .owner = itemsOf(tree, n) orelse return null, .kind = .list },
            .slice_open, .slice, .slice_sentinel => {
                return .{ .owner = itemsOf(tree, tree.fullSlice(n).?.ast.sliced) orelse return null, .kind = .list };
            },
            else => {},
        }
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, n) orelse return null;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
        const owner, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!isPlace(tree, owner)) return null;
        const name = tree.tokenSlice(method);
        if (in(name, &adds)) {
            if (!try r.declaredAs(owner, &.{ "ArrayList", "array_list" })) return null;
            return .{ .owner = owner, .kind = .list };
        }
        if (in(name, &lookups)) {
            if (!try r.declaredAs(owner, &.{"HashMap"})) return null;
            const grows_first = std.mem.startsWith(u8, name, "getOrPut") and !std.mem.endsWith(u8, name, "AssumeCapacity");
            return .{ .owner = owner, .kind = .map, .slot_left = grows_first };
        }
        return null;
    }

    /// Whether the type the file shows for `place`, written or, for a
    /// local, made by its initializer, has one of `words` in its name.
    fn declaredAs(r: *Rule, place: Node.Index, words: []const []const u8) Allocator.Error!bool {
        const t = try r.lazyTypes();
        const text = if (t.typeOf(place, 0)) |of|
            r.tree.getNodeSource(of)
        else if (r.tree.nodeTag(place) == .identifier)
            r.tree.getNodeSource(localInit(t, place) orelse return false)
        else
            return false;
        // The type's own name, before its arguments: not `List(HashMap(..))`.
        const head = text[0 .. std.mem.findScalar(u8, text, '(') orelse text.len];
        for (words) |word| if (std.mem.find(u8, head, word) != null) return true;
        return false;
    }

    /// A pointer local `name`, declared in `block` before `after`, that
    /// points into `into`: reports the first call among `after` that can
    /// move it with a use of `name` after.
    fn across(r: *Rule, block: Node.Index, after: []const Node.Index, into: Into, name: []const u8) Allocator.Error!void {
        var nodes: std.ArrayList(Node.Index) = .empty;
        for (after) |statement| try within(r.arena, r.tree, statement, &nodes);
        for (nodes.items) |node| {
            if (!r.moves(node, into)) continue;
            if (into.slot_left and try r.insertsOnlyToLeave(node)) continue;
            if (!try r.reached(node, .{ .name = name, .scope = block, .loop = false })) continue;
            return r.add(node, into, name);
        }
    }

    /// Whether `call` is a `getOrPut` whose new entry is made only on a
    /// path that leaves at once: `const g = try map.getOrPut(k);` then
    /// `if (!g.found_existing) { ...; return ...; }`. A key already there
    /// takes no slot, so, with a slot left by the `getOrPut` that made the
    /// pointer, the path that goes on moves nothing. Zig's own LLVM IR
    /// builder names its values this way. Asked of the pointer's own
    /// `getOrPut` as well, whose new entry may take the last free slot.
    fn insertsOnlyToLeave(r: *Rule, call: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        const parents = (try r.lazyTypes()).parents;
        var buffer: [1]Node.Index = undefined;
        const full = tree.fullCall(&buffer, call) orelse return false;
        if (!std.mem.startsWith(u8, tree.tokenSlice(tree.nodeData(full.ast.fn_expr).node_and_token[1]), "getOrPut")) return false;
        var decl = parents[@backingInt(call)].unwrap() orelse return false;
        if (tree.nodeTag(decl) == .@"try") decl = parents[@backingInt(decl)].unwrap() orelse return false;
        const var_decl = tree.fullVarDecl(decl) orelse return false;
        const result = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const block = parents[@backingInt(decl)].unwrap() orelse return false;
        var statements_buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&statements_buffer, block) orelse return false;
        const at = std.mem.findScalar(Node.Index, statements, decl) orelse return false;
        if (at + 1 == statements.len) return false;
        const check_found = tree.fullIf(statements[at + 1]) orelse return false;
        if (check_found.ast.else_expr != .none) return false;
        // `!g.found_existing`.
        const cond = check_found.ast.cond_expr;
        if (tree.nodeTag(cond) != .bool_not) return false;
        const read = tree.nodeData(cond).node;
        if (tree.nodeTag(read) != .field_access) return false;
        const of, const field = tree.nodeData(read).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(field), "found_existing") or !isNamed(tree, of, result)) return false;
        var then_buffer: [2]Node.Index = undefined;
        const then = tree.blockStatements(&then_buffer, check_found.ast.then_expr) orelse (&check_found.ast.then_expr)[0..1];
        if (then.len == 0) return false;
        return switch (tree.nodeTag(then[then.len - 1])) {
            .@"return", .@"break", .@"continue" => true,
            else => false,
        };
    }

    /// `if (map.getPtr(k)) |p| { ... }`: `p` points into the map for the
    /// `if`'s body.
    fn captured(r: *Rule, node: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        const full = tree.fullIf(node).?;
        const payload = full.payload_token orelse return;
        if (tree.tokenTag(payload) != .identifier) return;
        const into = try r.pointsInto(full.ast.cond_expr) orelse return;
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, full.ast.then_expr) orelse return;
        try r.across(full.ast.then_expr, statements, into, tree.tokenSlice(payload));
    }

    /// A `for` over `x.items`: reports the first call in its body that can
    /// move them with a path on to the next turn.
    fn loop(r: *Rule, node: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        const full = tree.fullFor(node).?;
        var capture = full.payload_token;
        for (full.ast.inputs) |input| {
            const by_pointer = tree.tokenTag(capture) == .asterisk;
            const capture_name = tree.tokenSlice(if (by_pointer) capture + 1 else capture);
            capture += if (by_pointer) 3 else 2;
            const sliced = switch (tree.nodeTag(input)) {
                .slice_open, .slice, .slice_sentinel => tree.fullSlice(input).?.ast.sliced,
                else => input,
            };
            const owner = itemsOf(tree, sliced) orelse continue;
            const into: Into = .{ .owner = owner, .kind = .list };
            var nodes: std.ArrayList(Node.Index) = .empty;
            try within(r.arena, tree, full.ast.then_expr, &nodes);
            for (nodes.items) |inner| {
                if (!r.moves(inner, into)) continue;
                // A pointer capture, `|*item|`, is a pointer kept as well.
                const watch: Watch = .{ .name = if (by_pointer) capture_name else "", .scope = node, .loop = true };
                if (!try r.reached(inner, watch)) continue;
                return r.add(inner, into, "");
            }
        }
    }

    /// Whether `node` is a call on `into`'s owner, as written, that can
    /// move what it holds.
    fn moves(r: *Rule, node: Node.Index, into: Into) bool {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse return false;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
        const owner, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, tree.getNodeSource(owner), tree.getNodeSource(into.owner))) return false;
        return in(tree.tokenSlice(method), switch (into.kind) {
            .list => &list_moves,
            .map => &map_moves,
        });
    }

    /// Whether a path from `call`, a call that moves, reaches what `watch`
    /// is watched for before it leaves.
    fn reached(r: *Rule, call: Node.Index, watch: Watch) Allocator.Error!bool {
        const tree = r.tree;
        const parents = (try r.lazyTypes()).parents;
        var child = call;
        var up = parents[@backingInt(call)].unwrap();
        climb: while (up) |parent| : ({
            child = parent;
            up = parents[@backingInt(parent)].unwrap();
        }) {
            // The end of the loop's body: the next turn.
            if (watch.loop and parent == watch.scope) return child == tree.fullFor(parent).?.ast.then_expr;
            if (kept.isNested(tree.nodeTag(parent))) return false;
            switch (tree.nodeTag(parent)) {
                .fn_decl, .test_decl => return false,
                .while_simple, .while_cont, .@"while", .for_simple, .@"for" => {
                    // The next turn of a loop around the call, declared
                    // after the pointer: it may read it again.
                    if (!watch.loop and isBody(tree, parent, child) and uses(tree, parent, watch.name)) return true;
                    continue;
                },
                else => {},
            }
            var buffer: [2]Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, parent) orelse continue;
            const at = std.mem.findScalar(Node.Index, statements, child) orelse return false;
            for (statements[at + 1 ..]) |next| {
                if (assigns(tree, next, watch.name)) return false;
                if (uses(tree, next, watch.name)) return true;
                switch (tree.nodeTag(next)) {
                    .@"return" => return false,
                    .@"break", .@"continue" => {
                        const target = jumpTarget(tree, parents, next) orelse return false;
                        const again = tree.nodeTag(next) == .@"continue";
                        if (watch.loop and target == watch.scope) return again;
                        if (!inside(parents, target, watch.scope)) return false;
                        if (again and !watch.loop and uses(tree, target, watch.name)) return true;
                        // On after the loop or block it leaves.
                        child = target;
                        up = parents[@backingInt(target)].unwrap();
                        continue :climb;
                    },
                    else => {},
                }
            }
            if (!watch.loop and parent == watch.scope) return false;
        }
        return false;
    }

    fn add(r: *Rule, call: Node.Index, into: Into, pointer: []const u8) Allocator.Error!void {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const full = tree.fullCall(&buffer, call).?;
        const owner = tree.getNodeSource(into.owner);
        try r.findings.append(r.arena, .{
            .offset = tree.tokenStart(tree.firstToken(call)),
            .hint = if (pointer.len == 0) hint_loop else switch (into.kind) {
                .list => hint_list,
                .map => hint_map,
            },
            .detail = .{ .grow = .{
                .call = tree.getNodeSource(full.ast.fn_expr),
                .moved = switch (into.kind) {
                    .list => try r.arena.print("`{s}.items`", .{owner}),
                    .map => try r.arena.print("`{s}`'s entries", .{owner}),
                },
                .pointer = pointer,
            } },
        });
    }
};

/// A list's calls that make a pointer into it.
const adds = [_][]const u8{
    "addOne",                       "addManyAsSlice",          "addManyAsArray",
    "addManyAt",                    "addOneAssumeCapacity",    "addManyAsSliceAssumeCapacity",
    "addManyAsArrayAssumeCapacity", "addManyAtAssumeCapacity",
};

/// A hash map's calls that make a pointer into it.
const lookups = [_][]const u8{
    "getPtr",        "getPtrAdapted",    "getPtrContext",          "getOrPut",        "getOrPutAdapted",
    "getOrPutValue", "getOrPutContext",  "getEntry",               "getEntryAdapted", "getEntryContext",
    "getKeyPtr",     "getKeyPtrAdapted", "getOrPutAssumeCapacity",
};

/// A list's calls that can reallocate its items.
const list_moves = [_][]const u8{
    "append",                     "appendSlice",          "appendNTimes", "appendUnalignedSlice",
    "insert",                     "insertSlice",          "addOne",       "addManyAsSlice",
    "addManyAsArray",             "addManyAt",            "resize",       "ensureTotalCapacity",
    "ensureTotalCapacityPrecise", "ensureUnusedCapacity", "replaceRange", "print",
};

/// A hash map's calls that can rehash or reallocate its entries.
const map_moves = [_][]const u8{
    "put",                 "putNoClobber",         "putContext",                 "putNoClobberContext",
    "getOrPut",            "getOrPutAdapted",      "getOrPutContext",            "getOrPutContextAdapted",
    "getOrPutValue",       "getOrPutValueContext", "fetchPut",                   "fetchPutContext",
    "ensureTotalCapacity", "ensureUnusedCapacity", "ensureTotalCapacityContext", "ensureUnusedCapacityContext",
};

fn isNamed(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

fn in(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// `x` of `x.items`, `x` a name or a field of one.
fn itemsOf(tree: *const Ast, node: Node.Index) ?Node.Index {
    if (tree.nodeTag(node) != .field_access) return null;
    const owner, const field = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(field), "items") or !isPlace(tree, owner)) return null;
    return owner;
}

/// Whether `node` is a name or a field of one: `list`, `self.list`.
fn isPlace(tree: *const Ast, node: Node.Index) bool {
    var n = node;
    while (tree.nodeTag(n) == .field_access) n = tree.nodeData(n).node_and_token[0];
    return tree.nodeTag(n) == .identifier;
}

/// The initializer of the local `use` names, when it has one.
fn localInit(t: types.Types, use: Node.Index) ?Node.Index {
    const tree = t.tree;
    const name = tree.tokenSlice(tree.nodeMainToken(use));
    var child = use;
    var up = t.parents[@backingInt(use)].unwrap();
    while (up) |parent| : ({
        child = parent;
        up = t.parents[@backingInt(parent)].unwrap();
    }) {
        if (tree.nodeTag(parent) == .fn_decl) return null;
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, parent) orelse continue;
        for (statements) |statement| {
            if (statement == child) break;
            const decl = tree.fullVarDecl(statement) orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)) return decl.ast.init_node.unwrap();
        }
    }
    return null;
}

/// Whether `child` is the body of `loop`, or its continue expression,
/// both of which run again on the next turn.
fn isBody(tree: *const Ast, loop: Node.Index, child: Node.Index) bool {
    if (tree.fullWhile(loop)) |full| return child == full.ast.then_expr or child == full.ast.cont_expr.unwrap();
    return child == tree.fullFor(loop).?.ast.then_expr;
}

/// Whether `node` reads `name`: as a name, not a field's, and not for a
/// copy read out of it (`.len`, `.found_existing`, `.index`).
fn uses(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    if (name.len == 0) return false;
    const last = tree.lastToken(node);
    var token = tree.firstToken(node);
    while (token <= last) : (token += 1) {
        if (tree.tokenTag(token) != .identifier or !std.mem.eql(u8, tree.tokenSlice(token), name)) continue;
        if (token > 0 and tree.tokenTag(token - 1) == .period) continue;
        if (token + 2 <= last and tree.tokenTag(token + 1) == .period) {
            const field = tree.tokenSlice(token + 2);
            if (in(field, &.{ "len", "found_existing", "index" })) continue;
        }
        return true;
    }
    return false;
}

/// Whether `node` stores a new pointer in `name`.
fn assigns(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    if (name.len == 0 or tree.nodeTag(node) != .assign) return false;
    const target = tree.nodeData(node).node_and_node[0];
    return tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), name);
}

/// The loop a `break` or `continue` leaves or turns again, or the block a
/// labeled `break` leaves. Null for a labeled `continue` of a `switch`.
fn jumpTarget(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) ?Node.Index {
    const label = if (tree.nodeData(node).opt_token_and_opt_node[0].unwrap()) |token| tree.tokenSlice(token) else null;
    var up = parents[@backingInt(node)].unwrap();
    while (up) |parent| : (up = parents[@backingInt(parent)].unwrap()) {
        if (kept.isNested(tree.nodeTag(parent))) return null;
        const loop_label: ?Ast.TokenIndex = if (tree.fullWhile(parent)) |full|
            full.label_token
        else if (tree.fullFor(parent)) |full|
            full.label_token
        else {
            const wanted = label orelse continue;
            var buffer: [2]Node.Index = undefined;
            if (tree.blockStatements(&buffer, parent) == null) continue;
            const lbrace = tree.nodeMainToken(parent);
            if (lbrace >= 2 and tree.tokenTag(lbrace - 1) == .colon and std.mem.eql(u8, tree.tokenSlice(lbrace - 2), wanted)) return parent;
            continue;
        };
        const wanted = label orelse return parent;
        if (loop_label) |token| if (std.mem.eql(u8, tree.tokenSlice(token), wanted)) return parent;
    }
    return null;
}

/// Whether `node` is `scope` or inside it.
fn inside(parents: []const Node.OptionalIndex, node: Node.Index, scope: Node.Index) bool {
    var at: ?Node.Index = node;
    while (at) |n| : (at = parents[@backingInt(n)].unwrap()) {
        if (n == scope) return true;
    }
    return false;
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
/// `line:col call moved pointer`, in source order.
fn expectGrow(source: [:0]const u8, expected: []const u8) !void {
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
        const g = finding.detail.grow;
        try out.writer.print("{d}:{d} {s} {s} {s}\n", .{ loc.line + 1, loc.column + 1, g.call, g.moved, if (g.pointer.len == 0) "(for)" else g.pointer });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a pointer into a list's items kept across a call that can move them (#55)" {
    try expectGrow(
        \\fn first(gpa: Allocator, list: *List) !void { const p = &list.items[0]; try list.append(gpa, 1); p.* = 7; }
        \\fn slice(gpa: Allocator, self: *Self) !u8 { const s = self.list.items[1..]; try self.list.appendSlice(gpa, "ab"); return s[0]; }
        \\fn added(gpa: Allocator) !void { var list: std.ArrayList(u8) = .empty; const slot = try list.addOne(gpa); try list.ensureUnusedCapacity(gpa, 8); slot.* = 1; }
        \\fn looped(gpa: Allocator, list: *List) !void { const p = &list.items[0]; while (more()) { use(p.*); try list.append(gpa, 1); } }
        \\fn walked(gpa: Allocator, list: *List) !void { for (list.items) |x| { if (x == 0) try list.append(gpa, 1); } }
        \\fn pointed(gpa: Allocator, list: *List) !void { for (list.items[1..]) |*x| { try list.append(gpa, 1); x.* = 0; break; } }
        \\fn broke(gpa: Allocator, list: *List) !void { const p = &list.items[0]; blk: { try list.append(gpa, 1); break :blk; } p.* = 1; }
    ,
        \\1:77 list.append `list.items` p
        \\2:81 self.list.appendSlice `self.list.items` s
        \\3:111 list.ensureUnusedCapacity `list.items` slot
        \\4:105 list.append `list.items` p
        \\5:87 list.append `list.items` (for)
        \\6:82 list.append `list.items` (for)
        \\7:84 list.append `list.items` p
        \\
    );
}

test "a pointer into a hash map kept across a call that can rehash it (#55)" {
    try expectGrow(
        \\fn put(gpa: Allocator) !void { var map: std.AutoHashMapUnmanaged(u32, u32) = .empty; const gop = try map.getOrPut(gpa, 1); try map.put(gpa, 2, 2); gop.value_ptr.* = 1; }
        \\fn held(self: *Self) !void { const v = self.map.getPtr(1).?; try self.map.put(2, 2); v.* += 1; }
        \\fn made(gpa: Allocator) !void { var map = std.StringHashMap(u32).init(gpa); const e = map.getEntry("a").?; try map.ensureUnusedCapacity(4); e.value_ptr.* = 1; }
        \\fn caught(self: *Self) !void { if (self.map.getPtr(1)) |v| { try self.map.put(2, 2); v.* += 1; } }
        \\fn looked(map: *std.AutoHashMap(u32, u32), k: u32) !void { const v = map.getPtr(k) orelse return; const next = try map.getOrPut(k + 1); if (!next.found_existing) return; v.* += 1; }
        \\fn inserted(map: *std.AutoHashMap(u32, u32), k: u32) !void { const gop = try map.getOrPut(k); if (!gop.found_existing) gop.value_ptr.* = 0; const next = try map.getOrPut(k + 1); if (!next.found_existing) return; gop.value_ptr.* += 1; }
        \\const Self = struct { map: std.AutoHashMap(u32, u32) };
    ,
        \\1:128 map.put `map`'s entries gop
        \\2:66 self.map.put `self.map`'s entries v
        \\3:112 map.ensureUnusedCapacity `map`'s entries e
        \\4:66 self.map.put `self.map`'s entries v
        \\5:116 map.getOrPut `map`'s entries v
        \\6:158 map.getOrPut `map`'s entries gop
        \\
    );
}

test "not reported: AssumeCapacity, another branch, a continue, taken again, a copy, a type not shown" {
    try expectGrow(
        \\fn assumed(list: *List) void { const p = &list.items[0]; list.appendAssumeCapacity(1); p.* = 7; }
        \\fn branch(gpa: Allocator, list: *List, c: bool) !void { const p = &list.items[0]; if (c) { try list.append(gpa, 1); } else { p.* = 7; } }
        \\fn stack(gpa: Allocator, frames: *List) !void { while (frames.items.len != 0) { const frame = &frames.items[frames.items.len - 1]; if (frame.next < 4) { frame.next += 1; try frames.append(gpa, .{}); continue; } _ = frames.pop(); } }
        \\fn again(gpa: Allocator, list: *List) !void { var p = &list.items[0]; try list.append(gpa, 1); p = &list.items[0]; p.* = 7; }
        \\fn length(gpa: Allocator, list: *List) !usize { const s = list.items; try list.append(gpa, 1); return s.len; }
        \\fn found(gpa: Allocator, map: *std.AutoHashMap(u32, u32)) !bool { const gop = try map.getOrPut(1); try map.put(2, 2); return gop.found_existing; }
        \\fn segmented(gpa: Allocator, seg: *Segmented) !void { const p = try seg.addOne(gpa); try seg.append(gpa, 1); p.* = 7; }
        \\fn other(gpa: Allocator, a: *List, b: *List) !void { const p = &a.items[0]; try b.append(gpa, 1); p.* = 7; }
        \\fn after(gpa: Allocator, list: *List) !void { const p = &list.items[0]; p.* = 7; try list.append(gpa, 1); }
        \\fn exits(gpa: Allocator, list: *List) !void { for (list.items) |x| { if (x == 0) { try list.append(gpa, 1); break; } } }
        \\fn returns(gpa: Allocator, list: *List) !void { for (list.items) |x| { if (x == 0) { try list.append(gpa, 1); return; } } }
        \\fn index(gpa: Allocator, list: *List) !void { var i: usize = 0; while (i < list.items.len) : (i += 1) { if (list.items[i] == 0) try list.append(gpa, 1); } }
        \\fn notlist(gpa: Allocator, pool: *Pool) !void { const p = pool.getPtr(1); try pool.put(2); p.* = 1; }
        \\fn unique(map: *std.AutoHashMap(u32, u32), k: u32) !u32 { const gop = try map.getOrPut(k); if (!gop.found_existing) { gop.value_ptr.* = 0; return k; } while (true) { gop.value_ptr.* += 1; const next = try map.getOrPut(k + gop.value_ptr.*); if (!next.found_existing) { next.value_ptr.* = 0; return k + gop.value_ptr.*; } } }
    , "");
}
