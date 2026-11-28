//! Rule five, refill: a place freed, then given new memory by something
//! that can fail first.
//!
//!     self.gpa.free(self.items);
//!     self.items = try self.gpa.alloc(u32, n);
//!
//! When the `try` fails the store never happens, so `self.items` still
//! holds what was just freed, and the error goes back to a caller that
//! still owns `self`. Its `deinit` frees it again, and anything that reads
//! it first reads freed memory. It compiles clean in every build mode and
//! reads naturally (free the old, make the new), and it goes wrong only
//! when an allocation fails, the path tests seldom take: the debugging
//! allocator says "double free" when a test makes it fail, and a release
//! build corrupts the heap and says nothing.
//!
//! What frees is `x.free(place)`, `x.destroy(place)`,
//! `x.rawFree(place, ...)` or `place.deinit(...)`, or a call to one of the
//! file's own functions that frees the parameter the place is passed to
//! (`self.destroyLocal(self.one)`, where a statement of `destroyLocal` frees
//! `local` or a field of it), as a statement or the body of an `if`, or
//! `if (place) |old| x.free(old)`. It is reported when a later statement
//! of the same block stores to the place, or to what holds it written whole
//! (`history.* = .{ ... }`), and something can fail first: a `try`, or a
//! `catch` or `orelse` that returns (`orelse return error.OutOfMemory`), in
//! the stored value or a statement between.
//!
//! The place is a field or what a pointer points at (`self.items`, `a.*`),
//! which the caller still holds when the function fails; or a local the
//! failing function throws away, a bare one (`name`) or a field of a `var`
//! holding a struct by value (`sample.items[j].line`), when the function's
//! own `defer` frees it on the way out, or its `errdefer` when the failure
//! returns an error (#252): `defer gpa.free(name)`, or
//! `for (sample.items) |s| gpa.free(s.line)` in one, armed before the
//! failure in a block around it.
//!
//! Not reported: a place reset first (`self.items = &.{}`, or any store
//! into it), by an `errdefer` or by the `catch` or `orelse` that handles
//! the failure, or perhaps by a call between that is handed what holds it
//! (`self.clear()`), when nothing has failed before that call; a place
//! released by a method of its own, one of the file's, that stores to what
//! it frees (`r.rgb = null` after the free), so a second `deinit` finds
//! nothing; a local declared empty (`&.{}`, `""` or a dupe of one) and
//! freed before anything fills it, when no loop comes round to the release
//! after the refill; and a local no defer frees again, since nothing reads
//! it after the failure (Zig rejects a `var` that is never changed, and a
//! store to a field changes no pointer), nor one whose defer frees only
//! what holds it (`defer sample.deinit(gpa)` frees the list's buffer, not
//! what its elements hold).

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const twice = @import("twice.zig");
const types = @import("types.zig");
const unlock = @import("unlock.zig");

/// Appends a finding for every place freed and then refilled by something
/// that can fail first. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings };
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, node) orelse continue;
        for (statements, 0..) |statement, at| {
            const freed = try rule.release(statement) orelse continue;
            try rule.after(freed, statements[at + 1 ..]);
        }
    }
}

const hint = "make the new value first (`const new = try ...;`), then free the old one and store the new, so a failure leaves the old value in place";

/// A place named from a variable: `self.items` is `self`, then `items`.
/// `.*` and `.?` along it are left out, as a field access derefs by itself;
/// only whether it ends in `.*` is kept.
const Path = struct {
    root: []const u8,
    /// Field names, and indexes as `[i]`, from the root out.
    parts: []const []const u8,
    /// Whether it ends in `.*`: the memory a pointer points at.
    deref: bool,

    /// Whether `holder` is `place` or a path it is reached through.
    fn reaches(holder: Path, place: Path) bool {
        if (!std.mem.eql(u8, holder.root, place.root) or holder.parts.len > place.parts.len) return false;
        for (holder.parts, place.parts[0..holder.parts.len]) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        return true;
    }

    /// Whether `p` names `place`, an index `[*]`, every element of a loop,
    /// standing for any index.
    fn matches(p: Path, place: Path) bool {
        if (!std.mem.eql(u8, p.root, place.root) or p.deref != place.deref or p.parts.len != place.parts.len) return false;
        for (p.parts, place.parts) |a, b| {
            if (std.mem.eql(u8, a, b)) continue;
            const any = std.mem.eql(u8, a, "[*]") or std.mem.eql(u8, b, "[*]");
            if (!any or a[0] != '[' or b[0] != '[') return false;
        }
        return true;
    }
};

/// What a store to a path does to the place freed.
const Store = enum {
    none,
    /// Gives it a new value: a store to it, or to what holds it, written
    /// whole.
    refill,
    /// A store into it (`self.items.len = 0`), or to the variable it is
    /// reached through, which repoints it.
    other,

    fn of(store: Path, place: Path) Store {
        if (!std.mem.eql(u8, store.root, place.root)) return .none;
        const n = @min(store.parts.len, place.parts.len);
        for (store.parts[0..n], place.parts[0..n]) |a, b| if (!std.mem.eql(u8, a, b)) return .none;
        if (store.parts.len > place.parts.len) return .other;
        if (store.parts.len == place.parts.len) return if (store.deref == place.deref) .refill else .other;
        return if (store.parts.len == 0 and !store.deref) .other else .refill;
    }
};

