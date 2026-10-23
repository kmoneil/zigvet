//! Rule nine, twice: an errdefer's free also written out by hand on a path
//! that then fails.
//!
//!     const conn = try gpa.create(Conn);
//!     errdefer gpa.destroy(conn);
//!     if (fd < 0) {
//!         gpa.destroy(conn);
//!         return error.BadConfig; // the errdefer destroys conn a second time
//!     }
//!
//! An errdefer runs on every error return in its scope, including one that
//! has already cleaned up by hand, so `conn` is destroyed twice. It compiles
//! clean in every build mode and reads as careful code. Unlike refill and
//! owner it needs no allocation to fail: any input that takes the refusing
//! path frees twice, though such paths (a library refusing a config, a
//! platform call failing) are often ones tests do not reach.
//!
//! What frees is the errdefer's call, one whose name says it releases (a
//! `free`, `destroy`, `deinit`, `close`, `unmap` or `release` of some kind:
//! `gpa.free`, `closeHandle`, `deinitAll`), written again as a statement
//! after it in its block, the same text but for whitespace, not in a
//! `defer` or `errdefer`. It is reported when, after that statement and on
//! its path, the function fails before it leaves another way: a `try`, a
//! `return error.X`, or a `return` of what a `catch` caught.
//!
//! Not reported: the same statement followed by a plain `return`, `break`
//! or `continue`, which is correct, since the errdefer does not run; a
//! failure on another branch; one after a statement that assigns to a name
//! the call is handed or is called on, which then frees something else; a
//! call safe to run twice (`shrinkRetainingCapacity`, a restore); a method
//! of a type the file declares whose body ends by writing its receiver
//! whole with anything but `undefined` (`self.* = .{};`), so the second
//! call frees nothing, the type shown by the receiver's declaration or
//! what made it (`T{ ... }`, `T.init(...)`); a free inside
//! `if (x.len == 0)` for the `x` it is handed, which frees nothing either
//! time; code in a `test` block, where a failure ends the test; and a
//! failure the syntax cannot see, such as `return f()` with no `try`, whose
//! type it does not know.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every errdefer's call also written out by hand on
/// a path that then fails. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var parents: []const Node.OptionalIndex = &.{};
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"errdefer") continue;
        const errdefer_node: Node.Index = @fromBackingInt(@intCast(i));
        var deferred = tree.nodeData(errdefer_node).node;
        // `errdefer { gpa.free(x); }` names one call as well.
        var buffer: [2]Node.Index = undefined;
        if (tree.blockStatements(&buffer, deferred)) |statements| {
            if (statements.len != 1) continue;
            deferred = statements[0];
        }
        var call_buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, deferred) orelse continue;
        if (!releases(tree, call.ast.fn_expr)) continue;
        if (parents.len == 0) parents = (try types.Types.init(arena, tree)).parents;
        if (inTest(tree, parents, errdefer_node)) continue;
        if (resets(.{ .tree = tree, .parents = parents }, call.ast.fn_expr)) continue;
        const block = parents[@backingInt(errdefer_node)].unwrap() orelse continue;
        // What the call is handed: its arguments, and the receiver of a
        // method (`current` of `current.close(io)`).
        var handed: std.ArrayList(Node.Index) = .empty;
        try handed.appendSlice(arena, call.ast.params);
        if (tree.nodeTag(call.ast.fn_expr) == .field_access) try handed.append(arena, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
        const text = try squeeze(arena, tree.getNodeSource(deferred));
        var nodes: std.ArrayList(Node.Index) = .empty;
        try within(arena, tree, block, &nodes);
        for (nodes.items) |node| {
            if (tree.nodeMainToken(node) <= tree.nodeMainToken(errdefer_node)) continue;
            if (!isStatement(tree, parents, node)) continue;
            if (!std.mem.eql(u8, try squeeze(arena, tree.getNodeSource(node)), text)) continue;
            if (onlyWhenEmpty(tree, parents, node, block, handed.items)) continue;
            const point = try failsAfter(arena, tree, parents, node, block, handed.items) orelse continue;
            try findings.append(arena, .{
                .offset = tree.tokenStart(tree.firstToken(node)),
                .hint = hint,
                .detail = .{ .twice = .{
                    .call = tree.getNodeSource(node),
                    .fails = try what(arena, tree, point),
                } },
            });
            break;
        }
    }
}

