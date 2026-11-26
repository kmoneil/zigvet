//! Rule twenty-nine, handed: an `errdefer` that frees a local, still armed
//! after a call has handed the local to a value whose own errdefer'd
//! release frees it.
//!
//!     const url = try gpa.dupe(u8, href);
//!     errdefer gpa.free(url);
//!     const p = try Pending.make(gpa, url);
//!     errdefer p.destroy();
//!     try more();
//!
//! Once `Pending.make` has stored `url` in `p.url`, `p.destroy()` frees it.
//! If anything after fails, both errdefers run, and `url` is freed twice.
//! Each errdefer is right where it stands: the first covers `make`
//! failing, the second the steps after it. The bug is that the first stays
//! armed after the hand-over. It is not owner, where the callee frees what
//! it is handed when it fails, and not twice, where a release is written
//! out by hand: here both releases are the caller's errdefers (#225).
//!
//! What is reported is an `errdefer` that frees a name, as kept reads one
//! (`x.free(name)`, `x.destroy(name)`, `name.deinit(...)`), followed in its
//! block by a declaration made by a call that is handed the name as an
//! argument (`const p = try Pending.make(gpa, url);`), where the call is a
//! function of the file that stores that parameter in a field
//! (`.{ .url = url }`, `p.url = url`); then, in the same block, an
//! `errdefer` that releases what the declaration made through a function
//! of the file (`p.destroy()`, `Pending.destroy(p)`) that frees that field
//! of it (`p.gpa.free(p.url)`); and then, with both armed, something that
//! makes the function fail.
//!
//! Not reported: the first errdefer scoped to the hand-over, the fix
//! (`const p = blk: { errdefer gpa.free(url); break :blk try
//! Pending.make(gpa, url); };`); a call that copies the name rather than
//! storing it; a release that frees another field, or only the value
//! itself; a name assigned anew before the failure; a call or a release
//! the file does not declare; and nothing that fails after the second
//! errdefer.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
const kept = @import("kept.zig");
const refill = @import("refill.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every errdefer still armed after a call has
/// handed what it frees to a value an errdefer after it releases.
/// Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"errdefer") continue;
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const name = kept.freedName(tree, tree.nodeData(node).node) orelse continue;
        try rule.freed(node, name);
    }
}

