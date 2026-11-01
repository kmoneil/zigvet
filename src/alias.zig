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
//!
//! A union is given its tag, and an optional is marked not null, before
//! any element is evaluated, so the first element can read what was
//! stored too: `left = .{ .pair = try alloc(.{ .left = left, .right =
//! right }) }` stores `.pair` into `left`, then copies `left`, its payload
//! not yet written, into the new node (measured on 0.17.0, in every build
//! mode). A read of the whole place, or of a part holding it, is reported,
//! and for a union one of a field other than the one being given a value;
//! an optional's payload (`o.?`) and the union's own field are not. That
//! holds when the file declares the place a tagged union or an optional,
//! and for an initializer of one field into a place whose type the file
//! does not show, taken for a union, where only a read of the whole place
//! is reported. A struct given one field could be reported there, but of
//! the 3,050 such initializers in Zig 0.17.0's sources and twenty-six
//! projects, none was. A struct is given its omitted fields' defaults after
//! the fields named, so one the file declares is read as it was.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const children = @import("children.zig");
const escape = @import("escape.zig");
const expect = @import("expect.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

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
        if (rule.types == null) rule.types = try .init(arena, tree);
        rule.target = target;
        rule.target_text = tree.getNodeSource(lhs);
        rule.reads_old = false;
        rule.found.clearRetainingCapacity();
        var stored: std.ArrayList(Stored) = .empty;
        try rule.initializer(target, rule.placeType(lhs), rhs, &stored);
        // A whole struct given its fields by name, none of them read from
        // what it held, is being made afresh, and reading back a field it
        // has just set (`.allocator = self.arena.allocator()`) is how that
        // is written on purpose.
        const fresh = target.parts.len == 0 and isStructInit(tree.nodeTag(rhs)) and !rule.reads_old;
        if (!fresh) try findings.appendSlice(arena, rule.found.items);
    }
}

const hint = "copy the old value first and read the copy, or assign the fields one at a time, each read before it is overwritten";
const header_hint = "build the value in a local first, then assign it: the tag, or that the place is not null, is stored before the initializer's elements are evaluated";

/// A place named from a variable: `d.rate[0]` is `d`, then `.rate`, then
/// `[0]`. `.*` and `.?` are left out of the parts, as a field access derefs
/// by itself; only whether the path ends in `.*`, or in `.?`, is kept.
const Path = struct {
    root: []const u8,
    parts: []const Part,
    deref: bool = false,
    unwrap: bool = false,

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
        if (p.deref) try w.writeAll(".*");
    }
};

/// What an initializer has stored by the time an element is evaluated.
const Stored = union(enum) {
    /// A field or index an earlier element stored.
    slot: Path,
    /// A union's tag, or an optional's mark that it is not null, stored
    /// into the place before any element is evaluated.
    header: Header,

    const Header = struct {
        place: Path,
        /// The union's field being given a value; null for an optional.
        field: ?[]const u8,
        /// Whether a read of another of the union's fields reads the tag:
        /// only when the file declares the place a tagged union.
        others: bool,

        /// Whether reading `read` reads the header: `read` is the place, or
        /// holds it and is `target` or inside it, or, for a declared union,
        /// is inside a field other than the one being given a value. An
        /// optional's payload, `o.?`, is not its header.
        fn hitBy(h: Header, read: Path, target: Path) bool {
            const place = h.place;
            if (!std.mem.eql(u8, read.root, place.root)) return false;
            const n = @min(read.parts.len, place.parts.len);
            for (read.parts[0..n], place.parts[0..n]) |x, y| if (!x.eql(y)) return false;
            if (read.parts.len > place.parts.len) {
                const field = h.field orelse return false;
                if (!h.others) return false;
                const next = read.parts[place.parts.len];
                return next != .field or !std.mem.eql(u8, next.field, field);
            }
            if (read.parts.len == place.parts.len and read.unwrap and h.field == null) return false;
            if (read.parts.len != target.parts.len) return read.parts.len > target.parts.len;
            // `b` read for `b.* = .{...}` is the pointer, not the memory.
            return read.deref or !target.deref;
        }
    };

    pub fn format(s: Stored, w: *Writer) Writer.Error!void {
        switch (s) {
            .slot => |slot| try slot.format(w),
            .header => |h| if (h.field) |field|
                try w.print("{f}'s tag, .{s}", .{ h.place, field })
            else
                try w.print("{f} as not null", .{h.place}),
        }
    }
};