const hint = "the errdefer above runs again when this path fails; drop this one and let the errdefer do it";

/// Whether the function `fn_expr` names releases what it is handed, by its
/// name: a `free`, `destroy`, `deinit`, `close`, `unmap` or `release` of
/// some kind (`gpa.free`, `closeHandle`, `deinitAll`). A call run twice
/// that is safe to run twice, such as `shrinkRetainingCapacity` or a
/// restore, is no bug.
fn releases(tree: *const Ast, fn_expr: Node.Index) bool {
    const name = switch (tree.nodeTag(fn_expr)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(fn_expr)),
        .field_access => tree.tokenSlice(tree.nodeData(fn_expr).node_and_token[1]),
        else => return false,
    };
    var lower: [64]u8 = undefined;
    if (name.len > lower.len) return false;
    const folded = std.ascii.lowerString(&lower, name);
    for ([_][]const u8{ "free", "destroy", "deinit", "close", "unmap", "release" }) |word| {
        if (std.mem.indexOf(u8, folded, word) != null) return true;
    }
    return false;
}

/// Whether the call `fn_expr` names is a method of a type the file declares
/// whose body ends by writing its receiver whole with anything but
/// `undefined` (`self.* = .{};`), so a second call finds nothing to free.
fn resets(t: types.Types, fn_expr: Node.Index) bool {
    const tree = t.tree;
    const fn_decl = method(t, fn_expr) orelse return false;
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
    var params = proto.iterate(tree);
    const receiver = (params.next() orelse return false).name_token orelse return false;
    var block: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&block, tree.nodeData(fn_decl).node_and_node[1]) orelse return false;
    if (statements.len == 0) return false;
    const last = statements[statements.len - 1];
    if (tree.nodeTag(last) != .assign) return false;
    const lhs, const rhs = tree.nodeData(last).node_and_node;
    if (tree.nodeTag(lhs) != .deref) return false;
    const target = tree.nodeData(lhs).node;
    if (tree.nodeTag(target) != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), tree.tokenSlice(receiver))) return false;
    return tree.nodeTag(rhs) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(rhs)), "undefined");
}

/// The file's own function a method call's `fn_expr` names: as
/// `types.callee` finds it, or through the type that made a local
/// receiver (`T{ ... }`, `T.init(...)`).
fn method(t: types.Types, fn_expr: Node.Index) ?Node.Index {
    const tree = t.tree;
    if (tree.nodeTag(fn_expr) != .field_access) return null;
    if (t.callee(fn_expr)) |found| return found[0];
    const receiver, const name = tree.nodeData(fn_expr).node_and_token;
    if (tree.nodeTag(receiver) != .identifier) return null;
    const type_expr = madeType(tree, t.localInit(receiver) orelse return null) orelse return null;
    const container = t.containerOf(type_expr, 0) orelse return null;
    return types.memberFn(tree, container, tree.tokenSlice(name));
}

/// The type an initializer makes, as written: `T` of `T{ ... }`, or of
/// `T.init(...)` or another `T.init...`, through a `try`.
fn madeType(tree: *const Ast, init: Node.Index) ?Node.Index {
    const made = if (tree.nodeTag(init) == .@"try") tree.nodeData(init).node else init;
    var buffer: [2]Node.Index = undefined;
    if (tree.fullStructInit(&buffer, made)) |full| return full.ast.type_expr.unwrap();
    var call_buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, made) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const type_expr, const name = tree.nodeData(call.ast.fn_expr).node_and_token;
    if (!std.mem.startsWith(u8, tree.tokenSlice(name), "init")) return null;
    return type_expr;
}

