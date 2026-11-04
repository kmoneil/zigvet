//! Rule twenty-two, race: a container-level optional asked whether it is
//! null by value, when what it holds has atomics or a lock in it.
//!
//!     var registry: ?Registry = null; // Registry has a `mutex: std.Io.Mutex`
//!
//!     fn state(io: std.Io) *Registry {
//!         if (registry == null) registry = .{ .gpa = gpa, .io = io };
//!         return &registry.?;
//!     }
//!
//! In Debug, `registry == null` copies the whole global and then reads the
//! tag from the copy; `if (registry) |r|` does the same before it copies
//! the payload out. Measured on Zig 0.17.1 (x86_64-linux and aarch64-macos
//! alike): a memcpy of all 136 bytes of `registry`, then a load of one. When
//! other threads lock the mutex or store to the atomic, that copy is a plain
//! read racing their atomic writes: a data race, which ThreadSanitizer
//! reports on x86_64 Linux (a memcpy against the mutex's cmpxchg; macOS's
//! does not see it). It compiles clean in every build mode.
//! `if (registry) |*r|`, `registry.?` and `&registry.?` read the tag in
//! place, and release builds drop the copy (#170).
//!
//! What is reported: `g == null` and `g != null`, either way round, and an
//! `if` or `while` that captures `g`'s payload by value (`|r|`, `|_|`),
//! where `g` is a container-level `var` written as `?T`, by its name or
//! through its container (`S.g`, `@This().g`), and `T` is a struct or union
//! the file declares with a field that other threads change atomically: a
//! `std.atomic.Value(...)`; a `Mutex`, `RwLock`, `Semaphore`, `ResetEvent`
//! or `WaitGroup` of any namespace, a project's own `io.Mutex` too; a
//! `Condition` or `Event` of `std.Io`, `std.Thread` or `std.atomic`, as
//! those names are common elsewhere (`ui.Event`); any of them through a
//! container-level `const`, or an array of them; or a struct the file
//! declares that holds one, a level down.
//!
//! Not reported: a `const`, a `threadlocal` (no other thread reaches it), a
//! local, a field; a capture by pointer; a payload with none of those
//! fields, where the same copy is only a waste; a payload type the file does
//! not declare; and the global copied into a local (`const r = g.?`,
//! `g orelse ...`), which Debug copies whole too, but where the copy is
//! what is asked for.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const expect = @import("expect.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");
const Types = types.Types;

/// The types other threads change atomically, by name: of any namespace,
/// and two names common enough elsewhere that only these namespaces' count.
const lock_names = [_][]const u8{ "Mutex", "RwLock", "Semaphore", "ResetEvent", "WaitGroup" };
const std_names = [_][]const u8{ "Condition", "Event" };
const std_spaces = [_][]const u8{ "Io", "Thread", "atomic" };

/// A container-level `var` of an optional type whose payload holds a
/// field other threads change atomically.
const Global = struct {
    decl: Node.Index,
    name: []const u8,
    /// The field, as a path from the payload: `mutex`, `inner.count`.
    field: []const u8,
    /// The field's type, as written: `std.Io.Mutex`.
    field_type: []const u8,
};

/// A read that copies all of `operand` when it is a global: a null test
/// by value, or an `if` or `while`, `keyword`, that captures its payload
/// by value into `capture`.
const Read = struct {
    operand: Node.Index,
    capture: ?Ast.TokenIndex = null,
    keyword: []const u8 = "",
};

/// Appends a finding for every by-value null test or capture of a
/// container-level optional whose payload holds atomics or a lock.
/// Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    // Most files declare no optional `var`: look before reading a node.
    if (!optionalVarToken(tree)) return;
    const candidates = try optionalVars(arena, tree);
    if (candidates.len == 0) return;
    // Most of those are never asked by value: look by name before working
    // out what holds each node.
    if (!anyRead(tree, candidates)) return;
    const t: Types = try .init(arena, tree);
    var globals: std.ArrayList(Global) = .empty;
    for (candidates) |decl| {
        if (try heldSync(arena, t, decl)) |g| try globals.append(arena, g);
    }
    if (globals.items.len == 0) return;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const read = readOf(tree, node) orelse continue;
        const g = globalOf(t, globals.items, read.operand) orelse continue;
        try add(arena, tree, findings, node, read, g);
    }
}

