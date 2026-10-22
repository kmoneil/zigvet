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
//! What frees is `x.free(place)`, `x.destroy(place)` or
//! `place.deinit(...)`, as a statement or the body of an `if`, or
//! `if (place) |old| x.free(old)`. The place has to be a field or what a
//! pointer points at (`self.items`, `a.*`). It is reported when a later
//! statement of the same block stores to it, or to what holds it written
//! whole (`history.* = .{ ... }`), and something can fail first: a `try`, or
//! a `catch` that returns, in the stored value or a statement between.
//!
//! Not reported: a place reset first (`self.items = &.{}`, or any store
//! into it), by an `errdefer` or by the `catch` that handles the failure,
//! or perhaps by a call between that is handed what holds it
//! (`self.clear()`); a field of a `var` local, which holds a struct by
//! value that the failing function throws away (Zig rejects a `var` that
//! is never changed, and a store to a field changes no pointer); and a
//! bare local, which an `errdefer` of its own can cover.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

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
    /// Every node's parent, made for the first place found refilled.
    parents: []const Node.OptionalIndex = &.{},

    /// The place `statement` frees: `x.free(place)`, `x.destroy(place)` or
    /// `place.deinit(...)`, alone or as the body of an `if` with no `else`,
    /// or `if (place) |old| x.free(old)`.
    fn release(r: *Rule, statement: Node.Index) Allocator.Error!?Release {
        const t = r.tree;
        const full = t.fullIf(statement) orelse {
            const call, const operand = releaseCall(t, statement) orelse return null;
            return r.placed(call, operand);
        };
        if (full.ast.else_expr != .none) return null;
        var body = full.ast.then_expr;
        var buffer: [2]Node.Index = undefined;
        if (t.blockStatements(&buffer, body)) |statements| {
            if (statements.len != 1) return null;
            body = statements[0];
        }
        const call, const operand = releaseCall(t, body) orelse return null;
        const token = full.payload_token orelse return r.placed(call, operand);
        // `if (place) |old| x.free(old)` frees the place.
        const name = if (t.tokenTag(token) == .asterisk) token + 1 else token;
        if (t.nodeTag(operand) != .identifier) return null;
        if (!std.mem.eql(u8, t.tokenSlice(t.nodeMainToken(operand)), t.tokenSlice(name))) return null;
        return r.placed(call, full.ast.cond_expr);
    }

    /// A release of `place` by `call`, if `place` is a field or what a
    /// pointer points at.
    fn placed(r: *Rule, call: Node.Index, place: Node.Index) Allocator.Error!?Release {
        const p = try r.path(place) orelse return null;
        if (p.parts.len == 0 and !p.deref) return null;
        return .{ .call = call, .place = place, .path = p };
    }

    /// Reports `freed` if one of `rest`, the statements after it in its
    /// block, refills it and something can fail before the store.
    fn after(r: *Rule, freed: Release, rest: []const Node.Index) Allocator.Error!void {
        const t = r.tree;
        // The first thing that can fail in a statement between.
        var fails: ?Node.Index = null;
        for (rest) |statement| {
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
                if (r.parents.len == 0) r.parents = (try types.Types.init(r.arena, t)).parents;
                if (r.heldByValue(freed.call, freed.path.root)) return;
                if (try r.resetOnError(freed, point)) return;
                return r.findings.append(r.arena, .{
                    .offset = t.tokenStart(t.firstToken(freed.call)),
                    .hint = hint,
                    .detail = .{ .refill = .{
                        .place = t.getNodeSource(freed.place),
                        .fails = what(t, point),
                    } },
                });
            }
            if (other or try r.handsOver(nodes.items, freed.path)) return;
            if (fails == null) fails = try r.failing(nodes.items, std.math.maxInt(Ast.TokenIndex), freed.path);
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
    /// whose handler returns without storing to the place first
    /// (`catch |err| { place = null; return err; }` leaves nothing freed).
    fn failing(r: *Rule, nodes: []const Node.Index, end: Ast.TokenIndex, place: Path) Allocator.Error!?Node.Index {
        const t = r.tree;
        var first: ?Node.Index = null;
        for (nodes) |node| {
            if (t.nodeMainToken(node) >= end) continue;
            const fails = switch (t.nodeTag(node)) {
                .@"try" => true,
                .@"catch" => fails: {
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

/// `x.free(operand)` or `x.destroy(operand)`, or `operand.deinit(...)`:
/// the call and what it frees.
pub fn releaseCall(t: *const Ast, node: Node.Index) ?struct { Node.Index, Node.Index } {
    var buffer: [1]Node.Index = undefined;
    const call = t.fullCall(&buffer, node) orelse return null;
    if (t.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver, const name_token = t.nodeData(call.ast.fn_expr).node_and_token;
    const name = t.tokenSlice(name_token);
    if (std.mem.eql(u8, name, "deinit")) return .{ node, receiver };
    if (call.ast.params.len != 1) return null;
    if (std.mem.eql(u8, name, "free") or std.mem.eql(u8, name, "destroy")) return .{ node, call.ast.params[0] };
    return null;
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

/// What fails at `point`, as written: the function a `try` or `catch`
/// calls, or the expression.
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
    try std.testing.expectEqualStrings(expected, out.written());
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
    , "");
}