/// A statement that frees a place.
const Release = struct {
    /// The call that frees it, where the report points.
    call: Node.Index,
    /// The place, as written.
    place: Node.Index,
    path: Path,
};

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),
    /// What the file shows of its types, made for the first place found
    /// refilled or the first call to a function that frees a parameter.
    types: ?types.Types = null,
    /// Every node's parent, made with `types`.
    parents: []const Node.OptionalIndex = &.{},
    /// The names of the file's functions that free one of their
    /// parameters, found at the first call that frees nothing itself.
    freeing: ?std.StringHashMapUnmanaged(void) = null,

    /// The place `statement` frees, as `releaseOf` finds it, alone or as
    /// the body of an `if` with no `else`, or `if (place) |old| x.free(old)`.
    fn release(r: *Rule, statement: Node.Index) Allocator.Error!?Release {
        const t = r.tree;
        const full = t.fullIf(statement) orelse {
            const call, const operand = try r.releaseOf(statement) orelse return null;
            return r.placed(call, operand);
        };
        if (full.ast.else_expr != .none) return null;
        var body = full.ast.then_expr;
        var buffer: [2]Node.Index = undefined;
        if (t.blockStatements(&buffer, body)) |statements| {
            if (statements.len != 1) return null;
            body = statements[0];
        }
        const call, const operand = try r.releaseOf(body) orelse return null;
        const token = full.payload_token orelse return r.placed(call, operand);
        // `if (place) |old| x.free(old)` frees the place.
        const name = if (t.tokenTag(token) == .asterisk) token + 1 else token;
        if (t.nodeTag(operand) != .identifier) return null;
        if (!std.mem.eql(u8, t.tokenSlice(t.nodeMainToken(operand)), t.tokenSlice(name))) return null;
        return r.placed(call, full.ast.cond_expr);
    }

    /// `releaseCall`, or a call to one of the file's own functions that
    /// frees the parameter its argument is passed to: the call and the
    /// argument.
    fn releaseOf(r: *Rule, node: Node.Index) Allocator.Error!?struct { Node.Index, Node.Index } {
        const t = r.tree;
        if (releaseCall(t, node)) |found| return .{ found[0], found[1] };
        var buffer: [1]Node.Index = undefined;
        const call = t.fullCall(&buffer, node) orelse return null;
        if (call.ast.params.len == 0) return null;
        const name = switch (t.nodeTag(call.ast.fn_expr)) {
            .identifier => t.tokenSlice(t.nodeMainToken(call.ast.fn_expr)),
            .field_access => t.tokenSlice(t.nodeData(call.ast.fn_expr).node_and_token[1]),
            else => return null,
        };
        if (r.freeing == null) r.freeing = try freeingNames(r.arena, t);
        if (!r.freeing.?.contains(name)) return null;
        const fn_decl, const receiver = (try r.typesOf()).callee(call.ast.fn_expr) orelse return null;
        for (try freedParams(r.arena, t, fn_decl)) |param| {
            // A method's receiver is its first parameter.
            if (param < receiver) continue;
            const at = param - receiver;
            if (at < call.ast.params.len) return .{ node, call.ast.params[at] };
        }
        return null;
    }

    /// What the file shows of its types, and every node's parent, made
    /// once.
    fn typesOf(r: *Rule) Allocator.Error!types.Types {
        if (r.types == null) {
            r.types = try .init(r.arena, r.tree);
            r.parents = r.types.?.parents;
        }
        return r.types.?;
    }

    /// A release of `place` by `call`, if `place` is named from a variable.
    fn placed(r: *Rule, call: Node.Index, place: Node.Index) Allocator.Error!?Release {
        const p = try r.path(place) orelse return null;
        return .{ .call = call, .place = place, .path = p };
    }

    /// Reports `freed` if one of `rest`, the statements after it in its
    /// block, refills it and something can fail before the store.
    fn after(r: *Rule, freed: Release, rest: []const Node.Index) Allocator.Error!void {
        const t = r.tree;
        // The first thing that can fail in a statement between.
        var fails: ?Node.Index = null;
        for (rest, 0..) |statement, i| {
            var nodes: std.ArrayList(Node.Index) = .empty;
            try r.within(statement, &nodes);
            var refill: ?Node.Index = null;
            var other = false;
            for (nodes.items) |node| {
                if (t.nodeTag(node) != .assign) continue;
                const store = try r.path(t.nodeData(node).node_and_node[0]) orelse continue;
                switch (Store.of(store, freed.path)) {
                    .none => {},
                    .refill => refill = node,
                    .other => other = true,
                }
            }
            if (refill) |store| {
                const end = t.lastToken(store);
                const point = fails orelse try r.failing(nodes.items, end, freed.path) orelse return;
                if (try r.excused(freed, point, rest[i + 1 ..])) return;
                return r.findings.append(r.arena, .{
                    .offset = t.tokenStart(t.firstToken(freed.call)),
                    .hint = hint,
                    .detail = .{ .refill = .{
                        .place = t.getNodeSource(freed.place),
                        .fails = what(t, point),
                    } },
                });
            }
            if (other) return;
            // A call that could reset the place excuses only what fails
            // after it: what fails before it leaves the place holding what
            // was freed.
            if (fails == null) {
                if (try r.handsOver(nodes.items, freed.path)) return;
                fails = try r.failing(nodes.items, std.math.maxInt(Ast.TokenIndex), freed.path);
            }
        }
    }

    /// Whether an `errdefer` armed before `point`, in the function around
    /// `freed`, stores to the place or hands over what holds it.
    fn resetOnError(r: *Rule, freed: Release, point: Node.Index) Allocator.Error!bool {
        const t = r.tree;
        var function = freed.call;
        while (r.parents[@backingInt(function)].unwrap()) |parent| {
            function = parent;
            if (t.nodeTag(function) == .fn_decl or t.nodeTag(function) == .test_decl) break;
        }
        const body = switch (t.nodeTag(function)) {
            .fn_decl => t.nodeData(function).node_and_node[1],
            .test_decl => t.nodeData(function).opt_token_and_node[1],
            else => function,
        };
        var nodes: std.ArrayList(Node.Index) = .empty;
        try r.within(body, &nodes);
        for (nodes.items) |node| {
            if (t.nodeTag(node) != .@"errdefer" or t.nodeMainToken(node) > t.nodeMainToken(point)) continue;
            var deferred: std.ArrayList(Node.Index) = .empty;
            try r.within(t.nodeData(node).node, &deferred);
            for (deferred.items) |d| {
                if (t.nodeTag(d) != .assign) continue;
                const store = try r.path(t.nodeData(d).node_and_node[0]) orelse continue;
                if (Store.of(store, freed.path) == .refill) return true;
            }
            if (try r.handsOver(deferred.items, freed.path)) return true;
        }
        return false;
    }

    /// Whether, when the function fails at `point`, the place holds nothing
    /// freed or nothing reads it: the release stores to what it frees or
    /// frees nothing, an `errdefer` resets it, or it is a local thrown
    /// away. `later` is what follows the refill in its block.
    fn excused(r: *Rule, freed: Release, point: Node.Index, later: []const Node.Index) Allocator.Error!bool {
        _ = try r.typesOf();
        if (try r.resets(freed) or try r.emptyWhenFreed(freed, later)) return true;
        return try r.resetOnError(freed, point) or try r.thrownAway(freed, point);
    }

    /// Whether the place, a bare local, can hold only the empty slice it is
    /// declared with when it is freed, so the release frees nothing: it is
    /// declared `&.{}`, `""` or a dupe of one, nothing stores to it before
    /// the release, and no loop between them comes round to the release
    /// after the refill (the refill is followed by a `break` or `return`).
    /// `later` is what follows the refill in its block.
    fn emptyWhenFreed(r: *Rule, freed: Release, later: []const Node.Index) Allocator.Error!bool {
        const t = r.tree;
        if (freed.path.parts.len != 0 or freed.path.deref) return false;
        const local = r.declaration(freed.call, freed.path.root) orelse return false;
        const init = local.decl.ast.init_node.unwrap() orelse return false;
        if (!knownEmpty(t, init)) return false;
        if (local.looped and (later.len == 0 or !leaves(t, later[0]))) return false;
        return !try r.touched(local.block, freed.path.root, t.lastToken(init), t.firstToken(freed.call));
    }

    /// The declaration of the local `name` that `node` sees, the block that
    /// holds it, and whether a loop lies between the two.
    fn declaration(r: *Rule, node: Node.Index, name: []const u8) ?struct { decl: Ast.full.VarDecl, block: Node.Index, looped: bool } {
        const t = r.tree;
        var looped = false;
        var child = node;
        var up = r.parents[@backingInt(node)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = r.parents[@backingInt(parent)].unwrap();
        }) {
            switch (t.nodeTag(parent)) {
                .fn_decl, .test_decl => return null,
                .for_simple, .@"for", .while_simple, .while_cont, .@"while" => looped = true,
                else => {},
            }
            var buffer: [2]Node.Index = undefined;
            const statements = t.blockStatements(&buffer, parent) orelse continue;
            const at = std.mem.indexOfScalar(Node.Index, statements, child) orelse continue;
            const decl = localIn(t, statements[0..at], name) orelse continue;
            return .{ .decl = decl, .block = parent, .looped = looped };
        }
        return null;
    }

    /// Whether something in `block` between tokens `from` and `to` stores
    /// to the local `name` or hands its address on.
    fn touched(r: *Rule, block: Node.Index, name: []const u8, from: Ast.TokenIndex, to: Ast.TokenIndex) Allocator.Error!bool {
        const t = r.tree;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try r.within(block, &nodes);
        for (nodes.items) |node| {
            const target = switch (t.nodeTag(node)) {
                .assign => t.nodeData(node).node_and_node[0],
                .address_of => t.nodeData(node).node,
                else => continue,
            };
            const main = t.nodeMainToken(node);
            if (main <= from or main >= to) continue;
            const store = try r.path(target) orelse continue;
            if (std.mem.eql(u8, store.root, name)) return true;
        }
        return false;
    }

    /// Whether the release is the place's own method, one of the file's,
    /// that stores to what it frees, as `twice.clears` reads one
    /// (`r.rgb = null` after `gpa.free(p)`), so the place holds nothing
    /// freed after it. What `x.free(place)` stores to is `x`'s.
    fn resets(r: *Rule, freed: Release) Allocator.Error!bool {
        const t = r.tree;
        var buffer: [1]Node.Index = undefined;
        const call = t.fullCall(&buffer, freed.call) orelse return false;
        if (t.nodeTag(call.ast.fn_expr) != .field_access) return false;
        if (t.nodeData(call.ast.fn_expr).node_and_token[0] != freed.place) return false;
        const fn_decl, _ = (try r.typesOf()).callee(call.ast.fn_expr) orelse return false;
        return twice.clears(t, fn_decl);
    }

    /// Whether the place is a local the function throws away when it fails
    /// at `point`, a bare one or a field of a `var` held by value, that no
    /// defer of its own frees again on the way out.
    fn thrownAway(r: *Rule, freed: Release, point: Node.Index) Allocator.Error!bool {
        const bare = freed.path.parts.len == 0 and !freed.path.deref;
        if (!bare and !r.heldByValue(freed.call, freed.path.root)) return false;
        return !try r.freedOnExit(freed, point);
    }

    /// Whether a `defer` armed before `point` in a block around it frees
    /// the place on the way out, or an `errdefer` does when the failure at
    /// `point` returns an error: the place as written, or reached through
    /// a capture of a loop or an `if` in it (`for (list.items) |s|
    /// gpa.free(s.line)` frees `list.items[j].line`).
    fn freedOnExit(r: *Rule, freed: Release, point: Node.Index) Allocator.Error!bool {
        const t = r.tree;
        const errors = try r.failsWithError(point);
        var child = point;
        var up = r.parents[@backingInt(point)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = r.parents[@backingInt(parent)].unwrap();
        }) {
            if (t.nodeTag(parent) == .fn_decl or t.nodeTag(parent) == .test_decl) return false;
            var buffer: [2]Node.Index = undefined;
            const statements = t.blockStatements(&buffer, parent) orelse continue;
            // One after `child` is armed only after the failure.
            const at = std.mem.indexOfScalar(Node.Index, statements, child) orelse continue;
            for (statements[0..at]) |statement| {
                switch (t.nodeTag(statement)) {
                    .@"defer" => {},
                    .@"errdefer" => if (!errors) continue,
                    else => continue,
                }
                if (try r.frees(t.nodeData(statement).node, freed.path)) return true;
            }
        }
        return false;
    }

    /// Whether what fails at `point` returns an error, so the function's
    /// `errdefer`s run: a `try`, or a `catch` or `orelse` whose handler
    /// returns one.
    fn failsWithError(r: *Rule, point: Node.Index) Allocator.Error!bool {
        const t = r.tree;
        if (t.nodeTag(point) == .@"try") return true;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try r.within(t.nodeData(point).node_and_node[1], &nodes);
        for (nodes.items) |node| {
            if (t.nodeTag(node) == .@"return" and unlock.returnsError(t, r.parents, node)) return true;
        }
        return false;
    }

    /// Whether `body`, what a `defer` runs, releases `place`, as
    /// `releaseOf` finds a release.
    fn frees(r: *Rule, body: Node.Index, place: Path) Allocator.Error!bool {
        var nodes: std.ArrayList(Node.Index) = .empty;
        try r.within(body, &nodes);
        for (nodes.items) |node| {
            _, const operand = try r.releaseOf(node) orelse continue;
            const p = try r.path(operand) orelse continue;
            const released = try r.uncaptured(operand, p, body) orelse continue;
            if (released.matches(place)) return true;
        }
        return false;
    }

    /// `p`, the path of `node`, with a root captured between `node` and
    /// `top` written as what was captured: `s.line` of
    /// `for (list.items) |s|` is `list.items[*].line`, and `n` of
    /// `if (name) |n|` is `name`. Null when the capture is of something
    /// that is not a path.
    fn uncaptured(r: *Rule, node: Node.Index, p: Path, top: Node.Index) Allocator.Error!?Path {
        const t = r.tree;
        var out = p;
        var child = node;
        while (child != top) {
            const parent = r.parents[@backingInt(child)].unwrap() orelse break;
            defer child = parent;
            const captured = capturedBy(t, parent, child, out.root) orelse continue;
            // A capture by pointer names what it points at only through
            // `.*` or a field.
            if (out.parts.len == 0 and out.deref != captured.by_pointer) return null;
            var sliced = captured.input orelse return null;
            if (t.fullSlice(sliced)) |slice| sliced = slice.ast.sliced;
            const held = try r.path(sliced) orelse return null;
            const element = captured.element;
            const deref = if (out.parts.len > 0) out.deref else if (element) false else held.deref;
            var parts: std.ArrayList([]const u8) = .empty;
            try parts.appendSlice(r.arena, held.parts);
            if (element) try parts.append(r.arena, "[*]");
            try parts.appendSlice(r.arena, out.parts);
            out = .{ .root = held.root, .parts = parts.items, .deref = deref };
        }
        return out;
    }

    /// Whether one of `nodes` is a call that could reset `place`: a method
    /// called on it or on what holds it (`self.clear()`), or a call handed
    /// what holds it or the address of it.
    fn handsOver(r: *Rule, nodes: []const Node.Index, place: Path) Allocator.Error!bool {
        const t = r.tree;
        for (nodes) |node| {
            var buffer: [1]Node.Index = undefined;
            const call = t.fullCall(&buffer, node) orelse continue;
            if (t.nodeTag(call.ast.fn_expr) == .field_access) {
                if (try r.path(t.nodeData(call.ast.fn_expr).node_and_token[0])) |receiver| {
                    if (receiver.reaches(place)) return true;
                }
            }
            for (call.ast.params) |param| {
                if (t.nodeTag(param) == .address_of) {
                    const p = try r.path(t.nodeData(param).node) orelse continue;
                    if (p.reaches(place) or Store.of(p, place) != .none) return true;
                } else if (try r.path(param)) |p| {
                    if (p.parts.len < place.parts.len and p.reaches(place)) return true;
                }
            }
        }
        return false;
    }

    /// Whether `root`, as seen from `node`, is a `var` local holding a
    /// value rather than a pointer: neither declared as one nor made from
    /// an address.
    fn heldByValue(r: *Rule, node: Node.Index, root: []const u8) bool {
        const t = r.tree;
        var child = node;
        var up = r.parents[@backingInt(node)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = r.parents[@backingInt(parent)].unwrap();
        }) {
            if (t.nodeTag(parent) == .fn_decl or t.nodeTag(parent) == .test_decl) return false;
            var buffer: [2]Node.Index = undefined;
            const statements = t.blockStatements(&buffer, parent) orelse continue;
            for (statements) |statement| {
                if (statement == child) break;
                const decl = t.fullVarDecl(statement) orelse continue;
                if (!std.mem.eql(u8, t.tokenSlice(decl.ast.mut_token + 1), root)) continue;
                if (t.tokenTag(decl.ast.mut_token) != .keyword_var) return false;
                if (decl.ast.type_node.unwrap()) |type_node| {
                    if (t.fullPtrType(type_node) != null) return false;
                }
                if (decl.ast.init_node.unwrap()) |init| {
                    if (t.nodeTag(init) == .address_of) return false;
                }
                return true;
            }
        }
        return false;
    }

    /// The first of `nodes`, before token `end`, that can make the function
    /// fail while `place` still holds what was freed: a `try`, or a `catch`
    /// or `orelse` whose handler returns without storing to the place first
    /// (`catch |err| { place = null; return err; }` leaves nothing freed).
    fn failing(r: *Rule, nodes: []const Node.Index, end: Ast.TokenIndex, place: Path) Allocator.Error!?Node.Index {
        const t = r.tree;
        var first: ?Node.Index = null;
        for (nodes) |node| {
            if (t.nodeMainToken(node) >= end) continue;
            const fails = switch (t.nodeTag(node)) {
                .@"try" => true,
                .@"catch", .@"orelse" => fails: {
                    const handler = t.nodeData(node).node_and_node[1];
                    if (!returns(t, handler)) break :fails false;
                    var handled: std.ArrayList(Node.Index) = .empty;
                    try r.within(handler, &handled);
                    for (handled.items) |h| {
                        if (t.nodeTag(h) != .assign) continue;
                        const store = try r.path(t.nodeData(h).node_and_node[0]) orelse continue;
                        if (Store.of(store, place) == .refill) break :fails false;
                    }
                    break :fails true;
                },
                else => false,
            };
            if (!fails) continue;
            if (first == null or t.nodeMainToken(node) < t.nodeMainToken(first.?)) first = node;
        }
        return first;
    }

    /// Appends `node` and every node under it, but not what nested
    /// functions and types hold.
    fn within(r: *Rule, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
        const t = r.tree;
        switch (t.nodeTag(node)) {
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
        try children.append(r.arena, t, node, &nodes);
        for (nodes.items) |child| try r.within(child, out);
    }

    /// `node` as a place named from a variable, or null if it is not one.
    fn path(r: *Rule, node: Node.Index) Allocator.Error!?Path {
        const t = r.tree;
        var parts: std.ArrayList([]const u8) = .empty;
        // Set by the outermost access: whether the path ends in `.*`.
        var deref: ?bool = null;
        var n = node;
        while (true) switch (t.nodeTag(n)) {
            .identifier => break,
            .field_access => {
                const lhs, const field = t.nodeData(n).node_and_token;
                try parts.append(r.arena, t.tokenSlice(field));
                deref = deref orelse false;
                n = lhs;
            },
            .array_access => {
                const lhs, const index = t.nodeData(n).node_and_node;
                try parts.append(r.arena, try r.arena.print("[{s}]", .{t.getNodeSource(index)}));
                deref = deref orelse false;
                n = lhs;
            },
            .unwrap_optional, .grouped_expression => n = t.nodeData(n).node_and_token[0],
            .deref => {
                deref = deref orelse true;
                n = t.nodeData(n).node;
            },
            else => return null,
        };
        std.mem.reverse([]const u8, parts.items);
        return .{ .root = t.tokenSlice(t.nodeMainToken(n)), .parts = parts.items, .deref = deref orelse false };
    }
};