/// Whether any `var name: ?` is written, at container level or not.
fn optionalVarToken(tree: *const Ast) bool {
    const tags = tree.tokens.items(.tag);
    if (tags.len < 4) return false;
    for (tags[0 .. tags.len - 3], 0..) |tag, i| {
        if (tag == .keyword_var and tags[i + 1] == .identifier and tags[i + 2] == .colon and tags[i + 3] == .question_mark) return true;
    }
    return false;
}

/// Every container-level `var` written as `?T`, but a `threadlocal`.
fn optionalVars(arena: Allocator, tree: *const Ast) Allocator.Error![]const Node.Index {
    var out: std.ArrayList(Node.Index) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [2]Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, node) orelse continue;
        for (container.ast.members) |member| {
            const decl = tree.fullVarDecl(member) orelse continue;
            if (tree.tokenTag(decl.ast.mut_token) != .keyword_var or decl.threadlocal_token != null) continue;
            const type_node = decl.ast.type_node.unwrap() orelse continue;
            if (tree.nodeTag(type_node) != .optional_type) continue;
            try out.append(arena, member);
        }
    }
    return out.items;
}

/// Whether any null test or capture by value reads something named as one
/// of `candidates` is.
fn anyRead(tree: *const Ast, candidates: []const Node.Index) bool {
    for (0..tree.nodes.len) |i| {
        const read = readOf(tree, @fromBackingInt(@intCast(i))) orelse continue;
        const name = lastName(tree, ungrouped(tree, read.operand));
        for (candidates) |decl| {
            if (std.mem.eql(u8, name, tree.tokenSlice(tree.fullVarDecl(decl).?.ast.mut_token + 1))) return true;
        }
    }
    return false;
}

/// The read `node` is, when it is one that copies all of an optional:
/// `x == null` or `x != null`, either way round, or an `if` or `while`
/// that captures by value.
fn readOf(tree: *const Ast, node: Node.Index) ?Read {
    switch (tree.nodeTag(node)) {
        .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            if (isNull(tree, rhs)) return .{ .operand = lhs };
            if (isNull(tree, lhs)) return .{ .operand = rhs };
            return null;
        },
        .if_simple, .@"if" => {
            const full = tree.fullIf(node).?;
            return captured(tree, "if", full.ast.cond_expr, full.payload_token);
        },
        .while_simple, .while_cont, .@"while" => {
            const full = tree.fullWhile(node).?;
            return captured(tree, "while", full.ast.cond_expr, full.payload_token);
        },
        else => return null,
    }
}

fn captured(tree: *const Ast, keyword: []const u8, cond: Node.Index, payload_token: ?Ast.TokenIndex) ?Read {
    const capture = payload_token orelse return null;
    if (tree.tokenTag(capture) == .asterisk) return null;
    return .{ .operand = cond, .capture = capture, .keyword = keyword };
}

fn isNull(tree: *const Ast, node: Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "null");
}

/// `decl` as a `Global`, when its payload is a struct or union the file
/// declares with a field other threads change atomically.
fn heldSync(arena: Allocator, t: Types, decl: Node.Index) Allocator.Error!?Global {
    const tree = t.tree;
    const full = tree.fullVarDecl(decl).?;
    const payload = tree.nodeData(full.ast.type_node.unwrap().?).node;
    const container = t.containerOf(payload, 0) orelse return null;
    const held = try syncField(arena, t, container, 0) orelse return null;
    return .{
        .decl = decl,
        .name = tree.tokenSlice(full.ast.mut_token + 1),
        .field = held.path,
        .field_type = held.type_name,
    };
}

