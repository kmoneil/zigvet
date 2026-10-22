//! Rule two, alias: an anonymous initializer assigned to a place that one of
//! its own later elements reads.
//!
//! Zig writes an anonymous initializer straight into the place it is
//! assigned to, an element at a time in the order written, so
//! `d.rate = .{ new, d.rate[0] }` stores `new` into `d.rate[0]` and then
//! reads it back: `{ new, new }`. A typed one, `T{...}` or `[_]T{...}`, is
//! built aside and then copied, so it is read whole as one element (measured
//! on 0.17.0, in every build mode).
//!
//! Only what the syntax proves is reported: an element that reads, by the
//! same path, a field or literal index an earlier element stored, or reads
//! the whole place, or a part holding a stored slot, after an element has
//! stored into it. Reading the slot an element is about to store is fine
//! and common (`lo = .{ .x = @min(lo.x, q.x), .y = @min(lo.y, q.y) }`), and
//! an index that is not a literal could be either, so neither is reported.
//! Nor is what reads no memory of the place: its address (`&p.step`), the
//! pointer it is reached through (`.owner = b` in `b.* = .{...}`), anything
//! shorter than it, which may be such a pointer, and a `return`, whose value
//! is not stored. Two names for the same memory are out of reach.
//!
//! Two shapes read what was stored on purpose, and are not reported
//! either. A slot stored with what it holds already (`.superblock =
//! self.superblock`) reads the same afterwards. And a whole struct given its
//! fields by name, none of them read from what it held, is being made
//! afresh: `self.* = .{ .arena = .init(gpa), .allocator =
//! self.arena.allocator() }` reads back a field it has just set because
//! that is the field it means. Over fourteen public Zig projects these
//! were all 22 of alias's reports. A swap or a shift reads what the place
//! held, by position or into part of a struct, and is still reported.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const children = @import("children.zig");
const escape = @import("escape.zig");
const report = @import("report.zig");
const Finding = report.Finding;

/// Appends a finding for every element that reads what its initializer has
/// already stored. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree };
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .assign) continue;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        if (!isAnonymousInit(tree.nodeTag(rhs))) continue;
        const target = try rule.path(lhs) orelse continue;
        rule.target = target;
        rule.target_text = tree.getNodeSource(lhs);
        rule.reads_old = false;
        rule.found.clearRetainingCapacity();
        var stored: std.ArrayList(Path) = .empty;
        try rule.initializer(target, rhs, &stored);
        // A whole struct given its fields by name, none of them read from
        // what it held, is being made afresh, and reading back a field it
        // has just set (`.allocator = self.arena.allocator()`) is how that
        // is written on purpose.
        const fresh = target.parts.len == 0 and isStructInit(tree.nodeTag(rhs)) and !rule.reads_old;
        if (!fresh) try findings.appendSlice(arena, rule.found.items);
    }
}

const hint = "copy the old value first and read the copy, or assign the fields one at a time, each read before it is overwritten";