/// `x.free(operand)`, `x.destroy(operand)` or `x.rawFree(operand, ...)`, or
/// `operand.deinit(...)`: the call and what it frees.
pub fn releaseCall(t: *const Ast, node: Node.Index) ?struct { Node.Index, Node.Index } {
    var buffer: [1]Node.Index = undefined;
    const call = t.fullCall(&buffer, node) orelse return null;
    if (t.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver, const name_token = t.nodeData(call.ast.fn_expr).node_and_token;
    const name = t.tokenSlice(name_token);
    if (std.mem.eql(u8, name, "deinit")) return .{ node, receiver };
    // `rawFree(memory, alignment, return_address)`, an allocator's own.
    if (std.mem.eql(u8, name, "rawFree") and call.ast.params.len == 3) return .{ node, call.ast.params[0] };
    if (call.ast.params.len != 1) return null;
    if (std.mem.eql(u8, name, "free") or std.mem.eql(u8, name, "destroy")) return .{ node, call.ast.params[0] };
    return null;
}

/// The names of the file's functions that free one of their parameters, as
/// `freedParams` finds them.
fn freeingNames(arena: Allocator, t: *const Ast) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (t.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const fn_decl: Node.Index = @fromBackingInt(@intCast(i));
        if ((try freedParams(arena, t, fn_decl)).len == 0) continue;
        var buffer: [1]Node.Index = undefined;
        const proto = t.fullFnProto(&buffer, t.nodeData(fn_decl).node_and_node[0]).?;
        try names.put(arena, t.tokenSlice(proto.name_token orelse continue), {});
    }
    return names;
}