const Held = struct { path: []const u8, type_name: []const u8 };

/// The first field of `container` that other threads change atomically,
/// or, a level down, the first such field of a struct the file declares
/// that one of its fields is.
fn syncField(arena: Allocator, t: Types, container: Node.Index, depth: u8) Allocator.Error!?Held {
    const tree = t.tree;
    var buffer: [2]Node.Index = undefined;
    for (tree.fullContainerDecl(&buffer, container).?.ast.members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        if (field.ast.tuple_like) continue;
        const type_expr = field.ast.type_expr.unwrap() orelse continue;
        const name = tree.tokenSlice(field.ast.main_token);
        if (isSync(t, type_expr, 0)) return .{ .path = name, .type_name = tree.getNodeSource(type_expr) };
        if (depth > 0) continue;
        const inner = t.containerOf(type_expr, 0) orelse continue;
        const held = try syncField(arena, t, inner, depth + 1) orelse continue;
        return .{ .path = try arena.print("{s}.{s}", .{ name, held.path }), .type_name = held.type_name };
    }
    return null;
}

/// Whether `type_expr` is a type other threads change atomically: an
/// `atomic.Value(...)`, one of `lock_names`, one of `std_names` in one of
/// `std_spaces`, an array of one, or a container-level `const` naming one.
fn isSync(t: Types, type_expr: Node.Index, depth: u8) bool {
    const tree = t.tree;
    if (depth > 4) return false;
    switch (tree.nodeTag(type_expr)) {
        .grouped_expression => return isSync(t, tree.nodeData(type_expr).node_and_token[0], depth + 1),
        .array_type, .array_type_sentinel => return isSync(t, tree.fullArrayType(type_expr).?.ast.elem_type, depth + 1),
        .field_access => {
            const lhs, const name_token = tree.nodeData(type_expr).node_and_token;
            const name = tree.tokenSlice(name_token);
            return among(name, &lock_names) or (among(name, &std_names) and among(lastName(tree, lhs), &std_spaces));
        },
        .call_one, .call_one_comma, .call, .call_comma => {
            var buffer: [1]Node.Index = undefined;
            return isValue(t, tree.fullCall(&buffer, type_expr).?.ast.fn_expr, depth + 1);
        },
        .identifier => {
            if (among(tree.tokenSlice(tree.nodeMainToken(type_expr)), &lock_names)) return true;
            return isSync(t, aliasOf(t, type_expr) orelse return false, depth + 1);
        },
        else => return false,
    }
}

/// Whether `fn_expr` is `std.atomic.Value`, as written or through a
/// container-level `const`.
fn isValue(t: Types, fn_expr: Node.Index, depth: u8) bool {
    const tree = t.tree;
    if (depth > 4) return false;
    switch (tree.nodeTag(fn_expr)) {
        .field_access => {
            const lhs, const name = tree.nodeData(fn_expr).node_and_token;
            return std.mem.eql(u8, tree.tokenSlice(name), "Value") and std.mem.eql(u8, lastName(tree, lhs), "atomic");
        },
        .identifier => return isValue(t, aliasOf(t, fn_expr) orelse return false, depth + 1),
        else => return false,
    }
}

/// What the container-level declaration that `use`, an identifier, names
/// is set to: `std.Thread.Mutex` of `const Mutex = std.Thread.Mutex;`.
fn aliasOf(t: Types, use: Node.Index) ?Node.Index {
    const tree = t.tree;
    const decl = declared(t, use, tree.tokenSlice(tree.nodeMainToken(use))) orelse return null;
    return tree.fullVarDecl(decl).?.ast.init_node.unwrap();
}

/// The last name of `node`: `Io` of `std.Io`, `Thread` of `Thread`.
fn lastName(tree: *const Ast, node: Node.Index) []const u8 {
    return switch (tree.nodeTag(node)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
        else => "",
    };
}

fn ungrouped(tree: *const Ast, node: Node.Index) Node.Index {
    var inner = node;
    while (tree.nodeTag(inner) == .grouped_expression) inner = tree.nodeData(inner).node_and_token[0];
    return inner;
}

