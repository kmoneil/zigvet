//! Rule eleven, unlock: a lock taken, then something that can fail before
//! the unlock, with no `defer` to unlock it.
//!
//!     try log.mutex.lock(io);
//!     try log.lines.append(gpa, v); // fails: the function returns holding the lock
//!     log.mutex.unlock(io);
//!
//! When `append` fails, the error leaves the function with the mutex still
//! held, and the next `lock` waits for good. It compiles clean in every
//! build mode and goes wrong only when the step between fails, the path
//! tests seldom take, and nothing at run time says why the program hangs.
//!
//! What locks is `x.lock(...)`, `x.lockUncancelable(...)`, `x.lockShared(...)`
//! or `x.lockSharedUncancelable(...)`, as a statement or under `try`, and
//! what unlocks is `x.unlock(...)`, or `x.unlockShared(...)` for a shared
//! lock, later in the same block, `x` the same as written. It is reported
//! when a statement between can fail with an error: a `try`, a
//! `return error.X`, or a `return` of what a `catch` caught, on a path that
//! does not unlock first.
//!
//! Not reported: a lock a `defer` or `errdefer` unlocks before the
//! failure, however it is written (`defer if (!unlocked) m.unlock();`); a
//! failure on a path that unlocks first; a plain `return` between, since a
//! function may return holding
//! the lock on purpose; the lock call's own `catch`; and code in a `test`
//! block, where a failure ends the test.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every lock left held by an error between it and
/// its unlock. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var parents: []const Node.OptionalIndex = &.{};
    for (0..tree.nodes.len) |i| {
        const block: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        for (statements, 0..) |statement, at| {
            const receiver, const shared = locks(tree, statement) orelse continue;
            const unlock_name = if (shared) "unlockShared" else "unlock";
            const holder = tree.getNodeSource(receiver);
            // Its unlock, later in the block, and what lies between.
            const end = for (statements[at + 1 ..], at + 1..) |later, k| {
                if (isCallOn(tree, later, holder, unlock_name)) break k;
            } else continue;
            const between = statements[at + 1 .. end];
            if (deferUnlocks(tree, between, holder, unlock_name)) continue;
            if (parents.len == 0) parents = (try types.Types.init(arena, tree)).parents;
            if (inTest(tree, parents, statement)) continue;
            const point = try failure(arena, tree, parents, between, holder, unlock_name) orelse continue;
            try findings.append(arena, .{
                .offset = tree.tokenStart(tree.firstToken(statement)),
                .hint = try arena.print("unlock it in a `defer` right after taking it (`defer {s}.{s}(...);`), so a failure cannot leave it held", .{ holder, unlock_name }),
                .detail = .{ .unlock = .{
                    .lock = holder,
                    .fails = what(tree, point),
                } },
            });
        }
    }
}

/// The receiver of `statement` if it takes a lock, `x` of `x.lock(io)` or
/// `try x.lock(io)`, and whether the lock is shared.
fn locks(tree: *const Ast, statement: Node.Index) ?struct { Node.Index, bool } {
    var node = statement;
    if (tree.nodeTag(node) == .@"try") node = tree.nodeData(node).node;
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
    const name = tree.tokenSlice(method);
    if (std.mem.eql(u8, name, "lock") or std.mem.eql(u8, name, "lockUncancelable")) return .{ receiver, false };
    if (std.mem.eql(u8, name, "lockShared") or std.mem.eql(u8, name, "lockSharedUncancelable")) return .{ receiver, true };
    return null;
}

/// Whether `node` is a call of `method` on what is written `holder`.
fn isCallOn(tree: *const Ast, node: Node.Index, holder: []const u8, method: []const u8) bool {
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const receiver, const name = tree.nodeData(call.ast.fn_expr).node_and_token;
    return std.mem.eql(u8, tree.tokenSlice(name), method) and std.mem.eql(u8, tree.getNodeSource(receiver), holder);
}

/// Whether one of `statements` is a `defer` or `errdefer` that can unlock
/// `holder`, however it is written (`defer if (!unlocked) m.unlock();`).
fn deferUnlocks(tree: *const Ast, statements: []const Node.Index, holder: []const u8, method: []const u8) bool {
    for (statements) |statement| {
        switch (tree.nodeTag(statement)) {
            .@"defer", .@"errdefer" => {
                const source = tree.getNodeSource(statement);
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, source, at, holder)) |found| : (at = found + 1) {
                    const rest = source[found + holder.len ..];
                    if (rest.len > method.len + 1 and rest[0] == '.' and std.mem.startsWith(u8, rest[1..], method) and rest[1 + method.len] == '(') return true;
                }
            },
            else => {},
        }
    }
    return false;
}

/// The first error exit in `statements`, on a path that does not unlock
/// `holder` first: a `try`, a `return error.X`, or a `return` of what a
/// `catch` caught.
fn failure(arena: Allocator, tree: *const Ast, parents: []const Node.OptionalIndex, statements: []const Node.Index, holder: []const u8, method: []const u8) Allocator.Error!?Node.Index {
    for (statements) |statement| {
        var nodes: std.ArrayList(Node.Index) = .empty;
        try within(arena, tree, statement, &nodes);
        var first: ?Node.Index = null;
        for (nodes.items) |node| {
            const fails = switch (tree.nodeTag(node)) {
                .@"try" => true,
                .@"return" => returnsError(tree, parents, node),
                else => false,
            };
            if (!fails or unlockedBefore(tree, parents, node, statement, holder, method)) continue;
            if (first == null or tree.nodeMainToken(node) < tree.nodeMainToken(first.?)) first = node;
        }
        if (first) |point| return point;
    }
    return null;
}