/// A local handed to a call that stores it, and what the call made.
const Handover = struct {
    /// The declaration: `const p = try Pending.make(gpa, url);`.
    statement: Node.Index,
    /// What it declares: `p`.
    made: []const u8,
    /// The call, as written: `Pending.make`.
    callee: []const u8,
    /// The fields the call stores the local in.
    fields: []const []const u8,
};

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),
    /// Made at the first errdefer that frees a name.
    types: ?types.Types = null,

    /// Reports `errdefer_node`, which frees `name`, if a statement after it
    /// in its block hands `name` to a value that an errdefer after that
    /// releases, with the field it is stored in, and something fails with
    /// both armed.
    fn freed(r: *Rule, errdefer_node: Node.Index, name: []const u8) Allocator.Error!void {
        const tree = r.tree;
        if (r.types == null) r.types = try .init(r.arena, tree);
        const t = r.types.?;
        const block = t.parents[@backingInt(errdefer_node)].unwrap() orelse return;
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse return;
        const at = std.mem.findScalar(Node.Index, statements, errdefer_node) orelse return;
        for (statements[at + 1 ..], at + 1..) |statement, index| {
            if (assigns(tree, statement, name)) return;
            const handover = try r.handedOver(statement, name) orelse continue;
            for (statements[index + 1 ..], index + 1..) |later, later_index| {
                if (assigns(tree, later, name)) return;
                if (tree.nodeTag(later) != .@"errdefer") continue;
                const release = try r.releases(tree.nodeData(later).node, handover) orelse continue;
                const point = try r.failsAfter(statements[later_index + 1 ..], later, name) orelse return;
                return r.findings.append(r.arena, .{
                    .offset = tree.tokenStart(tree.nodeMainToken(errdefer_node)),
                    .hint = try r.arena.print("scope this errdefer to the call that takes '{s}': `const {s} = blk: {{ errdefer ...; break :blk try {s}(...); }};`", .{ name, handover.made, handover.callee }),
                    .detail = .{ .handed = .{
                        .name = name,
                        .callee = handover.callee,
                        .release = release,
                        .fails = try kept.failureText(r.arena, tree, t.parents, point),
                    } },
                });
            }
            return;
        }
    }

    /// `statement` as a declaration made by a call of the file's own that
    /// is handed `name` and stores it in a field.
    fn handedOver(r: *Rule, statement: Node.Index, name: []const u8) Allocator.Error!?Handover {
        const tree = r.tree;
        const decl = tree.fullVarDecl(statement) orelse return null;
        var value = decl.ast.init_node.unwrap() orelse return null;
        switch (tree.nodeTag(value)) {
            .@"try" => value = tree.nodeData(value).node,
            .@"catch" => value = tree.nodeData(value).node_and_node[0],
            else => {},
        }
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, value) orelse return null;
        const argument = for (call.ast.params, 0..) |param, i| {
            if (isName(tree, param, name)) break i;
        } else return null;
        const fn_decl, const offset = r.types.?.callee(call.ast.fn_expr) orelse return null;
        const param = paramName(tree, fn_decl, argument + offset) orelse return null;
        const fields = try r.storedIn(fn_decl, param);
        if (fields.len == 0) return null;
        return .{
            .statement = statement,
            .made = tree.tokenSlice(decl.ast.mut_token + 1),
            .callee = tree.getNodeSource(call.ast.fn_expr),
            .fields = fields,
        };
    }

    /// The fields `fn_decl` stores its parameter `param` in: a field of an
    /// initializer (`.{ .url = url }`), or one assigned to (`p.url = url`).
    fn storedIn(r: *Rule, fn_decl: Node.Index, param: []const u8) Allocator.Error![]const []const u8 {
        const tree = r.tree;
        var fields: std.ArrayList([]const u8) = .empty;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try within(r.arena, tree, tree.nodeData(fn_decl).node_and_node[1], &nodes);
        for (nodes.items) |node| {
            var buffer: [2]Node.Index = undefined;
            if (tree.fullStructInit(&buffer, node)) |init| {
                for (init.ast.fields) |field| {
                    if (isName(tree, field, param)) try fields.append(r.arena, tree.tokenSlice(tree.firstToken(field) - 2));
                }
                continue;
            }
            if (tree.nodeTag(node) != .assign) continue;
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            if (tree.nodeTag(lhs) != .field_access or !isName(tree, rhs, param)) continue;
            try fields.append(r.arena, tree.tokenSlice(tree.nodeData(lhs).node_and_token[1]));
        }
        return fields.items;
    }

    /// The release `deferred`, an errdefer's, makes of what `handover`
    /// made, as written (`p.destroy`), when it is a function of the file
    /// that frees one of the fields the call stored the name in.
    fn releases(r: *Rule, deferred: Node.Index, handover: Handover) Allocator.Error!?[]const u8 {
        const tree = r.tree;
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, deferred) orelse (&deferred)[0..1];
        for (statements) |statement| {
            var call_buffer: [1]Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, statement) orelse continue;
            const fn_decl, const offset = r.types.?.callee(call.ast.fn_expr) orelse continue;
            // What was made, as the receiver or an argument.
            const index = if (offset == 1 and isName(tree, tree.nodeData(call.ast.fn_expr).node_and_token[0], handover.made))
                0
            else for (call.ast.params, 0..) |param, i| {
                if (isName(tree, param, handover.made)) break i + offset;
            } else continue;
            const param = paramName(tree, fn_decl, index) orelse continue;
            if (try r.freesField(fn_decl, param, handover.fields)) return tree.getNodeSource(call.ast.fn_expr);
        }
        return null;
    }

    /// Whether `fn_decl` frees one of `fields` of its parameter `param`:
    /// `p.gpa.free(p.url)`, `p.list.deinit(gpa)`.
    fn freesField(r: *Rule, fn_decl: Node.Index, param: []const u8, fields: []const []const u8) Allocator.Error!bool {
        const tree = r.tree;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try within(r.arena, tree, tree.nodeData(fn_decl).node_and_node[1], &nodes);
        for (nodes.items) |node| {
            _, const operand = refill.releaseCall(tree, node) orelse continue;
            if (tree.nodeTag(operand) != .field_access) continue;
            const lhs, const field = tree.nodeData(operand).node_and_token;
            if (!isName(tree, lhs, param)) continue;
            for (fields) |stored| if (std.mem.eql(u8, tree.tokenSlice(field), stored)) return true;
        }
        return false;
    }

    /// The first thing in `statements`, which follow the errdefer
    /// `armed_node` in its block, that makes the function fail. Null when
    /// a statement leaves the block first, or assigns `name` anew.
    fn failsAfter(r: *Rule, statements: []const Node.Index, armed_node: Node.Index, name: []const u8) Allocator.Error!?Node.Index {
        const tree = r.tree;
        const armed = tree.nodeMainToken(armed_node);
        for (statements) |statement| {
            if (assigns(tree, statement, name)) return null;
            if (try kept.failure(r.arena, tree, r.types.?.parents, statement, armed)) |point| return point;
            switch (tree.nodeTag(statement)) {
                .@"return", .@"break", .@"continue" => return null,
                else => {},
            }
        }
        return null;
    }
};