/// The parameters `fn_decl` frees, by index: each one a statement of its
/// body releases, or a field of it, alone or as the body of an `if` with no
/// `else` (`self.gpa.free(local.bytes)` frees `local`).
fn freedParams(arena: Allocator, t: *const Ast, fn_decl: Node.Index) Allocator.Error![]const usize {
    var buffer: [1]Node.Index = undefined;
    const proto = t.fullFnProto(&buffer, t.nodeData(fn_decl).node_and_node[0]).?;
    var block: [2]Node.Index = undefined;
    const statements = t.blockStatements(&block, t.nodeData(fn_decl).node_and_node[1]) orelse return &.{};
    var found: std.ArrayList(usize) = .empty;
    var params = proto.iterate(t);
    var index: usize = 0;
    while (params.next()) |param| : (index += 1) {
        const name = t.tokenSlice(param.name_token orelse continue);
        for (statements) |statement| {
            var body = statement;
            if (t.fullIf(statement)) |full| {
                if (full.ast.else_expr != .none or full.payload_token != null) continue;
                body = full.ast.then_expr;
                var inner: [2]Node.Index = undefined;
                if (t.blockStatements(&inner, body)) |one| {
                    if (one.len != 1) continue;
                    body = one[0];
                }
            }
            _, const operand = releaseCall(t, body) orelse continue;
            if (std.mem.eql(u8, rootName(t, operand) orelse continue, name)) {
                try found.append(arena, index);
                break;
            }
        }
    }
    return found.items;
}