/// Whether `node` is the body, or in the body, of an `if (x.len == 0)`
/// inside `block`, with `x` among `handed`: a free of an empty slice frees
/// nothing.
fn onlyWhenEmpty(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index, block: Node.Index, handed: []const Node.Index) bool {
    var child = node;
    var up = parents[@backingInt(node)].unwrap();
    while (up) |parent| : ({
        child = parent;
        up = parents[@backingInt(parent)].unwrap();
    }) {
        if (parent == block) return false;
        const full = tree.fullIf(parent) orelse continue;
        if (full.ast.then_expr != child) continue;
        const condition = full.ast.cond_expr;
        if (tree.nodeTag(condition) != .equal_equal) continue;
        const lhs, const rhs = tree.nodeData(condition).node_and_node;
        if (tree.nodeTag(rhs) != .number_literal or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(rhs)), "0")) continue;
        if (tree.nodeTag(lhs) != .field_access) continue;
        const of, const field = tree.nodeData(lhs).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(field), "len")) continue;
        for (handed) |argument| {
            if (std.mem.eql(u8, tree.getNodeSource(argument), tree.getNodeSource(of))) return true;
        }
    }
    return false;
}

/// Whether `node` is in a `test` block, where a failure ends the test.
fn inTest(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) bool {
    var up = parents[@backingInt(node)].unwrap();
    while (up) |parent| : (up = parents[@backingInt(parent)].unwrap()) {
        switch (tree.nodeTag(parent)) {
            .test_decl => return true,
            .fn_decl => return false,
            else => {},
        }
    }
    return false;
}

/// `text` without whitespace, so `gpa.free( x )` and `gpa.free(x)` match.
fn squeeze(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| if (!std.ascii.isWhitespace(c)) try out.append(arena, c);
    return out.items;
}

/// Whether `node` is a statement of a block.
fn isStatement(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) bool {
    const parent = parents[@backingInt(node)].unwrap() orelse return false;
    var buffer: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, parent) orelse {
        // The body of an `if` or a loop with no block: `if (bad) gpa.free(x);`.
        return switch (tree.nodeTag(parent)) {
            .if_simple, .@"if" => tree.fullIf(parent).?.ast.then_expr == node,
            else => false,
        };
    };
    return std.mem.findScalar(Node.Index, statements, node) != null;
}

/// The first thing after `statement`, on its path, before `block` ends,
/// that makes the function fail. Null if the path leaves another way
/// first, or a statement between assigns to one of `handed`, the names the
/// call is handed.
fn failsAfter(arena: Allocator, tree: *const Ast, parents: []const Node.OptionalIndex, statement: Node.Index, block: Node.Index, handed: []const Node.Index) Allocator.Error!?Node.Index {
    var child = statement;
    var up = parents[@backingInt(statement)].unwrap();
    while (up) |parent| : ({
        child = parent;
        up = parents[@backingInt(parent)].unwrap();
    }) {
        switch (tree.nodeTag(parent)) {
            .fn_decl, .test_decl => return null,
            else => {},
        }
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, parent) orelse continue;
        const at = std.mem.findScalar(Node.Index, statements, child) orelse return null;
        for (statements[at + 1 ..]) |next| {
            switch (tree.nodeTag(next)) {
                .@"defer", .@"errdefer" => continue,
                else => {},
            }
            if (try reassigns(arena, tree, next, handed)) return null;
            if (try failing(arena, tree, parents, next)) |point| return point;
            switch (tree.nodeTag(next)) {
                .@"return", .@"break", .@"continue" => return null,
                else => {},
            }
        }
        if (parent == block) return null;
    }
    return null;
}

/// Whether `node` assigns to a name among `handed`.
fn reassigns(arena: Allocator, tree: *const Ast, node: Node.Index, handed: []const Node.Index) Allocator.Error!bool {
    var nodes: std.ArrayList(Node.Index) = .empty;
    try within(arena, tree, node, &nodes);
    for (nodes.items) |n| {
        if (tree.nodeTag(n) != .assign) continue;
        const root = kept.rootOf(tree, tree.nodeData(n).node_and_node[0]) orelse continue;
        const name = tree.tokenSlice(tree.nodeMainToken(root));
        for (handed) |argument| {
            const handed_root = kept.rootOf(tree, argument) orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(handed_root)), name)) return true;
        }
    }
    return false;
}

