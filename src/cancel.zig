//! Rule three, cancel: in a task's loop, an Io call whose error is dropped
//! with `catch {}` or `catch continue`, which swallows error.Canceled.
//!
//! `std.Io` delivers a cancelation request once: the next cancelation point
//! returns error.Canceled, and later ones succeed (`Io.recancel` re-arms it).
//! A `catch {}` around one in a task's loop takes that error and drops it,
//! so the task runs on, and whoever called `cancel` on it waits for good. It
//! compiles clean in every build mode, and nothing at run time says why.
//!
//! The same `catch {}` in code nothing cancels is harmless, and that is most
//! of it: a first version that looked everywhere made 94 reports over the
//! 0.17.0 lib directory and seven app repos, nearly all in search, cleanup
//! and test loops. What the syntax can see is where a task starts: a
//! function handed to `async` or `concurrent` (`io.concurrent(worker, ...)`,
//! `group.async(io, handle, ...)`). So only such a function, or one it calls
//! directly, in the same file, is looked in, and only its loops. That made
//! two reports over the same code: a real bug, and a test task nothing
//! cancels.
//!
//! An Io call is known by name: one passed `io` or a field named `io`
//! (`self.io`), or called on one (`io.sleep(...)`). Not reported: `cancel`
//! and `await`, which drop the task's own result rather than the caller's
//! cancelation; anything in a `defer` or `errdefer`, where the function is
//! leaving anyway; and handlers that use the error or leave (`catch return`,
//! `catch null`), which only the caller can judge. Whether the callee's
//! error set holds error.Canceled is beyond the syntax; the hint says how to
//! tell.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const report = @import("report.zig");
const Finding = report.Finding;

/// Appends a finding for every Io call whose error is dropped in a task's
/// loop. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings };

    // Where tasks start: every function handed to `async` or `concurrent`.
    var tasks: std.StringHashMapUnmanaged(void) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        const method = calleeName(tree, call.ast.fn_expr) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        if (!std.mem.eql(u8, method, "async") and !std.mem.eql(u8, method, "concurrent")) continue;
        for (call.ast.params) |param| {
            if (calleeName(tree, param)) |name| try tasks.put(arena, name, {});
        }
    }
    if (tasks.count() == 0) return;

    // The file's functions by name, and the ones a task runs: a task's own,
    // and what it calls directly.
    var functions: std.StringHashMapUnmanaged(Node.Index) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]).?;
        try functions.put(arena, tree.tokenSlice(proto.name_token orelse continue), node);
    }
    var run: std.AutoArrayHashMapUnmanaged(Node.Index, void) = .empty;
    var names = tasks.keyIterator();
    while (names.next()) |name| {
        const task = functions.get(name.*) orelse continue;
        try run.put(arena, task, {});
        var called: std.ArrayList([]const u8) = .empty;
        try rule.calls(tree.nodeData(task).node_and_node[1], &called);
        for (called.items) |callee| {
            if (functions.get(callee)) |f| try run.put(arena, f, {});
        }
    }
    for (run.keys()) |function| try rule.walk(tree.nodeData(function).node_and_node[1], false, false);
}

/// `name` or the last name of `a.b.name`.
fn calleeName(tree: *const Ast, node: Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(node)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
        else => null,
    };
}

const hint = "if its error set holds error.Canceled, return that (`catch |err| switch (err) { error.Canceled => |e| return e, else => {} }`), or call `io.recancel()` after handling it";

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),

    /// Reports what `node` drops in a loop and outside a `defer`. Nested
    /// functions and types are not the task's code.
    fn walk(r: *Rule, node: Node.Index, deferred: bool, looping: bool) Allocator.Error!void {
        const tree = r.tree;
        switch (tree.nodeTag(node)) {
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
        const in_defer = deferred or switch (tree.nodeTag(node)) {
            .@"defer", .@"errdefer" => true,
            else => false,
        };
        const in_loop = looping or switch (tree.nodeTag(node)) {
            .while_simple, .while_cont, .@"while", .for_simple, .@"for" => true,
            else => false,
        };
        if (tree.nodeTag(node) == .@"catch" and in_loop and !in_defer) try r.dropped(node);
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, tree, node, &nodes);
        for (nodes.items) |child| try r.walk(child, in_defer, in_loop);
    }

    /// Appends the name of every function `node` calls.
    fn calls(r: *Rule, node: Node.Index, out: *std.ArrayList([]const u8)) Allocator.Error!void {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        if (tree.fullCall(&buffer, node)) |call| {
            if (calleeName(tree, call.ast.fn_expr)) |name| try out.append(r.arena, name);
        }
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, tree, node, &nodes);
        for (nodes.items) |child| try r.calls(child, out);
    }

    /// Reports `lhs catch rhs` when `rhs` drops the error and `lhs` is an
    /// Io call.
    fn dropped(r: *Rule, node: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        const catch_token = tree.nodeMainToken(node);
        // `catch |err|` would not compile with an empty handler; `|_|` does.
        if (tree.tokenTag(catch_token + 1) == .pipe and !std.mem.eql(u8, tree.tokenSlice(catch_token + 2), "_")) return;
        const drops = switch (tree.nodeTag(rhs)) {
            .block_two, .block_two_semicolon => blk: {
                const first, const second = tree.nodeData(rhs).opt_node_and_opt_node;
                break :blk first == .none and second == .none;
            },
            .@"continue" => true,
            else => false,
        };
        if (!drops) return;
        const callee = ioCallee(tree, lhs) orelse return;
        const last = tree.lastToken(rhs);
        const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
        try r.findings.append(r.arena, .{
            .offset = tree.tokenStart(catch_token),
            .hint = hint,
            .detail = .{ .cancel = .{
                .callee = tree.getNodeSource(callee),
                .handler = tree.source[tree.tokenStart(catch_token)..end],
            } },
        });
    }
};