/// The first of `stored` of kind `kind` that reading `read` reads.
fn hitIn(read: Path, stored: []const Stored, target: Path, kind: std.meta.Tag(Stored)) ?Stored {
    for (stored) |s| if (s == kind and switch (s) {
        .slot => |slot| read.hits(slot, target),
        .header => |h| h.hitBy(read, target),
    }) return s;
    return null;
}

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    /// Made at the file's first assignment of an anonymous initializer.
    types: ?types.Types = null,
    /// The assignment's left side, as a path and as written.
    target: Path = .{ .root = "", .parts = &.{} },
    target_text: []const u8 = "",
    /// What the assignment's initializer reads that it has already stored.
    found: std.ArrayList(Finding) = .empty,
    /// Whether the initializer reads any of what the place held before it
    /// stored to it.
    reads_old: bool = false,

    /// Checks each element of `init`, an anonymous initializer stored into
    /// `target`, against what was stored before it, adding what each stores
    /// to `stored`. `place_type` is `target`'s type, when the file shows it.
    fn initializer(r: *Rule, target: Path, place_type: ?Node.Index, init: Node.Index, stored: *std.ArrayList(Stored)) Allocator.Error!void {
        const tree = r.tree;
        var of = place_type;
        if (of) |t| if (optionalChild(tree, t)) |child| {
            try stored.append(r.arena, .{ .header = .{ .place = target, .field = null, .others = false } });
            of = child;
        };
        const container = if (of) |t| r.containerOf(t) else null;
        var buffer: [2]Node.Index = undefined;
        if (tree.fullStructInit(&buffer, init)) |s| {
            // One field into a place whose type the file does not show is
            // taken for a union, its other fields left alone.
            if (s.ast.fields.len == 1) {
                const declared = if (container) |c| isTaggedUnion(tree, c) else false;
                if (declared or container == null) try stored.append(r.arena, .{ .header = .{
                    .place = target,
                    .field = fieldName(tree, s.ast.fields[0]),
                    .others = declared,
                } });
            }
            for (s.ast.fields) |value| {
                const name = fieldName(tree, value);
                const field_type = if (container) |c| types.fieldType(tree, c, name) else null;
                try r.element(try target.with(r.arena, .{ .field = name }), field_type, value, stored);
            }
        } else if (tree.fullArrayInit(&buffer, init)) |a| {
            const element_type = if (of) |t| types.elementOf(tree, t) else null;
            for (a.ast.elements, 0..) |value, i| {
                try r.element(try target.with(r.arena, .{ .index = try r.arena.print("{d}", .{i}) }), element_type, value, stored);
            }
        }
    }

    fn element(r: *Rule, slot: Path, slot_type: ?Node.Index, value: Node.Index, stored: *std.ArrayList(Stored)) Allocator.Error!void {
        // `.x = p.x` stores what the slot holds already, so a later read of
        // it reads the same.
        if (try r.path(value)) |same| if (same.eql(slot)) return;
        // A nested anonymous initializer is written in place too, a field at
        // a time; anything else is evaluated whole, then stored.
        if (isAnonymousInit(r.tree.nodeTag(value))) {
            try r.initializer(slot, slot_type, value, stored);
        } else {
            try r.reads(value, stored.items);
        }
        try stored.append(r.arena, .{ .slot = slot });
    }

    /// Reports each read in `node` of a place that overlaps one of `stored`,
    /// and notes a read of what the place held before it was stored to.
    fn reads(r: *Rule, node: Node.Index, stored: []const Stored) Allocator.Error!void {
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
            const header = hitIn(read, stored, r.target, .header);
            // A tag is never read back on purpose: the read means what the
            // place held, so the place is not being made afresh.
            if (header != null) r.reads_old = true;
            // A slot is named over a header, as what the syntax proves.
            if (hitIn(read, stored, r.target, .slot) orelse header) |s| {
                try r.found.append(r.arena, .{
                    .offset = tree.tokenStart(tree.firstToken(node)),
                    .hint = if (s == .header) header_hint else hint,
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
    fn indexReads(r: *Rule, node: Node.Index, stored: []const Stored) Allocator.Error!void {
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
        return .{
            .root = tree.tokenSlice(tree.nodeMainToken(n)),
            .parts = parts.items,
            .deref = deref orelse false,
            .unwrap = endsInUnwrap(tree, node),
        };
    }

    /// The type the file declares for place `node`, or null if it does not
    /// show one.
    fn placeType(r: *Rule, node: Node.Index) ?Node.Index {
        const tree = r.tree;
        switch (tree.nodeTag(node)) {
            .identifier => return r.types.?.typeOf(node, 0),
            .grouped_expression => return r.placeType(tree.nodeData(node).node_and_token[0]),
            .field_access => {
                const lhs, const field = tree.nodeData(node).node_and_token;
                const outer = r.placeType(lhs) orelse return null;
                const container = r.containerOf(types.pointee(tree, outer) orelse outer) orelse return null;
                return types.fieldType(tree, container, tree.tokenSlice(field));
            },
            .deref => return types.pointee(tree, r.placeType(tree.nodeData(node).node) orelse return null),
            .array_access => return types.elementOf(tree, r.placeType(tree.nodeData(node).node_and_node[0]) orelse return null),
            .unwrap_optional => return optionalChild(tree, r.placeType(tree.nodeData(node).node_and_token[0]) orelse return null),
            else => return null,
        }
    }

    /// The struct or union `type_expr` is or names, when the file shows it.
    fn containerOf(r: *Rule, type_expr: Node.Index) ?Node.Index {
        var buffer: [2]Node.Index = undefined;
        if (r.tree.fullContainerDecl(&buffer, type_expr) != null) return type_expr;
        return r.types.?.containerOf(type_expr, 0);
    }
};

/// The name `value` is given to in a struct initializer: `.name = value`.
fn fieldName(tree: *const Ast, value: Node.Index) []const u8 {
    return tree.tokenSlice(tree.firstToken(value) - 2);
}

/// Whether `node`'s outermost access, under any parentheses, is `.?`.
fn endsInUnwrap(tree: *const Ast, node: Node.Index) bool {
    var n = node;
    while (tree.nodeTag(n) == .grouped_expression) n = tree.nodeData(n).node_and_token[0];
    return tree.nodeTag(n) == .unwrap_optional;
}

/// What `?T` holds, or null for any other type.
fn optionalChild(tree: *const Ast, type_expr: Node.Index) ?Node.Index {
    if (tree.nodeTag(type_expr) != .optional_type) return null;
    return tree.nodeData(type_expr).node;
}

/// Whether `container` is a union with a tag: `union(enum)` or `union(T)`.
fn isTaggedUnion(tree: *const Ast, container: Node.Index) bool {
    const main = tree.nodeMainToken(container);
    return tree.tokenTag(main) == .keyword_union and tree.tokenTag(main + 1) == .l_paren;
}

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
    try expect.findings(@src(), expected, out.written());
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

test "a union's tag and an optional's mark, stored before any element is evaluated" {
    try expectAliases(
        \\const Expr = union(enum) { lit: f64, pair: *Pair };
        \\const Pair = struct { left: Expr, right: Expr };
        \\const H = struct { e: Expr, n: u32 };
        \\fn local(right: Expr) !Expr { var left: Expr = .{ .lit = 1 }; left = .{ .pair = try alloc(.{ .left = left, .right = right }) }; return left; }
        \\fn through(e: *Expr) void { e.* = .{ .pair = make(e.*) }; }
        \\fn tag(e: *Expr) void { e.* = .{ .lit = switch (e.*) { .lit => |v| v, .pair => 0 } }; }
        \\fn other(e: *Expr) void { e.* = .{ .lit = e.pair.left.lit }; }
        \\fn inStruct(h: *H) !void { h.* = .{ .e = .{ .pair = try alloc(.{ .left = h.e, .right = h.e }) }, .n = 1 }; }
        \\fn unknown(s: *Sel, r: Sel) !void { s.* = .{ .complex = try alloc(.{ .left = s.*, .right = r }) }; }
        \\fn unknownLocal(p: *Parser) !Sel { var left = try p.next(); left = .{ .complex = try alloc(.{ .left = left }) }; return left; }
        \\fn optional(s: *?[2]u32, t: u32) void { s.* = .{ if (s.*) |v| v[0] else t, t }; }
        \\fn optionalLocal(t: u32) [2]u32 { var span: ?[2]u32 = null; span = .{ if (span) |v| v[0] else t, t }; return span.?; }
        \\fn afterSlot(t: *T) void { t.* = .{ .node = .{ .l = 5, .r = switch (t.*) { .leaf => |x| x, .node => 99 } } }; }
    ,
        \\4:102 left -> left, left's tag, .pair
        \\5:51 e.* -> e.*, e.*'s tag, .pair
        \\6:49 e.* -> e.*, e.*'s tag, .lit
        \\7:43 e.pair.left.lit -> e.*, e.*'s tag, .lit
        \\8:74 h.e -> h.*, h.e's tag, .pair
        \\8:88 h.e -> h.*, h.e's tag, .pair
        \\9:78 s.* -> s.*, s.*'s tag, .complex
        \\10:103 left -> left, left's tag, .complex
        \\11:54 s.* -> s.*, s.* as not null
        \\12:75 span -> span, span as not null
        \\13:69 t.* -> t.*, t.node.l
        \\
    );
}

test "not reported: a union's own field, a struct given one field, a typed union, an optional's payload" {
    try expectAliases(
        \\const Expr = union(enum) { lit: f64, pair: *Pair };
        \\const Bare = union { a: u32, b: u32 };
        \\const W = struct { a: u32, b: u32 = 0 };
        \\fn own(e: *Expr) !void { e.* = .{ .pair = try copy(e.pair) }; }
        \\fn typed(e: *Expr) !void { e.* = Expr{ .pair = try alloc(.{ .left = e.*, .right = e.* }) }; }
        \\fn structOne(w: *W) void { w.* = .{ .a = sum(w.*) }; }
        \\fn bare(u: *Bare) void { u.* = .{ .a = u.b }; }
        \\fn unknownOther(s: *Sel) void { s.* = .{ .inner = init(s.alloc) }; }
        \\fn payload(o: *?W) void { o.* = .{ .a = sum(o.*.?), .b = 0 }; }
        \\fn notOptional(s: *[2]u32, t: u32) void { s.* = .{ g(s.*), t }; }
        \\fn pointerOnly(e: *Expr) void { e.* = .{ .pair = make(e) }; }
    , "");
}
