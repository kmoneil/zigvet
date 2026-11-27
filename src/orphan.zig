//! Rule thirty-three, orphan: an allocation made in the arguments of a call
//! that can fail, which nothing frees when it does.
//!
//!     try list.append(gpa, try gpa.dupe(u8, s));
//!
//! The copy is made before `append` runs. When `append` then fails, the
//! error leaves the function and the copy has no name an errdefer could
//! free it by: it leaks. It compiles clean in every build mode and goes
//! wrong only when the outer call fails, the path tests seldom take; the
//! debugging allocator says "leaked" only in a test that makes that one
//! allocation fail. With a thread for the copy, `try threads.append(gpa,
//! try std.Thread.spawn(.{}, run, .{}))`, the thread is left neither joined
//! nor detached.
//!
//! What is made is an argument written `try <call>`, the call one of std's
//! that hand back what the caller releases, by name: an allocator's
//! (`alloc`, `dupe`, `create` and their variants), `allocPrint`, a list's
//! `toOwnedSlice`, `Thread.spawn`, and a directory's `openFile`, `openDir`
//! and `createFile`. It is reported when the call it is an argument of can
//! fail where it stands: it is under `try`, or what a `catch` handles.
//!
//! Memory is reported only from an allocator named for the general-purpose
//! one, `gpa` in its name (`gpa`, `self.gpa`). An arena frees it with the
//! rest, and most of these calls pass one: under any other name
//! (`allocator`, `a`) the syntax cannot tell which it is.
//!
//! Not reported: an allocator with `arena` in its name, or a local made
//! from one (`const gpa = arena_state.allocator();`); a call that cannot
//! fail (`appendAssumeCapacity`), or whose `catch` is `unreachable`; a call
//! to a function of the file that frees that parameter itself when it
//! fails, with an `errdefer` naming it; and code in a `test` block, where a
//! failure ends the test.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const expect = @import("expect.zig");
const ints = @import("ints.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");
const Types = types.Types;

/// Appends a finding for every allocation made in the arguments of a call
/// that can fail. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var t: ?Types = null;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        for (call.ast.params, 0..) |param, index| {
            const made = making(tree, param) orelse continue;
            if (t == null) t = try .init(arena, tree);
            if (!orphaned(t.?, node, call, index, made)) continue;
            try findings.append(arena, .{
                .offset = tree.tokenStart(tree.firstToken(param)),
                .hint = hint,
                .detail = .{ .orphan = .{
                    .made = tree.getNodeSource(made.callee),
                    .fails = tree.getNodeSource(call.ast.fn_expr),
                } },
            });
        }
    }
}

const hint = "give it a name and arm its release before the call (`const copy = try gpa.dupe(u8, s); errdefer gpa.free(copy);`), or make the call unable to fail first (`ensureUnusedCapacity`, then `appendAssumeCapacity`)";

/// Whether what `made` makes, argument `index` of the call `node`, is left
/// with nothing to release it when that call fails.
fn orphaned(t: Types, node: Node.Index, call: Ast.full.Call, index: usize, made: Made) bool {
    if (!canFail(t, node)) return false;
    if (inTest(t, node)) return false;
    if (made.allocator) |allocator| {
        if (!generalPurpose(t, allocator)) return false;
    }
    return !takenOnFailure(t, call, index);
}

/// What an argument makes under `try`: the call that makes it, and the
/// allocator it is made with; none for a thread or an open file.
const Made = struct {
    callee: Node.Index,
    allocator: ?Node.Index,
};

/// Where one of std's makers takes its allocator: `receiver` for
/// `gpa.dupe(...)`, `first` for `std.fmt.allocPrint(gpa, ...)` and
/// `list.toOwnedSlice(gpa)`, `none` for what is no memory.
const From = enum { receiver, first, none };

/// Std's functions that hand back what the caller releases, by name.
const makers: std.StaticStringMap(From) = .initComptime(.{
    .{ "alloc", .receiver },            .{ "alignedAlloc", .receiver }, .{ "allocSentinel", .receiver },
    .{ "allocWithOptions", .receiver }, .{ "create", .receiver },       .{ "dupe", .receiver },
    .{ "dupeZ", .receiver },            .{ "dupeSentinel", .receiver }, .{ "allocPrint", .first },
    .{ "allocPrintSentinel", .first },  .{ "toOwnedSlice", .first },    .{ "toOwnedSliceSentinel", .first },
    .{ "spawn", .none },                .{ "openFile", .none },         .{ "openDir", .none },
    .{ "createFile", .none },
});

