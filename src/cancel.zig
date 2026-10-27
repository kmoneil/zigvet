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
//!
//! A function a task calls inside one of its loops is where a handler that
//! leaves can drop it too: `catch |err| { if (err == error.Canceled) return;
//! ... }`, or a `switch (err)` prong `error.Canceled => return` or `=> {}`.
//! Leaving that function returns to the task's loop, which goes on with the
//! cancel spent, and naming the error shows the call can return it. Not
//! reported: a handler that calls `recancel`, returns a value, which the
//! loop may read (`while (tick())`), or hands the error on
//! (`error.Canceled => |e| return e`); and the same handler in the task's
//! own function, where returning ends the task.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
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

    // What a task calls inside one of its loops, and the first task found
    // to: a handler there that leaves on error.Canceled lets the loop go on.
    var looped: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    names = tasks.keyIterator();
    while (names.next()) |name| {
        const task = functions.get(name.*) orelse continue;
        var called: std.ArrayList([]const u8) = .empty;
        try rule.loopCalls(tree.nodeData(task).node_and_node[1], false, &called);
        for (called.items) |callee| {
            if (tasks.contains(callee) or !functions.contains(callee)) continue;
            const gop = try looped.getOrPut(arena, callee);
            if (!gop.found_existing) gop.value_ptr.* = name.*;
        }
    }
    for (looped.keys(), looped.values()) |callee, task| {
        try rule.spent(tree.nodeData(functions.get(callee).?).node_and_node[1], false, callee, task);
    }
}

fn isLoop(tag: Node.Tag) bool {
    return switch (tag) {
        .while_simple, .while_cont, .@"while", .for_simple, .@"for" => true,
        else => false,
    };
}

/// A nested function or type, which is not the code around it.
fn isNested(tag: Node.Tag) bool {
    return switch (tag) {
        .fn_decl,
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => true,
        else => false,
    };
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
        if (isNested(tree.nodeTag(node))) return;
        const in_defer = deferred or switch (tree.nodeTag(node)) {
            .@"defer", .@"errdefer" => true,
            else => false,
        };
        const in_loop = looping or isLoop(tree.nodeTag(node));
        if (tree.nodeTag(node) == .@"catch" and in_loop and !in_defer) try r.dropped(node);
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, tree, node, &nodes);
        for (nodes.items) |child| try r.walk(child, in_defer, in_loop);
    }

    /// Appends the name of every function `node` calls inside a loop.
    fn loopCalls(r: *Rule, node: Node.Index, looping: bool, out: *std.ArrayList([]const u8)) Allocator.Error!void {
        const tree = r.tree;
        if (isNested(tree.nodeTag(node))) return;
        const in_loop = looping or isLoop(tree.nodeTag(node));
        var buffer: [1]Node.Index = undefined;
        if (in_loop) if (tree.fullCall(&buffer, node)) |call| {
            if (calleeName(tree, call.ast.fn_expr)) |name| try out.append(r.arena, name);
        };
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, tree, node, &nodes);
        for (nodes.items) |child| try r.loopCalls(child, in_loop, out);
    }

    /// Reports, in `node`, of `callee`, which the loop in `task` calls, each
    /// handler that names error.Canceled and leaves without it, outside a
    /// `defer`.
    fn spent(r: *Rule, node: Node.Index, deferred: bool, callee: []const u8, task: []const u8) Allocator.Error!void {
        const tree = r.tree;
        if (isNested(tree.nodeTag(node))) return;
        const in_defer = deferred or switch (tree.nodeTag(node)) {
            .@"defer", .@"errdefer" => true,
            else => false,
        };
        if (tree.nodeTag(node) == .@"catch" and !in_defer) if (leavesOnCanceled(tree, node)) |at| {
            var lhs = tree.nodeData(node).node_and_node[0];
            while (tree.nodeTag(lhs) == .grouped_expression) lhs = tree.nodeData(lhs).node_and_token[0];
            var buffer: [1]Node.Index = undefined;
            const call = if (tree.fullCall(&buffer, lhs)) |c| c.ast.fn_expr else lhs;
            try r.findings.append(r.arena, .{
                .offset = tree.tokenStart(tree.firstToken(at)),
                .hint = try r.arena.print("{s} returns to the loop in {s}, which goes on with the cancel spent; return error.Canceled from {s} and `try` it in the loop, or call `io.recancel()`", .{ callee, task, callee }),
                .detail = .{ .cancel = .{
                    .callee = tree.getNodeSource(call),
                    .handler = try handlerText(r.arena, tree, at),
                } },
            });
        };
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, tree, node, &nodes);
        for (nodes.items) |child| try r.spent(child, in_defer, callee, task);
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

/// In `lhs catch |err| handler`, the part of the handler that names
/// error.Canceled and leaves without it: `if (err == error.Canceled)
/// return`, or a `switch (err)` prong `error.Canceled => return` or
/// `=> {}`, as the handler or one of its statements. Null when the handler
/// calls `recancel`, which arms the cancel again.
fn leavesOnCanceled(tree: *const Ast, node: Node.Index) ?Node.Index {
    const catch_token = tree.nodeMainToken(node);
    if (tree.tokenTag(catch_token + 1) != .pipe) return null;
    const capture = tree.tokenSlice(catch_token + 2);
    const handler = tree.nodeData(node).node_and_node[1];
    for (tree.firstToken(handler)..tree.lastToken(handler) + 1) |token| {
        if (std.mem.eql(u8, tree.tokenSlice(@intCast(token)), "recancel")) return null;
    }
    var buffer: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, handler) orelse (&handler)[0..1];
    for (statements) |statement| {
        if (tree.fullIf(statement)) |full| {
            if (testsCanceled(tree, full.ast.cond_expr, capture) and returnsBare(tree, full.ast.then_expr)) return statement;
        } else if (tree.fullSwitch(statement)) |full| {
            if (!isName(tree, full.ast.condition, capture)) continue;
            for (full.ast.cases) |case| {
                const prong = tree.fullSwitchCase(case).?;
                if (prong.payload_token != null) continue;
                const names_it = for (prong.ast.values) |value| {
                    if (isCanceled(tree, value)) break true;
                } else false;
                if (!names_it) continue;
                if (returnsBare(tree, prong.ast.target_expr) or isEmptyBlock(tree, prong.ast.target_expr)) return case;
            }
        }
    }
    return null;
}