/// Whether, on the way from `statement` down to `node`, a block unlocks
/// `holder` before what holds `node`: `if (bad) { m.unlock(); return error.X; }`.
fn unlockedBefore(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index, statement: Node.Index, holder: []const u8, method: []const u8) bool {
    var child = node;
    var up = parents[@backingInt(node)].unwrap();
    while (up) |parent| : ({
        child = parent;
        up = parents[@backingInt(parent)].unwrap();
    }) {
        var buffer: [2]Node.Index = undefined;
        if (tree.blockStatements(&buffer, parent)) |inner| {
            for (inner) |s| {
                if (s == child) break;
                if (isCallOn(tree, s, holder, method)) return true;
            }
        }
        if (parent == statement) return false;
    }
    return false;
}

/// Whether `node`, a `return`, returns an error: `error.X`, or what the
/// `catch |err|` around it caught.
pub fn returnsError(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) bool {
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

/// Whether `node` is in a `test` block, where a failure ends the test.
pub fn inTest(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) bool {
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

/// What fails at `point`, as written: the function a `try` calls, or what
/// a `return` returns.
pub fn what(tree: *const Ast, point: Node.Index) []const u8 {
    if (tree.nodeTag(point) == .@"return") return tree.getNodeSource(tree.nodeData(point).opt_node.unwrap().?);
    var operand = tree.nodeData(point).node;
    while (tree.nodeTag(operand) == .grouped_expression) operand = tree.nodeData(operand).node_and_token[0];
    var buffer: [1]Node.Index = undefined;
    if (tree.fullCall(&buffer, operand)) |call| return tree.getNodeSource(call.ast.fn_expr);
    return tree.getNodeSource(operand);
}

/// Appends `node` and every node under it, but not what nested functions
/// and types hold, or what a `defer` or `errdefer` runs.
pub fn within(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
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
/// `line:col lock <- what fails`, in source order.
fn expectUnlock(source: [:0]const u8, expected: []const u8) !void {
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
        const u = finding.detail.unlock;
        try out.writer.print("{d}:{d} {s} <- {s}\n", .{ loc.line + 1, loc.column + 1, u.lock, u.fails });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a lock left held by a failure before its unlock (#57)" {
    try expectUnlock(
        \\fn add(log: *Log, io: Io, gpa: Allocator, v: u32) !void { try log.mutex.lock(io); try log.lines.append(gpa, v); log.mutex.unlock(io); }
        \\fn acquire(self: *Pool, io: Io) !*Conn { try self.pool_mut.lock(io); const conn = try self.pool.create(self.allocator); self.pool_mut.unlock(io); return conn; }
        \\fn plain(self: *S) !void { self.mutex.lock(); if (self.closed) return error.Closed; self.mutex.unlock(); }
        \\fn shared(self: *S, io: Io) !void { self.rw.lockSharedUncancelable(io); _ = try self.read(); self.rw.unlockShared(io); }
        \\fn caught(self: *S) !void { self.mutex.lock(); self.flush() catch |err| { log(err); return err; }; self.mutex.unlock(); }
    ,
        \\1:59 log.mutex <- log.lines.append
        \\2:42 self.pool_mut <- self.pool.create
        \\3:28 self.mutex <- error.Closed
        \\4:37 self.rw <- self.read
        \\5:29 self.mutex <- err
        \\
    );
}

test "not reported: defer, errdefer, unlocked on the way out, a plain return, the lock's own catch, a test" {
    try expectUnlock(
        \\fn deferred(self: *S) !void { self.mutex.lock(); defer self.mutex.unlock(); try self.flush(); }
        \\fn flagged(self: *S) !void { self.mutex.lock(); var unlocked = false; defer if (!unlocked) self.mutex.unlock(); try self.flush(); self.mutex.unlock(); unlocked = true; }
        \\fn errdeferred(self: *S) !void { self.mutex.lock(); errdefer self.mutex.unlock(); try self.flush(); self.mutex.unlock(); }
        \\fn onTheWayOut(self: *S) !void { self.mutex.lock(); if (self.closed) { self.mutex.unlock(); return error.Closed; } self.mutex.unlock(); }
        \\fn plainReturn(self: *S) ?Config { self.mutex.lock(); return self.config orelse { self.mutex.unlock(); return null; }; }
        \\fn ownCatch(self: *S, io: Io) !void { self.mutex.lock(io) catch |err| switch (err) { error.Canceled => return error.Canceled }; self.n += 1; self.mutex.unlock(io); }
        \\fn after(self: *S) !void { self.mutex.lock(); self.n += 1; self.mutex.unlock(); try self.flush(); }
        \\fn other(self: *S) !void { self.a.lock(); try self.flush(); self.b.unlock(); }
        \\test "held" { m.lock(); try expect(false); m.unlock(); }
    , "");
}