/// The variable `node` is reached from: `local` of `local.bytes` or
/// `local.*`.
fn rootName(t: *const Ast, node: Node.Index) ?[]const u8 {
    var n = node;
    while (true) switch (t.nodeTag(n)) {
        .identifier => return t.tokenSlice(t.nodeMainToken(n)),
        .field_access, .unwrap_optional, .grouped_expression => n = t.nodeData(n).node_and_token[0],
        .array_access => n = t.nodeData(n).node_and_node[0],
        .deref => n = t.nodeData(n).node,
        else => return null,
    };
}

/// The last of `statements` that declares `name`.
fn localIn(t: *const Ast, statements: []const Node.Index, name: []const u8) ?Ast.full.VarDecl {
    var found: ?Ast.full.VarDecl = null;
    for (statements) |statement| {
        const decl = t.fullVarDecl(statement) orelse continue;
        if (std.mem.eql(u8, t.tokenSlice(decl.ast.mut_token + 1), name)) found = decl;
    }
    return found;
}

/// Whether `node` is a slice known to be empty, which a free of frees
/// nothing: `&.{}`, `""`, or `x.dupe(T, ...)` of one, with or without a
/// `try`. A dupe of nothing allocates nothing (`Allocator.alloc` of 0
/// bytes returns without calling the allocator); a `dupeZ` allocates its
/// sentinel.
pub fn knownEmpty(t: *const Ast, node: Node.Index) bool {
    var n = node;
    if (t.nodeTag(n) == .@"try") n = t.nodeData(n).node;
    if (emptyLiteral(t, n)) return true;
    var buffer: [1]Node.Index = undefined;
    const call = t.fullCall(&buffer, n) orelse return false;
    if (t.nodeTag(call.ast.fn_expr) != .field_access or call.ast.params.len != 2) return false;
    if (!std.mem.eql(u8, t.tokenSlice(t.nodeData(call.ast.fn_expr).node_and_token[1]), "dupe")) return false;
    return emptyLiteral(t, call.ast.params[1]);
}

fn emptyLiteral(t: *const Ast, node: Node.Index) bool {
    const text = t.getNodeSource(node);
    return std.mem.eql(u8, text, "&.{}") or std.mem.eql(u8, text, "\"\"");
}

/// Whether `node` is a `break` or a `return`, after which the block's
/// loop does not come round again.
fn leaves(t: *const Ast, node: Node.Index) bool {
    return t.nodeTag(node) == .@"break" or t.nodeTag(node) == .@"return";
}

/// One of the names a `for` or an `if` captures.
const Capture = struct {
    /// Its place in the list, from 0.
    at: usize,
    /// Whether it is written `*name`.
    by_pointer: bool,
};

/// `name` as `node`, a `for` or an `if` with `child` its body, captures it.
const Captured = struct {
    by_pointer: bool,
    /// What is captured: the loop's input or the `if`'s condition. Null
    /// for a capture past the loop's inputs.
    input: ?Node.Index,
    /// Whether the capture is an element of it.
    element: bool,
};

/// How `node`, with `child` its body, captures `name`, if it does.
fn capturedBy(t: *const Ast, node: Node.Index, child: Node.Index, name: []const u8) ?Captured {
    switch (t.nodeTag(node)) {
        .for_simple, .@"for" => {
            const full = t.fullFor(node).?;
            if (child != full.ast.then_expr) return null;
            const c = capture(t, full.payload_token, name) orelse return null;
            const input = if (c.at < full.ast.inputs.len) full.ast.inputs[c.at] else null;
            return .{ .by_pointer = c.by_pointer, .input = input, .element = true };
        },
        .if_simple, .@"if" => {
            const full = t.fullIf(node).?;
            if (child != full.ast.then_expr) return null;
            const c = capture(t, full.payload_token orelse return null, name) orelse return null;
            if (c.at != 0) return null;
            return .{ .by_pointer = c.by_pointer, .input = full.ast.cond_expr, .element = false };
        },
        else => return null,
    }
}