/// Whether `statement` assigns `name` anew.
fn assigns(tree: *const Ast, statement: Node.Index, name: []const u8) bool {
    return tree.nodeTag(statement) == .assign and isName(tree, tree.nodeData(statement).node_and_node[0], name);
}

/// The name of `fn_decl`'s parameter at `index`.
fn paramName(tree: *const Ast, fn_decl: Node.Index, index: usize) ?[]const u8 {
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
    var params = proto.iterate(tree);
    var i: usize = 0;
    while (params.next()) |param| : (i += 1) {
        if (i == index) return tree.tokenSlice(param.name_token orelse return null);
    }
    return null;
}

/// Appends `node` and every node under it, but not what nested functions
/// and types hold.
fn within(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    if (kept.isNested(tree.nodeTag(node))) return;
    try out.append(arena, node);
    var nodes: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, node, &nodes);
    for (nodes.items) |child| try within(arena, tree, child, out);
}

fn isName(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col name callee release <- what fails`, in source order.
fn expectHanded(source: [:0]const u8, expected: []const u8) !void {
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
        const h = finding.detail.handed;
        try out.writer.print("{d}:{d} {s} {s} {s} <- {s}\n", .{ loc.line + 1, loc.column + 1, h.name, h.callee, h.release, h.fails });
    }
    try expect.findings(@src(), expected, out.written());
}

const pending =
    \\const Pending = struct {
    \\    gpa: Allocator,
    \\    url: []u8,
    \\    name: []u8 = &.{},
    \\    fn make(gpa: Allocator, url: []u8) !*Pending { const p = try gpa.create(Pending); p.* = .{ .gpa = gpa, .url = url }; return p; }
    \\    fn set(gpa: Allocator, url: []u8) !*Pending { const p = try gpa.create(Pending); p.gpa = gpa; p.url = url; return p; }
    \\    fn copied(gpa: Allocator, url: []u8) !*Pending { const p = try gpa.create(Pending); p.* = .{ .gpa = gpa, .url = try gpa.dupe(u8, url) }; return p; }
    \\    fn value(gpa: Allocator, url: []u8) Pending { return .{ .gpa = gpa, .url = url }; }
    \\    fn destroy(p: *Pending) void { p.gpa.free(p.url); p.gpa.destroy(p); }
    \\    fn deinit(p: *Pending) void { p.gpa.free(p.url); }
    \\    fn drop(p: *Pending) void { p.gpa.free(p.name); p.gpa.destroy(p); }
    \\};
    \\fn release(p: *Pending) void { p.gpa.free(p.url); p.gpa.destroy(p); }
    \\fn freeOther(p: *Pending, o: *Pending) void { _ = p; o.gpa.free(o.url); }
    \\
;

test "an errdefer still armed after a call hands what it frees to a value an errdefer releases (#225)" {
    try expectHanded(pending ++
        \\fn a(gpa: Allocator, href: []const u8) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.make(gpa, url); errdefer p.destroy(); gpa.free(try gpa.alloc(u8, 1)); return p; }
        \\fn b(gpa: Allocator, href: []const u8) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.set(gpa, url); errdefer release(p); if (href.len == 0) return error.Empty; return p; }
        \\fn c(gpa: Allocator, href: []const u8) !Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); var p = Pending.value(gpa, url); errdefer p.deinit(); try more(); return p; }
        \\fn d(gpa: Allocator, href: []const u8) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.make(gpa, url); errdefer { p.destroy(); } try more(); return p; }
    ,
        \\15:88 url Pending.make p.destroy <- gpa.alloc fails
        \\16:88 url Pending.set release <- it returns error.Empty
        \\17:87 url Pending.value p.deinit <- more fails
        \\18:88 url Pending.make p.destroy <- more fails
        \\
    );
}

test "not reported: scoped to the hand-over, a copy, another field, assigned anew, nothing after, not the file's" {
    try expectHanded(pending ++
        \\fn scoped(gpa: Allocator, href: []const u8) !*Pending { const url = try gpa.dupe(u8, href); const p = blk: { errdefer gpa.free(url); break :blk try Pending.make(gpa, url); }; errdefer p.destroy(); try more(); return p; }
        \\fn copy(gpa: Allocator, href: []const u8) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.copied(gpa, url); errdefer p.destroy(); try more(); return p; }
        \\fn other(gpa: Allocator, href: []const u8) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.make(gpa, url); errdefer p.drop(); try more(); return p; }
        \\fn last(gpa: Allocator, href: []const u8) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.make(gpa, url); errdefer p.destroy(); return p; }
        \\fn before(gpa: Allocator, href: []const u8) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.make(gpa, url); try more(); errdefer p.destroy(); return p; }
        \\fn elsewhere(gpa: Allocator, href: []const u8) !*Other { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Other.make(gpa, url); errdefer p.destroy(); try more(); return p; }
        \\fn anew(gpa: Allocator, href: []const u8) !*Pending { var url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.make(gpa, url); errdefer p.destroy(); url = try gpa.dupe(u8, href); try more(); return p; }
        \\fn gone(gpa: Allocator, href: []const u8) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.make(gpa, url); errdefer gpa.destroy(p); try more(); return p; }
        \\fn another(gpa: Allocator, href: []const u8, keep: *Pending) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.make(gpa, url); errdefer keep.destroy(); try more(); return p; }
        \\fn theirs(gpa: Allocator, href: []const u8, keep: *Pending) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.make(gpa, url); errdefer freeOther(p, keep); try more(); return p; }
    , "");
}

test "the message and the hint" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, pending ++
        \\fn a(gpa: Allocator, href: []const u8) !*Pending { const url = try gpa.dupe(u8, href); errdefer gpa.free(url); const p = try Pending.make(gpa, url); errdefer p.destroy(); try more(); return p; }
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
        \\`url` freed here if more fails, and again by the errdefer's p.destroy, since Pending.make stored it in what p.destroy frees
        \\scope this errdefer to the call that takes 'url': `const p = blk: { errdefer ...; break :blk try Pending.make(...); };`
        \\
    , out.written());
}