/// `argument` as something made in place: `try gpa.dupe(u8, s)`.
fn making(tree: *const Ast, argument: Node.Index) ?Made {
    const tried = ints.unparen(tree, argument);
    if (tree.nodeTag(tried) != .@"try") return null;
    const made = ints.unparen(tree, tree.nodeData(tried).node);
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, made) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver, const name_token = tree.nodeData(call.ast.fn_expr).node_and_token;
    const name = tree.tokenSlice(name_token);
    const allocator: ?Node.Index = switch (makers.get(name) orelse return null) {
        .receiver => receiver,
        .first => if (call.ast.params.len > 0) call.ast.params[0] else return null,
        .none => null,
    };
    // `spawn` is many things' name; a thread's is `Thread.spawn`.
    if (std.mem.eql(u8, name, "spawn") and !std.mem.endsWith(u8, tree.getNodeSource(receiver), "Thread")) return null;
    return .{ .callee = call.ast.fn_expr, .allocator = allocator };
}

/// Whether the call `node` can fail where it stands: it is under `try`, or
/// what a `catch` handles with something other than `unreachable`.
fn canFail(t: Types, node: Node.Index) bool {
    const tree = t.tree;
    var child = node;
    var up = t.parents[@backingInt(node)].unwrap();
    while (up) |parent| : ({
        child = parent;
        up = t.parents[@backingInt(parent)].unwrap();
    }) switch (tree.nodeTag(parent)) {
        .grouped_expression => {},
        .@"try" => return true,
        .@"catch" => {
            const lhs, const handler = tree.nodeData(parent).node_and_node;
            return lhs == child and tree.nodeTag(handler) != .unreachable_literal;
        },
        else => return false,
    };
    return false;
}

/// Whether `node` is in a `test` block, where a failure ends the test.
fn inTest(t: Types, node: Node.Index) bool {
    var up = t.parents[@backingInt(node)].unwrap();
    while (up) |parent| : (up = t.parents[@backingInt(parent)].unwrap()) {
        if (t.tree.nodeTag(parent) == .test_decl) return true;
    }
    return false;
}

/// Whether `allocator` is named for one whose memory someone has to free,
/// `gpa` in its name. Not one with `arena` in its name too, nor a local
/// made from one.
fn generalPurpose(t: Types, allocator: Node.Index) bool {
    const tree = t.tree;
    const text = tree.getNodeSource(allocator);
    if (std.ascii.findIgnoreCase(text, "arena") != null) return false;
    if (tree.nodeTag(allocator) == .identifier) {
        if (t.localInit(allocator)) |init| {
            if (std.ascii.findIgnoreCase(tree.getNodeSource(init), "arena") != null) return false;
        }
    }
    return std.ascii.findIgnoreCase(text, "gpa") != null;
}