/// The first node of `statement` that makes the function fail: a `try`, a
/// `return error.X`, or a `return` of what a `catch` around it caught.
fn failing(arena: Allocator, tree: *const Ast, parents: []const Node.OptionalIndex, statement: Node.Index) Allocator.Error!?Node.Index {
    var nodes: std.ArrayList(Node.Index) = .empty;
    try within(arena, tree, statement, &nodes);
    var first: ?Node.Index = null;
    for (nodes.items) |node| {
        const fails = switch (tree.nodeTag(node)) {
            .@"try" => true,
            .@"return" => returnsError(tree, parents, node),
            else => false,
        };
        if (!fails) continue;
        if (first == null or tree.nodeMainToken(node) < tree.nodeMainToken(first.?)) first = node;
    }
    return first;
}

/// Whether `node`, a `return`, returns an error: `error.X`, or what the
/// `catch |err|` around it caught.
fn returnsError(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) bool {
    const value = tree.nodeData(node).opt_node.unwrap() orelse return false;
    if (tree.nodeTag(value) == .error_value) return true;
    if (tree.nodeTag(value) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(value));
    var up = parents[@backingInt(node)].unwrap();
    while (up) |parent| : (up = parents[@backingInt(parent)].unwrap()) {
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

/// What fails at `point`, as the message says it: `it returns error.Busy`,
/// or `self.spawn fails`.
fn what(arena: Allocator, tree: *const Ast, point: Node.Index) Allocator.Error![]const u8 {
    if (tree.nodeTag(point) == .@"return") {
        return arena.print("it returns {s}", .{tree.getNodeSource(tree.nodeData(point).opt_node.unwrap().?)});
    }
    var operand = tree.nodeData(point).node;
    while (tree.nodeTag(operand) == .grouped_expression) operand = tree.nodeData(operand).node_and_token[0];
    var buffer: [1]Node.Index = undefined;
    const failing_expr = if (tree.fullCall(&buffer, operand)) |call| call.ast.fn_expr else operand;
    return arena.print("{s} fails", .{tree.getNodeSource(failing_expr)});
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
/// `line:col call <- what fails`, in source order.
fn expectTwice(source: [:0]const u8, expected: []const u8) !void {
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
        const t = finding.detail.twice;
        try out.writer.print("{d}:{d} {s} <- {s}\n", .{ loc.line + 1, loc.column + 1, t.call, t.fails });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "an errdefer's free written out by hand on a path that then fails (#61)" {
    try expectTwice(
        \\fn open(gpa: Allocator, fd: i32) !*Conn { const conn = try gpa.create(Conn); errdefer gpa.destroy(conn); if (fd < 0) { gpa.destroy(conn); return error.BadConfig; } return conn; }
        \\fn map(handle: Handle, size: usize) !*Header { errdefer platform.closeHandle(handle, true); const base = try platform.map(handle, size); errdefer platform.unmap(base, size); if (!commit(base)) { platform.unmap(base, size); platform.closeHandle(handle, true); return error.OutOfMemory; } return @ptrCast(base); }
        \\fn caught(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); use(b) catch |err| { gpa.free(b); return err; }; }
        \\fn tried(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); if (b.len == 4) { gpa.free(b); try report(); } }
        \\fn spaced(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free( b ); if (bad()) { gpa.free(b); return error.Bad; } }
        \\fn bare(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); if (bad()) gpa.free(b); try more(); }
    ,
        \\1:120 gpa.destroy(conn) <- it returns error.BadConfig
        \\2:196 platform.unmap(base, size) <- it returns error.OutOfMemory
        \\2:224 platform.closeHandle(handle, true) <- it returns error.OutOfMemory
        \\3:110 gpa.free(b) <- it returns err
        \\4:106 gpa.free(b) <- report fails
        \\5:104 gpa.free(b) <- it returns error.Bad
        \\6:98 gpa.free(b) <- more fails
        \\
    );
}

test "not reported: a plain return after it, another branch, a name assigned again, nothing after" {
    try expectTwice(
        \\fn plain(gpa: Allocator) !?*Conn { const conn = try gpa.create(Conn); errdefer gpa.destroy(conn); if (bad()) { gpa.destroy(conn); return null; } return conn; }
        \\fn other(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); if (bad()) { gpa.free(b); return; } else return error.Bad; }
        \\fn again(gpa: Allocator) !void { var b = try gpa.alloc(u8, 4); errdefer gpa.free(b); gpa.free(b); b = try gpa.alloc(u8, 8); try more(); }
        \\fn looped(gpa: Allocator, items: []Item) !void { for (items) |it| { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); if (it.skip) { gpa.free(b); continue; } try keep(b); } }
        \\fn deferred(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); defer gpa.free(b); try more(); }
        \\fn idempotent(list: *List, n: usize) !void { errdefer list.shrinkRetainingCapacity(n); list.shrinkRetainingCapacity(n); try list.ensureUnusedCapacity(gpa, 1); }
        \\fn receiver(io: Io, dir: Dir, next: Dir) !void { var current = dir; errdefer current.close(io); current.close(io); current = next; try current.stat(io); }
        \\test "a test" { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); gpa.free(b); try expect(false); }
    , "");
}