fn among(name: []const u8, names: []const []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// The one of `globals` that `expr` names: by its name, found in the
/// containers around `expr` as Zig allows no shadowing, or through its
/// container (`S.g`, `@This().g`).
fn globalOf(t: Types, globals: []const Global, expr: Node.Index) ?*const Global {
    const tree = t.tree;
    const operand = ungrouped(tree, expr);
    const decl = switch (tree.nodeTag(operand)) {
        .identifier => declared(t, operand, tree.tokenSlice(tree.nodeMainToken(operand))) orelse return null,
        .field_access => decl: {
            const lhs, const name = tree.nodeData(operand).node_and_token;
            const container = t.containerOf(lhs, 0) orelse return null;
            break :decl types.memberDecl(tree, container, tree.tokenSlice(name)) orelse return null;
        },
        else => return null,
    };
    for (globals) |*g| {
        if (g.decl == decl) return g;
    }
    return null;
}

/// The declaration `name` in the innermost container around `node` that
/// declares it.
fn declared(t: Types, node: Node.Index, name: []const u8) ?Node.Index {
    var around = t.enclosingContainer(node);
    while (around) |container| : (around = t.enclosingContainer(container)) {
        if (types.memberDecl(t.tree, container, name)) |decl| return decl;
    }
    return null;
}

fn add(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding), node: Node.Index, read: Read, g: *const Global) Allocator.Error!void {
    const operand = tree.getNodeSource(read.operand);
    const at, const shown, const hint = if (read.capture) |capture| capture: {
        const name = tree.tokenSlice(capture);
        break :capture .{
            read.operand,
            try arena.print("{s} ({s}) |{s}|", .{ read.keyword, operand, name }),
            try arena.print("capture a pointer, `|*{s}|`, which reads only whether it is null and leaves the payload in place", .{
                if (std.mem.eql(u8, name, "_")) "it" else name,
            }),
        };
    } else .{
        node,
        tree.getNodeSource(node),
        try arena.print("ask through a pointer, `if ({s}) |*it|`, which reads only whether it is null", .{operand}),
    };
    try findings.append(arena, .{
        .offset = tree.tokenStart(tree.firstToken(at)),
        .hint = hint,
        .detail = .{ .race = .{
            .read = shown,
            .global = g.name,
            .field = g.field,
            .field_type = g.field_type,
        } },
    });
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col read: global.field (type)`, in source order.
fn expectRace(source: [:0]const u8, expected: []const u8) !void {
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
        const r = finding.detail.race;
        try out.writer.print("{d}:{d} {s}: {s}.{s} ({s})\n", .{ loc.line + 1, loc.column + 1, r.read, r.global, r.field, r.field_type });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a global optional holding a lock or atomics, asked by value (#170)" {
    try expectRace(
        \\const std = @import("std");
        \\const io_mod = @import("io.zig");
        \\const Value = std.atomic.Value;
        \\const Lock = struct { gpa: std.mem.Allocator, m: std.Io.Mutex };
        \\const Own = struct { m: io_mod.Mutex };
        \\const Called = struct { n: Value(u64) };
        \\const Many = struct { slots: [4]std.atomic.Value(usize) };
        \\const Inner = struct { count: std.atomic.Value(u32) };
        \\const Nested = struct { name: []const u8, inner: Inner };
        \\const Either = union(enum) { lock: std.Io.Condition, none };
        \\const Bare = struct { m: Mutex };
        \\var a: ?Lock = null;
        \\var b: ?Own = null;
        \\var c: ?Called = null;
        \\var d: ?Many = null;
        \\var e: ?Nested = null;
        \\pub var f: ?Either = null;
        \\var h: ?Bare = null;
        \\fn eq() bool { return a == null; }
        \\fn ne() bool { return b != null; }
        \\fn flipped() bool { return null == c; }
        \\fn grouped() bool { return (d) == null; }
        \\fn capture() []const u8 { if (e) |v| return v.name; return ""; }
        \\fn discard() bool { if (f) |_| return true; return false; }
        \\fn loop() void { while (a) |v| { _ = v; break; } }
        \\fn bare() bool { return h == null; }
        \\const S = struct {
        \\    var g: ?Lock = null;
        \\    fn inside() bool { return g == null; }
        \\    fn this() bool { return @This().g != null; }
        \\};
        \\fn qualified() bool { return S.g == null; }
    ,
        \\19:23 a == null: a.m (std.Io.Mutex)
        \\20:23 b != null: b.m (io_mod.Mutex)
        \\21:28 null == c: c.n (Value(u64))
        \\22:28 (d) == null: d.slots ([4]std.atomic.Value(usize))
        \\23:31 if (e) |v|: e.inner.count (std.atomic.Value(u32))
        \\24:25 if (f) |_|: f.lock (std.Io.Condition)
        \\25:25 while (a) |v|: a.m (std.Io.Mutex)
        \\26:25 h == null: h.m (Mutex)
        \\29:31 g == null: g.m (std.Io.Mutex)
        \\30:29 @This().g != null: g.m (std.Io.Mutex)
        \\32:30 S.g == null: g.m (std.Io.Mutex)
        \\
    );
}

test "not reported: a const, a threadlocal, a local, a field, a pointer, no lock in it, a type from elsewhere" {
    try expectRace(
        \\const std = @import("std");
        \\const other = @import("other.zig");
        \\const Lock = struct { m: std.Io.Mutex };
        \\const Plain = struct { name: []const u8, port: u16 };
        \\const Lookalike = struct { e: ui.Event, c: sql.Condition, n: Value(u8), v: other.Value(u8), p: std.Thread.Pool };
        \\const Inner = struct { count: std.atomic.Value(u32) };
        \\const Nested = struct { inner: Inner };
        \\const Deeper = struct { nested: Nested };
        \\const fixed: ?Lock = null;
        \\threadlocal var mine: ?Lock = null;
        \\var plain: ?Plain = null;
        \\var lookalike: ?Lookalike = null;
        \\var deeper: ?Deeper = null;
        \\var elsewhere: ?other.Registry = null;
        \\var pointer: ?*Lock = null;
        \\var lock: Lock = undefined;
        \\var held: ?Lock = null;
        \\const Holder = struct { lock: ?Lock };
        \\const T = struct {
        \\    var plain_too: ?Plain = null;
        \\    fn otherG() bool { return plain_too == null; }
        \\};
        \\fn a() bool { return fixed == null; }
        \\fn b() bool { return mine == null; }
        \\fn c() bool { return plain != null; }
        \\fn d() bool { return lookalike == null; }
        \\fn e() bool { return deeper == null; }
        \\fn f() bool { return elsewhere == null; }
        \\fn g() bool { return pointer == null; }
        \\fn h() bool { var local: ?Lock = null; _ = &local; return local == null; }
        \\fn i(holder: Holder) bool { return holder.lock == null; }
        \\fn j() bool { if (held) |*r| { _ = r; return true; } return false; }
        \\fn k() *Lock { return &held.?; }
        \\fn l(io: std.Io) !void { try held.?.m.lock(io); }
        \\fn m(x: ?Lock) bool { return x == null; }
        \\fn n() bool { const r = held orelse return false; _ = r; return true; }
    , "");
}

test "a name shared by two containers' globals is the nearest one's" {
    try expectRace(
        \\const std = @import("std");
        \\const Lock = struct { m: std.Io.Mutex };
        \\const Plain = struct { n: u8 };
        \\var g: ?Lock = null;
        \\const S = struct {
        \\    var g: ?Plain = null;
        \\    fn inner() bool { return g == null; }
        \\};
        \\fn outer() bool { return g == null; }
    ,
        \\9:26 g == null: g.m (std.Io.Mutex)
        \\
    );
}