/// A place named from a variable: `d.rate[0]` is `d`, then `.rate`, then
/// `[0]`. `.*` and `.?` are left out of the parts, as a field access derefs
/// by itself; only whether the path ends in `.*` is kept.
const Path = struct {
    root: []const u8,
    parts: []const Part,
    deref: bool = false,

    const Part = union(enum) {
        field: []const u8,
        /// As written: a literal, or any other expression.
        index: []const u8,

        fn eql(a: Part, b: Part) bool {
            return switch (a) {
                .field => |name| b == .field and std.mem.eql(u8, name, b.field),
                .index => |text| b == .index and std.mem.eql(u8, text, b.index),
            };
        }
    };

    fn eql(a: Path, b: Path) bool {
        if (!std.mem.eql(u8, a.root, b.root) or a.parts.len != b.parts.len or a.deref != b.deref) return false;
        for (a.parts, b.parts) |x, y| if (!x.eql(y)) return false;
        return true;
    }

    /// Whether reading `read` reads memory of `place`: a part of it, or
    /// all of it, not the pointer it is reached through.
    fn inside(read: Path, place: Path) bool {
        if (!std.mem.eql(u8, read.root, place.root) or read.parts.len < place.parts.len) return false;
        for (place.parts, read.parts[0..place.parts.len]) |x, y| if (!x.eql(y)) return false;
        if (read.parts.len > place.parts.len) return true;
        return read.deref or !place.deref;
    }

    fn with(p: Path, arena: Allocator, part: Part) Allocator.Error!Path {
        const parts = try arena.alloc(Part, p.parts.len + 1);
        @memcpy(parts[0..p.parts.len], p.parts);
        parts[p.parts.len] = part;
        return .{ .root = p.root, .parts = parts };
    }

    /// Whether reading `read` reads `stored`, a slot of `target`: `read` is
    /// `stored` or inside it, or holds it and is `target` or inside it.
    fn hits(read: Path, stored: Path, target: Path) bool {
        if (!std.mem.eql(u8, read.root, stored.root)) return false;
        const n = @min(read.parts.len, stored.parts.len);
        for (read.parts[0..n], stored.parts[0..n]) |x, y| if (!x.eql(y)) return false;
        if (read.parts.len >= stored.parts.len) return true;
        if (read.parts.len != target.parts.len) return read.parts.len > target.parts.len;
        // `b` read for `b.* = .{...}` is the pointer, not the memory.
        return read.deref or !target.deref;
    }

    pub fn format(p: Path, w: *Writer) Writer.Error!void {
        try w.writeAll(p.root);
        for (p.parts) |part| switch (part) {
            .field => |name| try w.print(".{s}", .{name}),
            .index => |text| try w.print("[{s}]", .{text}),
        };
    }
};

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    /// The assignment's left side, as a path and as written.
    target: Path = .{ .root = "", .parts = &.{} },
    target_text: []const u8 = "",
    /// What the assignment's initializer reads that it has already stored.
    found: std.ArrayList(Finding) = .empty,
    /// Whether the initializer reads any of what the place held before it
    /// stored to it.
    reads_old: bool = false,

    /// Checks each element of `init`, an anonymous initializer stored into
    /// `target`, against what the elements before it stored, adding what
    /// each stores to `stored`.
    fn initializer(r: *Rule, target: Path, init: Node.Index, stored: *std.ArrayList(Path)) Allocator.Error!void {
        const tree = r.tree;
        var buffer: [2]Node.Index = undefined;
        if (tree.fullStructInit(&buffer, init)) |s| {
            for (s.ast.fields) |value| {
                // `.name = value`
                const name = tree.tokenSlice(tree.firstToken(value) - 2);
                try r.element(try target.with(r.arena, .{ .field = name }), value, stored);
            }
        } else if (tree.fullArrayInit(&buffer, init)) |a| {
            for (a.ast.elements, 0..) |value, i| {
                try r.element(try target.with(r.arena, .{ .index = try r.arena.print("{d}", .{i}) }), value, stored);
            }
        }
    }

    fn element(r: *Rule, slot: Path, value: Node.Index, stored: *std.ArrayList(Path)) Allocator.Error!void {
        // `.x = p.x` stores what the slot holds already, so a later read of
        // it reads the same.
        if (try r.path(value)) |same| if (same.eql(slot)) return;
        // A nested anonymous initializer is written in place too, a field at
        // a time; anything else is evaluated whole, then stored.
        if (isAnonymousInit(r.tree.nodeTag(value))) {
            try r.initializer(slot, value, stored);
        } else {
            try r.reads(value, stored.items);
        }
        try stored.append(r.arena, slot);
    }

    /// Reports each read in `node` of a place that overlaps one of `stored`,
    /// and notes a read of what the place held before it was stored to.
    fn reads(r: *Rule, node: Node.Index, stored: []const Path) Allocator.Error!void {
        const tree = r.tree;
        switch (tree.nodeTag(node)) {
            // Evaluated at compile time: reads no memory.
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                if (escape.comptime_builtins.has(tree.tokenSlice(tree.nodeMainToken(node)))) return;
            },
            // Its value leaves the function rather than being stored.
            .@"return" => return,
            // An address reads nothing of the place, though its indexes do.
            .address_of => {
                const operand = tree.nodeData(node).node;
                if (try r.path(operand) != null) return r.indexReads(operand, stored);
            },
            else => {},
        }
        if (try r.path(node)) |read| {
            const hit = for (stored) |s| {
                if (read.hits(s, r.target)) break s;
            } else null;
            if (hit) |s| {
                try r.found.append(r.arena, .{
                    .offset = tree.tokenStart(tree.firstToken(node)),
                    .hint = hint,
                    .detail = .{ .alias = .{
                        .read = tree.getNodeSource(node),
                        .target = r.target_text,
                        .stored = try r.arena.print("{f}", .{s}),
                    } },
                });
            } else if (read.inside(r.target)) {
                r.reads_old = true;
            }
            return r.indexReads(node, stored);
        }
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, tree, node, &nodes);
        for (nodes.items) |child| try r.reads(child, stored);
    }

    /// The indexes along path `node`, which are reads of their own.
    fn indexReads(r: *Rule, node: Node.Index, stored: []const Path) Allocator.Error!void {
        const tree = r.tree;
        var n = node;
        while (true) switch (tree.nodeTag(n)) {
            .field_access, .unwrap_optional, .grouped_expression => n = tree.nodeData(n).node_and_token[0],
            .deref => n = tree.nodeData(n).node,
            .array_access => {
                const lhs, const index = tree.nodeData(n).node_and_node;
                try r.reads(index, stored);
                n = lhs;
            },
            else => break,
        };
    }

    /// `node` as a place named from a variable, or null if it is not one.
    fn path(r: *Rule, node: Node.Index) Allocator.Error!?Path {
        const tree = r.tree;
        var parts: std.ArrayList(Path.Part) = .empty;
        // Set by the outermost access: whether the path ends in `.*`.
        var deref: ?bool = null;
        var n = node;
        while (true) switch (tree.nodeTag(n)) {
            .identifier => break,
            .field_access => {
                const lhs, const field = tree.nodeData(n).node_and_token;
                try parts.append(r.arena, .{ .field = tree.tokenSlice(field) });
                deref = deref orelse false;
                n = lhs;
            },
            .array_access => {
                const lhs, const index = tree.nodeData(n).node_and_node;
                try parts.append(r.arena, .{ .index = tree.getNodeSource(index) });
                deref = deref orelse false;
                n = lhs;
            },
            .unwrap_optional, .grouped_expression => n = tree.nodeData(n).node_and_token[0],
            .deref => {
                deref = deref orelse true;
                n = tree.nodeData(n).node;
            },
            else => return null,
        };
        std.mem.reverse(Path.Part, parts.items);
        return .{ .root = tree.tokenSlice(tree.nodeMainToken(n)), .parts = parts.items, .deref = deref orelse false };
    }
};