/// Whether `call` is to a function of the file that releases its argument
/// `index` itself when it fails: an `errdefer` in it names that parameter.
fn takenOnFailure(t: Types, call: Ast.full.Call, index: usize) bool {
    const tree = t.tree;
    const fn_decl, const offset = t.callee(call.ast.fn_expr) orelse return false;
    const proto_node, const body = tree.nodeData(fn_decl).node_and_node;
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, proto_node).?;
    var params = proto.iterate(tree);
    var at: usize = 0;
    const name = while (params.next()) |param| : (at += 1) {
        if (at == index + offset) break tree.tokenSlice(param.name_token orelse return false);
    } else return false;
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .@"errdefer") continue;
        const from = tree.firstToken(node);
        if (from < first or from > last) continue;
        for (from..tree.lastToken(node) + 1) |token| {
            if (std.mem.eql(u8, tree.tokenSlice(@intCast(token)), name)) return true;
        }
    }
    return false;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col made <- fails`, in source order.
fn expectOrphans(source: [:0]const u8, expected: []const u8) !void {
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
        const o = finding.detail.orphan;
        try out.writer.print("{d}:{d} {s} <- {s}\n", .{ loc.line + 1, loc.column + 1, o.made, o.fails });
    }
    try expect.findings(@src(), expected, out.written());
}

test "an allocation in the arguments of a call that can fail (#236)" {
    try expectOrphans(
        \\fn keep(gpa: Allocator, list: *List, s: []const u8) !void { try list.append(gpa, try gpa.dupe(u8, s)); }
        \\fn put(self: *Store, k: []const u8, v: u32) !void { try self.names.put(self.gpa, (try self.gpa.dupe(u8, k)), v); }
        \\fn note(self: *App, n: u32) !void { try self.push(try std.fmt.allocPrint(self.gpa, "{d}", .{n})); }
        \\fn lines(gpa: Allocator, out: *Lines, line: *Line) !void { try out.append(gpa, try line.toOwnedSlice(gpa)); }
        \\fn node(m: *Model) !void { try m.nodes.append(m.gpa, try m.gpa.create(Node)); }
        \\fn start(r: *Runner, arena: Allocator) !void { try r.threads.append(arena, try std.Thread.spawn(.{}, run, .{r})); }
        \\fn opened(files: *Files, arena: Allocator, dir: Dir, io: Io) !void { try files.append(arena, try dir.openFile(io, "a", .{})); }
        \\fn undone(self: *Store, s: []const u8) !void { self.list.append(self.gpa, try self.gpa.dupe(u8, s)) catch |err| { self.undo(); return err; }; }
        \\const App = struct { fn push(self: *App, text: []u8) !void { try self.entries.append(self.gpa, text); } };
    ,
        \\1:82 gpa.dupe <- list.append
        \\2:82 self.gpa.dupe <- self.names.put
        \\3:51 std.fmt.allocPrint <- self.push
        \\4:80 line.toOwnedSlice <- out.append
        \\5:54 m.gpa.create <- m.nodes.append
        \\6:76 std.Thread.spawn <- r.threads.append
        \\7:94 dir.openFile <- files.append
        \\8:75 self.gpa.dupe <- self.list.append
        \\
    );
}

test "not reported: an arena, a name that says neither, a call that cannot fail, one that frees it, a test (#236)" {
    try expectOrphans(
        \\fn arena(a: Allocator, list: *List, s: []const u8) !void { try list.append(a, try a.dupe(u8, s)); }
        \\fn named(arena_gpa: Allocator, list: *List, s: []const u8) !void { try list.append(arena_gpa, try arena_gpa.dupe(u8, s)); }
        \\fn field(self: *Doc, s: []const u8) !void { try self.parts.append(self.arena, try self.arena.dupe(u8, s)); }
        \\fn alias(arena_state: *std.heap.ArenaAllocator, list: *List, s: []const u8) !void { const gpa = arena_state.allocator(); try list.append(gpa, try gpa.dupe(u8, s)); }
        \\fn generic(allocator: Allocator, list: *List, s: []const u8) !void { try list.append(allocator, try allocator.dupe(u8, s)); }
        \\fn paged(list: *List, s: []const u8) !void { try list.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, s)); }
        \\fn assumed(gpa: Allocator, list: *List, s: []const u8) !void { try list.ensureUnusedCapacity(gpa, 1); list.appendAssumeCapacity(try gpa.dupe(u8, s)); }
        \\fn asserted(gpa: Allocator, list: *List, s: []const u8) !void { list.append(gpa, try gpa.dupe(u8, s)) catch unreachable; }
        \\fn bound(gpa: Allocator, list: *List, s: []const u8) !void { const copy = try gpa.dupe(u8, s); errdefer gpa.free(copy); try list.append(gpa, copy); }
        \\fn other(gpa: Allocator, list: *List, s: []const u8) !void { try list.append(gpa, try parse(s)); }
        \\fn spawned(gpa: Allocator, kids: *Kids, argv: []const []const u8) !void { try kids.append(gpa, try process.spawn(argv)); }
        \\fn taken(self: *Nav, gpa: Allocator, view: []const u8) !void { try self.addPane(gpa, try gpa.dupe(u8, view)); }
        \\const Nav = struct { fn addPane(self: *Nav, gpa: Allocator, view: []u8) !void { errdefer gpa.free(view); try self.panes.append(gpa, view); } };
        \\test "a failure ends the test" { try list.append(gpa, try gpa.dupe(u8, "a")); }
    , "");
}