/// What `leavesOnCanceled` found, on one line: `if (err == error.Canceled)
/// return`, `error.Canceled => {}`, or a block that ends in `return` as
/// `{ ... return; }`.
fn handlerText(arena: Allocator, tree: *const Ast, at: Node.Index) Allocator.Error![]const u8 {
    if (tree.fullIf(at)) |full| {
        return arena.print("if ({s}) {s}", .{ tree.getNodeSource(full.ast.cond_expr), leaving(tree, full.ast.then_expr) });
    }
    const prong = tree.fullSwitchCase(at).?;
    const first = tree.tokenStart(tree.firstToken(prong.ast.values[0]));
    const last = tree.lastToken(prong.ast.values[prong.ast.values.len - 1]);
    const values = tree.source[first .. tree.tokenStart(last) + tree.tokenSlice(last).len];
    return arena.print("{s} => {s}", .{ values, leaving(tree, prong.ast.target_expr) });
}

fn leaving(tree: *const Ast, node: Node.Index) []const u8 {
    if (tree.nodeTag(node) == .@"return") return "return";
    if (isEmptyBlock(tree, node)) return "{}";
    return "{ ... return; }";
}

/// `err == error.Canceled` or `error.Canceled == err`, with `err` named
/// `capture`.
fn testsCanceled(tree: *const Ast, node: Node.Index, capture: []const u8) bool {
    if (tree.nodeTag(node) != .equal_equal) return false;
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    return (isName(tree, lhs, capture) and isCanceled(tree, rhs)) or (isCanceled(tree, lhs) and isName(tree, rhs, capture));
}

fn isCanceled(tree: *const Ast, node: Node.Index) bool {
    return tree.nodeTag(node) == .error_value and std.mem.eql(u8, tree.tokenSlice(tree.lastToken(node)), "Canceled");
}

fn isName(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

/// `return` with no value, alone or as a block's last statement.
fn returnsBare(tree: *const Ast, node: Node.Index) bool {
    if (tree.nodeTag(node) == .@"return") return tree.nodeData(node).opt_node == .none;
    var buffer: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, node) orelse return false;
    return statements.len > 0 and returnsBare(tree, statements[statements.len - 1]);
}

fn isEmptyBlock(tree: *const Ast, node: Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .block_two, .block_two_semicolon => tree.nodeData(node).opt_node_and_opt_node[0] == .none,
        else => false,
    };
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
    try expect.findings(@src(), expected, out.written());
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

test "in a function a task's loop calls, a handler that names error.Canceled and returns (#66)" {
    try expectDropped(
        \\fn start(io: Io, s: *Sub) !void { _ = try io.concurrent(janitorLoop, .{s}); }
        \\fn janitorLoop(s: *Sub) Io.Cancelable!void { while (true) { try s.io.sleep(.fromMilliseconds(1), .awake); s.flush(); } }
        \\fn flush(s: *Sub) void {
        \\    s.sub.modifyAckDeadline(s.chunk) catch |err| { if (err == error.Canceled) return; log(err); };
        \\    s.sendIds() catch |err| switch (err) { error.Canceled => return, else => log(err) };
        \\    (s.other()) catch |e| switch (e) { error.Timeout, error.Canceled => {}, else => {} };
        \\    s.last() catch |err| if (error.Canceled == err) { log(err); return; } else log(err);
        \\}
    ,
        \\4:52 s.sub.modifyAckDeadline if (err == error.Canceled) return
        \\5:44 s.sendIds error.Canceled => return
        \\6:40 s.other error.Timeout, error.Canceled => {}
        \\7:26 s.last if (error.Canceled == err) { ... return; }
        \\
    );
}

test "not reported: the task's own handler, a call outside its loops, recancel, a value, the error handed on" {
    try expectDropped(
        \\fn start(io: Io, s: *Sub) !void { _ = try io.concurrent(task, .{s}); }
        \\fn task(s: *Sub) void {
        \\    outside(s);
        \\    while (true) {
        \\        s.io.sleep(.fromMilliseconds(1), .awake) catch |err| { if (err == error.Canceled) return; };
        \\        if (!tick(s)) return;
        \\        rearmed(s);
        \\        handed(s) catch return;
        \\        deferred(s);
        \\    }
        \\}
        \\fn outside(s: *Sub) void { s.io.sleep(.fromMilliseconds(1), .awake) catch |err| { if (err == error.Canceled) return; }; }
        \\fn tick(s: *Sub) bool { s.io.sleep(.fromMilliseconds(1), .awake) catch |err| { if (err == error.Canceled) return false; }; return true; }
        \\fn rearmed(s: *Sub) void { s.io.sleep(.fromMilliseconds(1), .awake) catch |err| { if (err == error.Canceled) { s.io.recancel(); return; } }; }
        \\fn handed(s: *Sub) !void { s.io.sleep(.fromMilliseconds(1), .awake) catch |err| switch (err) { error.Canceled => |e| return e }; }
        \\fn deferred(s: *Sub) void { defer s.io.sleep(.fromMilliseconds(1), .awake) catch |err| { if (err == error.Canceled) return; }; }
    , "");
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