/// `name` among the captures starting at token `first`, by value or by
/// pointer.
fn capture(t: *const Ast, first: Ast.TokenIndex, name: []const u8) ?Capture {
    var token = first;
    var at: usize = 0;
    while (true) : (at += 1) {
        const by_pointer = t.tokenTag(token) == .asterisk;
        if (by_pointer) token += 1;
        if (t.tokenTag(token) != .identifier) return null;
        if (std.mem.eql(u8, t.tokenSlice(token), name)) return .{ .at = at, .by_pointer = by_pointer };
        token += 1;
        if (t.tokenTag(token) != .comma) return null;
        token += 1;
    }
}

/// Whether `node` is or holds a `return`.
fn returns(t: *const Ast, node: Node.Index) bool {
    if (t.nodeTag(node) == .@"return") return true;
    const first = t.firstToken(node);
    const last = t.lastToken(node);
    for (first..last + 1) |token| {
        if (t.tokenTag(@intCast(token)) == .keyword_return) return true;
    }
    return false;
}

/// What fails at `point`, as written: the function a `try`, `catch` or
/// `orelse` calls, or the expression.
fn what(t: *const Ast, point: Node.Index) []const u8 {
    var operand = switch (t.nodeTag(point)) {
        .@"try" => t.nodeData(point).node,
        else => t.nodeData(point).node_and_node[0],
    };
    while (t.nodeTag(operand) == .grouped_expression) operand = t.nodeData(operand).node_and_token[0];
    var buffer: [1]Node.Index = undefined;
    if (t.fullCall(&buffer, operand)) |call| return t.getNodeSource(call.ast.fn_expr);
    return t.getNodeSource(operand);
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col place <- what fails`, in source order.
fn expectRefills(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var t = try Ast.parse(gpa, source, .{});
    defer t.deinit(gpa);
    try std.testing.expectEqual(0, t.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var findings: std.ArrayList(Finding) = .empty;
    try check(arena_state.allocator(), &t, &findings);
    std.mem.sort(Finding, findings.items, {}, struct {
        fn before(_: void, a: Finding, b: Finding) bool {
            return a.offset < b.offset;
        }
    }.before);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (findings.items) |finding| {
        const loc = report.location(source, finding.offset);
        const f = finding.detail.refill;
        try out.writer.print("{d}:{d} {s} <- {s}\n", .{ loc.line + 1, loc.column + 1, f.place, f.fails });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a place freed, then refilled by something that can fail first (#39)" {
    try expectRefills(
        \\fn resize(self: *Rows, n: usize) !void { self.gpa.free(self.items); self.items = try self.gpa.alloc(u32, n); }
        \\fn whole(gpa: Allocator, history: *History, n: usize) !void { gpa.free(history.ends); history.* = .{ .name = "", .ends = try gpa.alloc(i64, n) }; }
        \\fn guarded(gpa: Allocator, b: *Browser, kept: *List) !void { if (b.visible.len > 0) gpa.free(b.visible); b.visible = try kept.toOwnedSlice(gpa); }
        \\fn captured(self: *Cache, path: []const u16) ![:0]u16 { if (self.line) |v| self.allocator.free(v); self.line = try build(self.allocator, path); return self.line.?; }
        \\fn deinited(self: *Decode, gpa: Allocator) !void { self.probs.deinit(gpa); self.probs = try Vec2d.init(gpa, 4); }
        \\fn between(gpa: Allocator, s: *S, w: *Writer) !void { gpa.free(s.name); try w.writeAll("x"); s.name = &.{}; }
        \\fn caught(gpa: Allocator, s: *S) !void { gpa.destroy(s.node); s.node = gpa.create(Node) catch |err| return err; }
        \\fn branch(gpa: Allocator, s: *S, n: usize) !void { gpa.free(s.items); if (n == 0) s.items = &.{} else s.items = try gpa.alloc(u8, n); }
        \\fn pointerLocal(self: *Editor) !void { const top = &self.undo[0]; self.gpa.free(top.after); top.after = try self.gpa.dupe(u8, self.now); }
        \\fn pointerVar(gpa: Allocator, list: *List) !void { var node: *Node = list.first; gpa.free(node.name); node.name = try gpa.dupe(u8, "x"); node = node.next; }
        \\fn captureLoop(gpa: Allocator, rows: []Row) !void { for (rows) |*row| { gpa.free(row.cells); row.cells = try gpa.alloc(u8, 4); } }
        \\fn early(self: *Rows, n: usize) !void { self.gpa.free(self.items); const names = try self.gpa.alloc(u8, 1); _ = self.width(); self.items = try self.gpa.alloc(u32, n); _ = names; }
        \\fn orelsed(gpa: Allocator, s: *S) !void { gpa.free(s.bytes); const b = gpa.rawAlloc(16, .@"16", 0) orelse return error.OutOfMemory; s.bytes = b[0..16]; }
        \\fn orelseBlock(gpa: Allocator, s: *S) !void { gpa.free(s.bytes); const b = s.pool.take() orelse { log(); return error.OutOfMemory; }; s.bytes = b; }
        \\fn rawFreed(gpa: Allocator, s: *S, n: usize) !void { gpa.rawFree(s.bytes, .@"1", 0); s.bytes = try gpa.alloc(u8, n); }
    ,
        \\1:42 self.items <- self.gpa.alloc
        \\2:63 history.ends <- gpa.alloc
        \\3:85 b.visible <- kept.toOwnedSlice
        \\4:76 self.line <- build
        \\5:52 self.probs <- Vec2d.init
        \\6:55 s.name <- w.writeAll
        \\7:42 s.node <- gpa.create
        \\8:52 s.items <- gpa.alloc
        \\9:67 top.after <- self.gpa.dupe
        \\10:82 node.name <- gpa.dupe
        \\11:73 row.cells <- gpa.alloc
        \\12:41 self.items <- self.gpa.alloc
        \\13:43 s.bytes <- gpa.rawAlloc
        \\14:47 s.bytes <- s.pool.take
        \\15:54 s.bytes <- gpa.alloc
        \\
    );
}

test "not reported: reset first, made first, by value, a bare local, or nothing to fail" {
    try expectRefills(
        \\fn reset(gpa: Allocator, v: *Viewer, n: usize) !void { gpa.free(v.order); v.order = &.{}; v.order = try gpa.alloc(u32, n); }
        \\fn made(self: *Rows, n: usize) !void { const new = try self.gpa.alloc(u32, n); self.gpa.free(self.items); self.items = new; }
        \\fn emptied(gpa: Allocator, s: *S, n: usize) !void { gpa.free(s.items); s.items.len = 0; s.items = try gpa.alloc(u8, n); }
        \\fn errdeferred(gpa: Allocator, s: *S, n: usize) !void { errdefer s.items = &.{}; gpa.free(s.items); s.items = try gpa.alloc(u8, n); }
        \\fn cleared(gpa: Allocator, s: *S, n: usize) !void { gpa.free(s.items); s.clear(); s.items = try gpa.alloc(u8, n); }
        \\fn byValue(gpa: Allocator, n: usize) !Rows { var r: Rows = .{ .items = try gpa.alloc(u32, 4) }; gpa.free(r.items); r.items = try gpa.alloc(u32, n); return r; }
        \\fn bare(gpa: Allocator, token: ?[]u8, next: []const u8) !void { var t = token; if (t) |old| gpa.free(old); t = try gpa.dupe(u8, next); _ = t; }
        \\fn infallible(gpa: Allocator, s: *S, kept: []u8) void { gpa.free(s.items); s.items = kept; }
        \\fn after(gpa: Allocator, s: *S, w: *Writer) !void { gpa.free(s.name); s.name = &.{}; try w.writeAll("x"); }
        \\fn never(gpa: Allocator, s: *S, w: *Writer) !void { gpa.free(s.name); try w.writeAll("x"); }
        \\fn resetInside(gpa: Allocator, s: *S, n: usize) !void { if (n > 0) { gpa.free(s.items); s.items = &.{}; } s.items = try gpa.alloc(u8, n); }
        \\fn elsewhere(gpa: Allocator, s: *S, n: usize) !void { gpa.free(s.a); s.b = try gpa.alloc(u8, n); }
        \\fn caughtHere(gpa: Allocator, s: *S) void { gpa.destroy(s.node); s.node = gpa.create(Node) catch unreachable; }
        \\fn withElse(gpa: Allocator, s: *S, n: usize) !void { if (n > 0) gpa.free(s.items) else log(); s.items = try gpa.alloc(u8, n); }
        \\fn resetInCatch(gpa: Allocator, s: *S, name: []const u8) void { if (s.name) |old| gpa.free(old); s.name = gpa.dupe(u8, name) catch |err| { s.name = null; log(err); return; }; }
        \\fn callFirst(self: *Rows, n: usize) !void { self.gpa.free(self.items); _ = self.width(); self.items = try self.gpa.alloc(u32, n); }
        \\fn orelseHere(gpa: Allocator, s: *S) void { gpa.free(s.bytes); s.bytes = s.pool.take() orelse &.{}; }
        \\fn orelseReset(gpa: Allocator, s: *S) !void { gpa.free(s.bytes); s.bytes = s.pool.take() orelse { s.bytes = &.{}; return error.OutOfMemory; }; }
    , "");
}

test "a local freed, then refilled, that a defer of its function frees again (#252)" {
    try expectRefills(
        \\fn rename(gpa: Allocator, text: []const u8) !void { var name: []u8 = try gpa.dupe(u8, "x"); defer gpa.free(name); gpa.free(name); name = try gpa.dupe(u8, text); }
        \\fn resample(gpa: Allocator, text: []const u8) !void { var sample: List = .empty; defer { for (sample.items) |s| gpa.free(s.line); sample.deinit(gpa); } gpa.free(sample.items[0].line); sample.items[0] = .{ .id = 1, .line = try gpa.dupe(u8, text) }; }
        \\fn errdeferred(gpa: Allocator, text: []const u8) ![]u8 { var name: []u8 = try gpa.dupe(u8, "x"); errdefer gpa.free(name); gpa.free(name); name = try gpa.dupe(u8, text); return name; }
        \\fn optional(gpa: Allocator, text: []const u8) !void { var name: ?[]u8 = null; defer if (name) |n| gpa.free(n); if (name) |old| gpa.free(old); name = try gpa.dupe(u8, text); }
        \\fn deinited(gpa: Allocator, n: usize) !void { var l: List = .empty; defer l.deinit(gpa); l.deinit(gpa); l = try .initCapacity(gpa, n); }
        \\fn outer(gpa: Allocator, texts: []const []const u8) !void { var name: []u8 = try gpa.dupe(u8, "x"); defer gpa.free(name); for (texts) |text| { gpa.free(name); name = try gpa.dupe(u8, text); } }
        \\fn pointed(gpa: Allocator, text: []const u8) !void { var rows: Rows = .{}; defer for (rows.items) |*row| gpa.free(row.cells); gpa.free(rows.items[1].cells); rows.items[1].cells = try gpa.dupe(u8, text); }
        \\fn orelsed(gpa: Allocator, s: *S) !void { var b: []u8 = try gpa.alloc(u8, 4); errdefer gpa.free(b); gpa.free(b); b = s.pool.take() orelse return error.OutOfMemory; s.keep(b); }
    ,
        \\1:115 name <- gpa.dupe
        \\2:153 sample.items[0].line <- gpa.dupe
        \\3:123 name <- gpa.dupe
        \\4:128 name <- gpa.dupe
        \\5:90 l <- .initCapacity
        \\6:144 name <- gpa.dupe
        \\7:127 rows.items[1].cells <- gpa.dupe
        \\8:101 b <- s.pool.take
        \\
    );
}

test "not reported: a local no defer frees again" {
    try expectRefills(
        \\fn noDefer(gpa: Allocator, text: []const u8) !void { var name: []u8 = try gpa.dupe(u8, "x"); gpa.free(name); name = try gpa.dupe(u8, text); gpa.free(name); }
        \\fn armedAfter(gpa: Allocator, text: []const u8) !void { var name: []u8 = try gpa.dupe(u8, "x"); gpa.free(name); name = try gpa.dupe(u8, text); defer gpa.free(name); }
        \\fn sibling(gpa: Allocator, text: []const u8) !void { { var name: []u8 = try gpa.dupe(u8, "a"); defer gpa.free(name); log(name); } { var name: []u8 = try gpa.dupe(u8, "b"); gpa.free(name); name = try gpa.dupe(u8, text); gpa.free(name); } }
        \\fn nulled(gpa: Allocator, text: []const u8) ?[]u8 { var name: []u8 = gpa.dupe(u8, "x") catch return null; errdefer gpa.free(name); gpa.free(name); name = gpa.dupe(u8, text) catch return null; return name; }
        \\fn another(gpa: Allocator, text: []const u8) !void { var name: []u8 = try gpa.dupe(u8, "x"); const kept = try gpa.dupe(u8, "y"); defer gpa.free(kept); gpa.free(name); name = try gpa.dupe(u8, text); gpa.free(name); }
        \\fn otherList(gpa: Allocator, other: List, text: []const u8) !void { var sample: List = .empty; defer for (other.items) |s| gpa.free(s.line); gpa.free(sample.items[0].line); sample.items[0] = .{ .line = try gpa.dupe(u8, text) }; }
        \\fn listOnly(gpa: Allocator, text: []const u8) !void { var sample: List = .empty; defer sample.deinit(gpa); gpa.free(sample.items[0].line); sample.items[0] = .{ .line = try gpa.dupe(u8, text) }; }
    , "");
}

test "a local declared empty, freed before anything fills it, frees nothing (#252)" {
    try expectRefills(
        \\fn once(gpa: Allocator, decls: []const Decl) !void { var s: []const u8 = try gpa.dupe(u8, ""); errdefer gpa.free(s); for (decls) |d| { if (d.main) { gpa.free(s); s = try typeString(gpa, d); break; } } use(s); }
        \\fn literal(gpa: Allocator, text: []const u8) !void { var s: []u8 = &.{}; defer gpa.free(s); gpa.free(s); s = try gpa.dupe(u8, text); }
        \\fn grown(gpa: Allocator, items: []const []const u8) !void { var buf: []u8 = &.{}; defer gpa.free(buf); for (items) |item| { if (item.len > buf.len) { gpa.free(buf); buf = try gpa.alloc(u8, item.len); } } }
        \\fn storedFirst(gpa: Allocator, text: []const u8) !void { var s: []u8 = &.{}; defer gpa.free(s); s = try gpa.dupe(u8, "x"); gpa.free(s); s = try gpa.dupe(u8, text); }
        \\fn handed(gpa: Allocator, text: []const u8) !void { var s: []u8 = &.{}; defer gpa.free(s); try fill(gpa, &s); gpa.free(s); s = try gpa.dupe(u8, text); }
        \\fn sentinel(gpa: Allocator, text: []const u8) !void { var s: [:0]u8 = try gpa.dupeZ(u8, ""); defer gpa.free(s); gpa.free(s); s = try gpa.dupeZ(u8, text); }
    ,
        \\3:151 buf <- gpa.alloc
        \\4:124 s <- gpa.dupe
        \\5:111 s <- gpa.dupe
        \\6:113 s <- gpa.dupeZ
        \\
    );
}

test "a release of its receiver that resets what it frees leaves nothing freed (#252)" {
    try expectRefills(
        \\const Render = struct {
        \\    rgb: ?[]u8 = null,
        \\    fn deinit(r: *Render, gpa: Allocator) void { if (r.rgb) |p| gpa.free(p); r.rgb = null; }
        \\};
        \\const Image = struct {
        \\    px: []u8,
        \\    fn deinit(i: *Image, gpa: Allocator) void { gpa.free(i.px); i.* = undefined; }
        \\};
        \\const S = struct { base: Render, node: *Node };
        \\const Pool = struct {
        \\    free_list: ?*Node = null,
        \\    fn free(p: *Pool, n: *Node) void { p.free_list = n; }
        \\};
        \\fn local(gpa: Allocator) !void { var base: Render = .{}; defer base.deinit(gpa); base.deinit(gpa); base = try render(gpa); }
        \\fn field(gpa: Allocator, s: *S) !void { s.base.deinit(gpa); s.base = try render(gpa); }
        \\fn undef(gpa: Allocator) !void { var image: Image = try make(gpa); defer image.deinit(gpa); image.deinit(gpa); image = try make(gpa); }
        \\fn argument(pool: *Pool, s: *S) !void { pool.free(s.node); s.node = try pool.make(); }
    ,
        \\16:93 image <- make
        \\17:41 s.node <- pool.make
        \\
    );
}

test "a place freed through the file's own function (#64)" {
    try expectRefills(
        \\const S = struct {
        \\    gpa: Allocator,
        \\    fn destroyLocal(self: *S, local: Local) void { self.gpa.free(local.bytes); }
        \\    fn helped(self: *S) !void { self.destroyLocal(self.one); self.one = .{ .bytes = try self.gpa.alloc(u8, 16) }; }
        \\    fn typed(self: *S) !void { S.destroyLocal(self, self.one); self.one = .{ .bytes = try self.gpa.alloc(u8, 16) }; }
        \\    fn entry(self: *S, key: u64) !void { const e = try self.map.getOrPut(self.gpa, key); if (e.found_existing) self.destroyLocal(e.value_ptr.*); const b = self.gpa.rawAlloc(16, .@"16", 0) orelse { return error.OutOfMemory; }; e.value_ptr.* = .{ .bytes = b[0..16] }; }
        \\};
        \\fn drop(gpa: Allocator, node: *Node) void { gpa.destroy(node); }
        \\fn swap(gpa: Allocator, t: *T) !void { drop(gpa, t.node); t.node = try gpa.create(Node); }
        \\fn maybeDrop(gpa: Allocator, local: Local) void { if (local.owned) gpa.free(local.bytes); }
        \\fn maybe(gpa: Allocator, t: *T) !void { maybeDrop(gpa, t.one); t.one = .{ .bytes = try gpa.alloc(u8, 4) }; }
    ,
        \\4:33 self.one <- self.gpa.alloc
        \\5:32 self.one <- self.gpa.alloc
        \\6:112 e.value_ptr.* <- self.gpa.rawAlloc
        \\9:40 t.node <- gpa.create
        \\11:41 t.one <- gpa.alloc
        \\
    );
}

test "not reported: a function that frees nothing, or what the place points at, or the new value made first" {
    try expectRefills(
        \\const S = struct {
        \\    gpa: Allocator,
        \\    fn destroyLocal(self: *S, local: Local) void { self.gpa.free(local.bytes); }
        \\    fn note(self: *S, local: Local) void { self.log(local.bytes.len); }
        \\    fn noted(self: *S) !void { self.note(self.one); self.one = .{ .bytes = try self.gpa.alloc(u8, 16) }; }
        \\    fn destroyAt(self: *S, local: *Local) void { self.gpa.free(local.bytes); local.* = .{ .bytes = &.{} }; }
        \\    fn pointed(self: *S) !void { self.destroyAt(&self.one); self.one = .{ .bytes = try self.gpa.alloc(u8, 16) }; }
        \\    fn madeFirst(self: *S) !void { const b = try self.gpa.alloc(u8, 16); self.destroyLocal(self.one); self.one = .{ .bytes = b }; }
        \\    fn reset(self: *S) void { self.gpa.free(self.items); }
        \\    fn receiverOnly(self: *S) !void { self.reset(); self.items = try self.gpa.alloc(u8, 4); }
        \\};
        \\fn elsewhere(t: *T) !void { other.drop(t.node); t.node = try make(); }
    , "");
}