/// The callee of `node` if it is an Io call: passed `io` or a field named
/// `io`, or called on one. Never `cancel` or `await`.
fn ioCallee(tree: *const Ast, node: Node.Index) ?Node.Index {
    if (tree.nodeTag(node) == .grouped_expression) return ioCallee(tree, tree.nodeData(node).node_and_token[0]);
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    const callee = call.ast.fn_expr;
    if (tree.nodeTag(callee) == .field_access) {
        const receiver, const name = tree.nodeData(callee).node_and_token;
        if (std.mem.eql(u8, tree.tokenSlice(name), "cancel") or std.mem.eql(u8, tree.tokenSlice(name), "await")) return null;
        if (namesIo(tree, receiver)) return callee;
    }
    for (call.ast.params) |param| if (namesIo(tree, param)) return callee;
    return null;
}

/// `io`, or a field named `io`.
fn namesIo(tree: *const Ast, node: Node.Index) bool {
    const name = switch (tree.nodeTag(node)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
        else => return false,
    };
    return std.mem.eql(u8, name, "io");
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col callee handler`, in source order.
fn expectDropped(source: [:0]const u8, expected: []const u8) !void {
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
        const c = finding.detail.cancel;
        try out.writer.print("{d}:{d} {s} {s}\n", .{ loc.line + 1, loc.column + 1, c.callee, c.handler });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "in a task's loop, an Io call whose error is dropped" {
    try expectDropped(
        \\fn start(io: Io, g: *Group, s: *S) !void { _ = try io.concurrent(worker, .{io}); g.async(io, Self.write, .{s}); _ = io.async(serve, .{io}); }
        \\fn worker(io: Io) void { while (true) io.sleep(.fromMilliseconds(1), .awake) catch {}; }
        \\fn write(self: *S, line: File, bytes: []const u8) void { while (true) line.writeStreamingAll(self.io, bytes) catch {}; }
        \\fn serve(io: Io, dir: Dir) void { while (true) list(io, dir); }
        \\fn list(io: Io, dir: Dir) void { for (names) |n| { _ = dir.statFile(io, n, .{}) catch continue; (io.sleep(.fromMilliseconds(1), .awake)) catch |_| {}; } }
    ,
        \\2:78 io.sleep catch {}
        \\3:110 line.writeStreamingAll catch {}
        \\5:81 dir.statFile catch continue
        \\5:138 io.sleep catch |_| {}
        \\
    );
}

test "not reported: outside tasks and their loops, cancel and await, defer, handlers that do something" {
    // Nothing here is handed to `async` or `concurrent`, so nothing is a task.
    try expectDropped(
        \\fn worker(io: Io) void { while (true) io.sleep(.fromMilliseconds(1), .awake) catch {}; }
    , "");
    try expectDropped(
        \\fn start(io: Io) !void { _ = try io.concurrent(task, .{io}); }
        \\fn task(io: Io, f: *Future, dir: Dir, list: *List) !void {
        \\    io.sleep(.fromMilliseconds(1), .awake) catch {};
        \\    while (true) {
        \\        _ = f.cancel(io) catch {};
        \\        f.await(io) catch {};
        \\        defer io.sleep(.fromMilliseconds(1), .awake) catch {};
        \\        errdefer dir.deleteTree(io, "x") catch {};
        \\        io.sleep(.fromMilliseconds(1), .awake) catch return;
        \\        io.sleep(.fromMilliseconds(1), .awake) catch |err| return err;
        \\        io.sleep(.fromMilliseconds(1), .awake) catch { log("slept badly"); };
        \\        list.append(gpa, 1) catch {};
        \\        const Inner = struct { fn f(i: Io) void { while (true) i.sleep(.fromMilliseconds(1), .awake) catch {}; } };
        \\        _ = Inner;
        \\    }
        \\}
    , "");
}