test "a deinit that resets its receiver, and a free of an empty slice, run twice safely (#87)" {
    try expectTwice(
        \\const Builder = struct {
        \\    items: []u8 = &.{},
        \\    fn init(gpa: Allocator) !Builder { return .{ .items = try gpa.alloc(u8, 4) }; }
        \\    fn deinit(self: *Builder, gpa: Allocator) void { gpa.free(self.items); self.* = .{}; }
        \\    fn deinitAll(self: *Builder, gpa: Allocator) void { gpa.free(self.items); self.* = Builder.init(gpa) catch .{}; }
        \\    fn release(self: *Builder, gpa: Allocator) void { gpa.free(self.items); self.* = undefined; }
        \\};
        \\fn annotated(gpa: Allocator, fail: bool) !void { var b: Builder = .{ .items = try gpa.alloc(u8, 4) }; errdefer b.deinit(gpa); b.deinit(gpa); if (fail) return error.Failed; }
        \\fn literal(gpa: Allocator, fail: bool) !void { var b = Builder{ .items = try gpa.alloc(u8, 4) }; errdefer b.deinit(gpa); b.deinit(gpa); if (fail) return error.Failed; }
        \\fn made(gpa: Allocator, fail: bool) !void { var b = try Builder.init(gpa); errdefer b.deinitAll(gpa); b.deinitAll(gpa); if (fail) return error.Failed; }
        \\fn undef(gpa: Allocator, fail: bool) !void { var b = try Builder.init(gpa); errdefer b.release(gpa); b.release(gpa); if (fail) return error.Failed; }
        \\fn elsewhere(gpa: Allocator, fail: bool) !void { var b = other.Builder{}; errdefer b.deinit(gpa); b.deinit(gpa); if (fail) return error.Failed; }
        \\fn empty(gpa: Allocator, components: []u8, fail: bool) !void { errdefer gpa.free(components); if (components.len == 0) { gpa.free(components); if (fail) return error.Failed; return; } gpa.free(components); }
        \\fn nonEmpty(gpa: Allocator, components: []u8, fail: bool) !void { errdefer gpa.free(components); if (components.len != 0) { gpa.free(components); if (fail) return error.Failed; return; } }
    ,
        \\11:102 b.release(gpa) <- it returns error.Failed
        \\12:99 b.deinit(gpa) <- it returns error.Failed
        \\14:125 gpa.free(components) <- it returns error.Failed
        \\
    );
}