fn isStructInit(tag: Node.Tag) bool {
    return switch (tag) {
        .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma => true,
        else => false,
    };
}

fn isAnonymousInit(tag: Node.Tag) bool {
    return switch (tag) {
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        => true,
        else => false,
    };
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col read -> target, stored`, in source order.
fn expectAliases(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var findings: std.ArrayList(Finding) = .empty;
    try check(arena_state.allocator(), &tree, &findings);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (findings.items) |finding| {
        const loc = report.location(source, finding.offset);
        const a = finding.detail.alias;
        try out.writer.print("{d}:{d} {s} -> {s}, {s}\n", .{ loc.line + 1, loc.column + 1, a.read, a.target, a.stored });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "the measured shapes that read what the initializer already stored" {
    try expectAliases(
        \\fn shift(d: *D, new: u32) void { d.rate = .{ new, d.rate[0] }; }
        \\fn swap(p: *P) void { p.* = .{ .x = p.y, .y = p.x }; }
        \\fn rotate(a: *[3]u8) void { a.* = .{ a[2], a[0], a[1] }; }
        \\fn order(u: *P) void { u.* = .{ .y = u.x, .x = u.y }; }
        \\fn shiftNamed(h: *H, cur: u32) void { h.hist = .{ .prev = cur, .prev2 = h.hist.prev }; }
        \\fn nested(n: *N) void { n.* = .{ .a = .{ .x = n.a.y, .y = n.a.x }, .b = n.b }; }
        \\fn swapBesideSame(p: *Q) void { p.* = .{ .z = p.z, .x = p.y, .y = p.x }; }
        \\fn rows(arr: *[2]P) void { arr.* = .{ .{ .x = 9, .y = 9 }, .{ .x = arr[0].x, .y = 2 } }; }
        \\fn sameIndex(a: [][2]u8, i: usize) void { a[i] = .{ 5, a[i][0] }; }
        \\fn local() void { var a: [2]u8 = .{ 1, 2 }; a = .{ 5, f(a) }; }
        \\fn swapLocal(ext: *[2]f32) void { var e = ext.*; if (e[1] < e[0]) e = .{ e[1], e[0] }; ext.* = e; }
    ,
        \\1:51 d.rate[0] -> d.rate, d.rate[0]
        \\2:47 p.x -> p.*, p.x
        \\3:44 a[0] -> a.*, a[0]
        \\3:50 a[1] -> a.*, a[1]
        \\4:48 u.y -> u.*, u.y
        \\5:73 h.hist.prev -> h.hist, h.hist.prev
        \\6:59 n.a.x -> n.*, n.a.x
        \\7:67 p.x -> p.*, p.x
        \\8:68 arr[0].x -> arr.*, arr[0].x
        \\9:56 a[i][0] -> a[i], a[i][0]
        \\10:57 a -> a, a[0]
        \\11:80 e[0] -> e, e[0]
        \\
    );
}

test "not reported: own slot, typed initializers, unknown indexes, compile-time reads" {
    try expectAliases(
        \\fn bounds(lo: *P, q: P) void { lo.* = .{ .x = @min(lo.x, q.x), .y = @min(lo.y, q.y) }; }
        \\fn step(at: *[2]i32, s: [2]i32) void { at.* = .{ at[0] + s[0], at[1] + s[1] }; }
        \\fn typed(q: *P) void { q.* = P{ .x = q.y, .y = q.x }; }
        \\fn typedArray(b: *[3]u8) void { b.* = [_]u8{ b[2], b[0], b[1] }; }
        \\fn typedOuter(t: *D) void { t.* = D{ .rate = .{ 7, t.rate[0] } }; }
        \\fn typedInnerFirst(n: *N) void { n.* = .{ .a = P{ .x = n.a.y, .y = n.a.x }, .b = n.b }; }
        \\fn unknown(w: *[2]u8, i: usize) void { w.* = .{ 5, w[i] }; }
        \\fn sized(p: *P) void { p.* = .{ .x = 1, .y = @sizeOf(@TypeOf(p.*)) }; }
        \\fn length(a: *[2]usize) void { a.* = .{ 1, a.len }; }
        \\fn other(p: *P, q: *P) void { p.* = .{ .x = q.y, .y = q.x }; }
        \\fn declared(p: P) P { const r: P = .{ .x = p.y, .y = p.x }; return r; }
        \\fn pointer(b: *B) void { b.* = .{ .graph = g, .owner = b }; }
        \\fn address(c: *C) void { c.* = .{ .step = .{}, .generated = add(&c.step) }; }
        \\fn returned(t: *T) !void { t.* = .{ .w = w0, .c = init() catch return t.w.err.? }; }
        \\fn shorter(d: *D, new: u32) void { d.rate = .{ new, g(d) }; }
    , "");
}

test "not reported: a slot stored with what it holds, and a whole struct made afresh" {
    try expectAliases(
        \\fn sameValue(t: *T) void { t.loc = .{ .start = t.loc.start, .end = t.loc.start + 1 }; }
        \\fn keepField(r: *R, o: O) void { r.* = .{ .superblock = r.superblock, .view = r.superblock.view, .opts = o }; }
        \\fn chain(self: *B, a: Allocator) void { self.* = .{ .arena = .init(a), .allocator = self.arena.allocator() }; }
        \\fn fresh(s: *P) void { s.* = .{ .x = 5, .y = id(s.*).x }; }
        \\fn freshTyped(m: *N) void { m.* = .{ .b = 7, .a = P{ .x = m.b, .y = 0 } }; }
        \\fn freshLocal(a: Allocator) B { var b: B = undefined; b = .{ .arena = .init(a), .allocator = b.arena.allocator() }; return b; }
    , "");
}
