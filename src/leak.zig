//! Rule nineteen, leak: a local released by hand later in its block, with
//! something between that can fail and no `defer` to release it.
//!
//!     var stmt = try prepare(gpa);
//!     try stmt.bind(v); // fails: the function returns without finalizing stmt
//!     stmt.finalize();
//!
//! When `bind` fails, the error leaves the function before the `finalize`,
//! and what `prepare` made is never released. It compiles clean in every
//! build mode and goes wrong only when the step between fails, the path
//! tests seldom take; the debugging allocator says "leaked" only in a test
//! that makes it fail. It is unlock's shape, with a resource for the lock.
//!
//! What is made is a local whose initializer is a call that can fail,
//! under `try` or `catch` (`try prepare(gpa)`, `try gpa.alloc(u8, n)`),
//! or an empty value (`.empty`, `.{}`, an `init` that cannot fail), which
//! holds nothing until something is put in it. What releases it is a
//! statement later in the same block, not under `try`: a call on it whose
//! name is a release word (`stmt.finalize()`, `file.close(io)`), or one
//! handed it, as its only argument or one after the first, whose name is
//! or has one, an allocator's (`gpa.free(buf)`), a namespace's
//! (`posix.close(fd)`, `c.sqlite3_finalize(stmt)`) or a function's. The
//! words are `deinit`, `finalize`, `close`, `destroy`, `free`, `release`
//! and `unmap`, each a word of the name. What an allocator's `create(T)`
//! made only `destroy` releases, and what its `alloc` made only `free`.
//! It is reported at the first statement between that can fail with an
//! error, a `try`, a `return error.X`, or a `return` of what a `catch` or
//! an `else |err|` caught, on a path that does not release it first; for
//! an empty value, after the first statement that uses it.
//!
//! Not reported: a local a `defer` or `errdefer` names before the failure;
//! one assigned to between, or stored on the failing path; a failure in a
//! `return` that hands it on; one made from a name, a field, a call that
//! cannot fail or one under `orelse`, a view more often than something
//! new; one made with an arena or released into one, which frees it with
//! the rest; a value's method with a release word in a longer name
//! (`self.codegen.freeGeneral(reg)`), which releases what the value keeps;
//! a failed `expect`, which ends the test it is in; and code in a `test`
//! block, where a failure ends the test.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const expect = @import("expect.zig");
const kept = @import("kept.zig");
const refill = @import("refill.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");
const unlock = @import("unlock.zig");

/// Appends a finding for every local left unreleased by an error between
/// it and its release by hand. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree };
    for (0..tree.nodes.len) |i| {
        const block: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        for (statements, 0..) |statement, at| {
            const decl = tree.fullVarDecl(statement) orelse continue;
            const made = making(tree, decl.ast.init_node.unwrap() orelse continue) orelse continue;
            const name = tree.tokenSlice(decl.ast.mut_token + 1);
            rule.paired = made.release;
            // Its release by hand, later in the block, and what lies between.
            const end, const release = for (statements[at + 1 ..], at + 1..) |later, k| {
                if (try rule.releaseIn(later, name)) |call| break .{ k, call };
            } else continue;
            var between = statements[at + 1 .. end];
            // A `defer` or `errdefer` that names it covers what follows,
            // whether it releases it or hands it back
            // (`errdefer self.definitions.restore(gpa, &snapshot);`).
            for (between, 0..) |later, k| {
                switch (tree.nodeTag(later)) {
                    .@"defer", .@"errdefer" => {},
                    else => continue,
                }
                if (mentions(tree, later, name)) {
                    between = between[0..k];
                    break;
                }
            }
            if (try assigns(arena, tree, between, name)) continue;
            // Made empty, it holds nothing until the first statement that
            // uses it, so a failure there leaks nothing.
            if (made.empty) {
                const first = for (between, 0..) |later, k| {
                    if (mentions(tree, later, name)) break k;
                } else continue;
                between = between[first + 1 ..];
            }
            if (between.len == 0) continue;
            const parents = try rule.parentsOf();
            if (unlock.inTest(tree, parents, statement)) continue;
            const point = try rule.failure(between, name) orelse continue;
            const release_source = tree.getNodeSource(release);
            const hint = if (try handedOut(arena, tree, statements[at + 1 ..], name))
                try arena.print("release it in an `errdefer` right after it is made (`errdefer {s};`), so a failure cannot skip it", .{release_source})
            else
                try arena.print("release it in a `defer` right after it is made (`defer {s};`, in place of the one below), so a failure cannot skip it", .{release_source});
            try findings.append(arena, .{
                .offset = tree.tokenStart(tree.firstToken(point)),
                .hint = hint,
                .detail = .{ .leak = .{
                    .local = name,
                    .release = release_source,
                    .fails = unlock.what(tree, point),
                } },
            });
        }
    }
}

/// What a local's initializer makes: what a call that can fail returns
/// (`try prepare(gpa)`, `open(path) catch ...`), or an empty value that
/// holds nothing until something is put in it. Null for anything else: a
/// call that cannot fail, or one under `orelse`, returns a view of what
/// something else owns more often than something new
/// (`self.allocatedSlice()`, `map.get(key) orelse ...`), and a name or a
/// field is a copy. So is anything made with an arena
/// (`ArenaAllocator.init(ctx.arena)`), which frees it with the rest.
const Made = struct {
    empty: bool,
    /// The release its maker pairs with, if it says: `destroy` for an
    /// allocator's `create`, `free` for its `alloc` and the like.
    release: ?[]const u8 = null,
};

fn making(tree: *const Ast, init: Node.Index) ?Made {
    var node = init;
    var fallible = false;
    while (true) switch (tree.nodeTag(node)) {
        .@"try" => {
            fallible = true;
            node = tree.nodeData(node).node;
        },
        .@"catch" => {
            fallible = true;
            node = tree.nodeData(node).node_and_node[0];
        },
        .grouped_expression => node = tree.nodeData(node).node_and_token[0],
        else => break,
    };
    switch (tree.nodeTag(node)) {
        // `.empty`, `.init`.
        .enum_literal => return .{ .empty = true },
        .field_access => {
            const field = tree.tokenSlice(tree.nodeData(node).node_and_token[1]);
            return if (std.mem.eql(u8, field, "empty")) .{ .empty = true } else null;
        },
        else => {},
    }
    var init_buffer: [2]Node.Index = undefined;
    if (tree.fullStructInit(&init_buffer, node)) |struct_init| return if (struct_init.ast.fields.len == 0) .{ .empty = true } else null;
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (madeInArena(tree, call)) return null;
    const callee = calleeName(tree, call.ast.fn_expr) orelse return if (fallible) .{ .empty = false } else null;
    // `ArenaAllocator.init(gpa)`: an `init` that cannot fail has made
    // nothing it could fail to make.
    if (!fallible) return if (std.mem.eql(u8, callee, "init")) .{ .empty = true } else null;
    const release = pairedRelease(callee) orelse return .{ .empty = false };
    // An allocator's `create(T)`, not an API's `schema.create(.{ ... })`.
    if (std.mem.eql(u8, callee, "create") and (call.ast.params.len != 1 or !isType(tree, call.ast.params[0]))) return .{ .empty = false };
    return .{ .empty = false, .release = release };
}

/// Whether `node` is written as a type is: a primitive (`u8`), a name or
/// a field written with a capital (`Shot`, `sim.Sim`), a call of one
/// (`List(u8)`), or a builtin (`@This()`).
fn isType(tree: *const Ast, node: Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            return std.ascii.isUpper(name[0]) or std.zig.primitives.isPrimitive(name);
        },
        .field_access => return std.ascii.isUpper(tree.tokenSlice(tree.nodeData(node).node_and_token[1])[0]),
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => return true,
        else => {},
    }
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    return isType(tree, call.ast.fn_expr);
}

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    parents: []const Node.OptionalIndex = &.{},
    /// The names the file declares at its top level, which a call through
    /// is a call through a namespace (`posix.close(fd)`), and `std`.
    namespaces: ?std.StringHashMapUnmanaged(void) = null,
    /// The one release the local at hand pairs with, if its maker says:
    /// what `create` made is released by `destroy`, not by its `deinit`,
    /// which releases what its `init` made.
    paired: ?[]const u8 = null,

    fn parentsOf(r: *Rule) Allocator.Error![]const Node.OptionalIndex {
        if (r.parents.len == 0) r.parents = (try types.Types.init(r.arena, r.tree)).parents;
        return r.parents;
    }

    /// The call `statement` is, if it releases the local `name`: as
    /// written alone, with a `catch`, or assigned to `_`. One under `try`
    /// is a step that can fail, as a builder's `try scope.finalize()`,
    /// rather than a release, which in Zig does not.
    fn releaseIn(r: *Rule, statement: Node.Index, name: []const u8) Allocator.Error!?Node.Index {
        const tree = r.tree;
        var node = statement;
        while (true) switch (tree.nodeTag(node)) {
            .@"catch" => node = tree.nodeData(node).node_and_node[0],
            .assign => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                if (!isName(tree, lhs, "_")) return null;
                node = rhs;
            },
            else => break,
        };
        return if (try r.releases(node, name)) node else null;
    }

    /// Whether `node` is a call that releases the local `name`: one whose
    /// name is a release word called on it (`stmt.finalize()`), or one
    /// whose name is or has a release word, handed it as its only argument
    /// or one after the first, the first being most often what it releases
    /// into: an allocator's (`gpa.free(buf)`), a namespace's
    /// (`posix.close(fd)`, `c.sqlite3_finalize(stmt)`), or a function's
    /// (`release(ctx, &frame)`). A value's method with a release word in a
    /// longer name releases what the value keeps more often than what it
    /// is handed (`self.codegen.freeGeneral(reg)` hands a register back to
    /// a pool), and is not one.
    fn releases(r: *Rule, node: Node.Index, name: []const u8) Allocator.Error!bool {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse return false;
        const callee = calleeName(tree, call.ast.fn_expr) orelse return false;
        const word = releaseWord(callee) orelse return false;
        if (r.paired) |paired| if (!std.mem.eql(u8, callee, paired)) return false;
        if (intoArena(tree, call)) return false;
        // `a.free(x)`, `a.destroy(x)`, `a.rawFree(x, ...)` and `x.deinit()`.
        if (refill.releaseCall(tree, node)) |found| return isName(tree, stripped(tree, found[1]), name);
        if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
            const receiver = tree.nodeData(call.ast.fn_expr).node_and_token[0];
            if (word == .whole and isName(tree, stripped(tree, receiver), name)) return true;
            if (!try r.isNamespace(receiver)) return false;
        }
        const params = if (call.ast.params.len > 1) call.ast.params[1..] else call.ast.params;
        for (params) |param| if (isName(tree, stripped(tree, param), name)) return true;
        return false;
    }

    /// Whether `receiver` is reached from a name the file declares at its
    /// top level, or `std`: a namespace rather than a value.
    fn isNamespace(r: *Rule, receiver: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        const root = kept.rootOf(tree, receiver) orelse return false;
        const name = tree.tokenSlice(tree.nodeMainToken(root));
        if (std.mem.eql(u8, name, "std")) return true;
        if (r.namespaces == null) {
            var names: std.StringHashMapUnmanaged(void) = .empty;
            for (tree.rootDecls()) |decl_node| {
                const decl = tree.fullVarDecl(decl_node) orelse continue;
                try names.put(r.arena, tree.tokenSlice(decl.ast.mut_token + 1), {});
            }
            r.namespaces = names;
        }
        return r.namespaces.?.contains(name);
    }

    /// The first error exit in `statements`, on a path that does not
    /// release the local `name` first: a `try`, a `return error.X`, or a
    /// `return` of what a capture caught. A failed `expect` ends the test
    /// it is in, and is not one.
    fn failure(r: *Rule, statements: []const Node.Index, name: []const u8) Allocator.Error!?Node.Index {
        const tree = r.tree;
        for (statements) |statement| {
            var nodes: std.ArrayList(Node.Index) = .empty;
            try unlock.within(r.arena, tree, statement, &nodes);
            var first: ?Node.Index = null;
            for (nodes.items) |node| {
                const fails = switch (tree.nodeTag(node)) {
                    .@"try" => !std.mem.startsWith(u8, unlock.what(tree, node), "expect") and
                        std.mem.find(u8, unlock.what(tree, node), ".expect") == null,
                    .@"return" => unlock.returnsError(tree, r.parents, node),
                    else => false,
                };
                if (!fails or try r.handledBefore(node, statement, name)) continue;
                // `return try self.makeDeferred(face, ...)` hands it on.
                if (r.returned(node) and mentions(tree, node, name)) continue;
                if (first == null or tree.nodeMainToken(node) < tree.nodeMainToken(first.?)) first = node;
            }
            if (first) |point| return point;
        }
        return null;
    }

    /// Whether `node` is what a `return` returns, or under it.
    fn returned(r: *Rule, node: Node.Index) bool {
        var up: ?Node.Index = node;
        while (up) |n| : (up = r.parents[@backingInt(n)].unwrap()) {
            switch (r.tree.nodeTag(n)) {
                .@"return" => return true,
                .fn_decl, .test_decl => return false,
                else => {},
            }
        }
        return false;
    }

    /// Whether, on the way from `statement` down to `node`, a block
    /// releases the local `name` before what holds `node`
    /// (`else => { stmt.finalize(); return err; }`), or stores it.
    fn handledBefore(r: *Rule, node: Node.Index, statement: Node.Index, name: []const u8) Allocator.Error!bool {
        const tree = r.tree;
        var child = node;
        var up = r.parents[@backingInt(node)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = r.parents[@backingInt(parent)].unwrap();
        }) {
            var buffer: [2]Node.Index = undefined;
            if (tree.blockStatements(&buffer, parent)) |inner| {
                for (inner) |s| {
                    if (s == child) break;
                    if (try r.releaseIn(s, name) != null or try stores(r.arena, tree, s, name)) return true;
                }
            }
            if (parent == statement) return false;
        }
        return false;
    }
};

/// The name a call's function is written with: `prepare` of `prepare(gpa)`
/// or `finalize` of `stmt.finalize()`.
fn calleeName(tree: *const Ast, fn_expr: Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(fn_expr)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(fn_expr)),
        .field_access => tree.tokenSlice(tree.nodeData(fn_expr).node_and_token[1]),
        else => null,
    };
}

/// `node` through `&`, `.*` and parentheses.
fn stripped(tree: *const Ast, node: Node.Index) Node.Index {
    var n = node;
    while (true) switch (tree.nodeTag(n)) {
        .address_of, .deref => n = tree.nodeData(n).node,
        .grouped_expression => n = tree.nodeData(n).node_and_token[0],
        else => return n,
    };
}

fn isName(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

/// Whether a release word is all of `name` (`finalize`) or one word of it,
/// split at `_` and where a capital follows a small letter
/// (`sqlite3_finalize`, `destroyWindow`): not `closest` or `freeze`.
const Word = enum { whole, part };

fn releaseWord(name: []const u8) ?Word {
    const words = [_][]const u8{ "deinit", "finalize", "close", "destroy", "free", "release", "unmap", "munmap" };
    var start: usize = 0;
    while (start < name.len) {
        var stop = start + 1;
        while (stop < name.len and name[stop] != '_' and !(std.ascii.isUpper(name[stop]) and std.ascii.isLower(name[stop - 1]))) stop += 1;
        for (words) |word| {
            if (std.ascii.eqlIgnoreCase(name[start..stop], word)) return if (start == 0 and stop == name.len) .whole else .part;
        }
        start = if (stop < name.len and name[stop] == '_') stop + 1 else stop;
    }
    return null;
}

/// Whether `call` releases into an arena (`cells.deinit(p.arena)`,
/// `arena.free(buf)`), which frees nothing the arena will not.
fn intoArena(tree: *const Ast, call: Ast.full.Call) bool {
    for (call.ast.params) |param| if (namesArena(tree, param)) return true;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const callee = calleeName(tree, call.ast.fn_expr).?;
    if (!std.mem.eql(u8, callee, "free") and !std.mem.eql(u8, callee, "destroy") and !std.mem.eql(u8, callee, "rawFree")) return false;
    return namesArena(tree, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
}

/// Whether `call` makes what it makes with an arena: one is handed to it
/// (`ArenaAllocator.init(ctx.arena)`), or it is an arena's own allocation
/// (`arena.alloc(u8, n)`).
fn madeInArena(tree: *const Ast, call: Ast.full.Call) bool {
    for (call.ast.params) |param| if (namesArena(tree, param)) return true;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const callee = calleeName(tree, call.ast.fn_expr).?;
    if (pairedRelease(callee) == null) return false;
    return namesArena(tree, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
}

/// The release an allocator's maker pairs with: `destroy` for `create`,
/// `free` for `alloc` and the like.
fn pairedRelease(maker: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, maker, "create")) return "destroy";
    const freed = [_][]const u8{ "alloc", "alignedAlloc", "allocSentinel", "dupe", "dupeZ", "allocPrint", "allocPrintSentinel", "realloc", "toOwnedSlice", "toOwnedSliceSentinel" };
    for (freed) |made| if (std.mem.eql(u8, maker, made)) return "free";
    return null;
}

fn namesArena(tree: *const Ast, node: Node.Index) bool {
    return std.ascii.findIgnoreCase(tree.getNodeSource(node), "arena") != null;
}

/// Whether `statement` stores the local `name` somewhere else, an
/// assignment whose value names it: `self.stmt = stmt;`,
/// `out.* = .{ .stmt = stmt };`.
fn stores(arena: Allocator, tree: *const Ast, statement: Node.Index, name: []const u8) Allocator.Error!bool {
    var nodes: std.ArrayList(Node.Index) = .empty;
    try unlock.within(arena, tree, statement, &nodes);
    for (nodes.items) |node| {
        if (tree.nodeTag(node) != .assign) continue;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        const root = kept.rootOf(tree, lhs) orelse continue;
        if (!isName(tree, root, name) and !isName(tree, root, "_") and mentions(tree, rhs, name)) return true;
    }
    return false;
}

/// Whether a `return` in `statements` returns the local `name` or what
/// holds it, so that a `defer` releasing it would free what the caller
/// gets.
fn handedOut(arena: Allocator, tree: *const Ast, statements: []const Node.Index, name: []const u8) Allocator.Error!bool {
    for (statements) |statement| {
        var nodes: std.ArrayList(Node.Index) = .empty;
        try unlock.within(arena, tree, statement, &nodes);
        for (nodes.items) |node| {
            if (tree.nodeTag(node) != .@"return") continue;
            const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
            if (mentions(tree, value, name)) return true;
        }
    }
    return false;
}

/// Whether one of `statements` assigns to the local `name` whole, which
/// leaves it something else to release.
fn assigns(arena: Allocator, tree: *const Ast, statements: []const Node.Index, name: []const u8) Allocator.Error!bool {
    for (statements) |statement| {
        var nodes: std.ArrayList(Node.Index) = .empty;
        try unlock.within(arena, tree, statement, &nodes);
        for (nodes.items) |node| {
            if (tree.nodeTag(node) == .assign and isName(tree, tree.nodeData(node).node_and_node[0], name)) return true;
        }
    }
    return false;
}

/// Whether a token of `node` is the name `name`.
fn mentions(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    for (tree.firstToken(node)..tree.lastToken(node) + 1) |token| {
        if (tree.tokenTag(@intCast(token)) == .identifier and std.mem.eql(u8, tree.tokenSlice(@intCast(token)), name)) return true;
    }
    return false;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col local <- what fails, release`, in source order, with `errdefer`
/// after it when the hint says one.
fn expectLeaks(source: [:0]const u8, expected: []const u8) !void {
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
        const l = finding.detail.leak;
        const errdefer_hint = std.mem.find(u8, finding.hint, "`errdefer") != null;
        try out.writer.print("{d}:{d} {s} <- {s}, {s}{s}\n", .{ loc.line + 1, loc.column + 1, l.local, l.fails, l.release, if (errdefer_hint) " errdefer" else "" });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a local released by hand after something that can fail (#112)" {
    try expectLeaks(
        \\const posix = std.posix;
        \\const c = @cImport({});
        \\fn insert(gpa: Allocator, v: u8) !void { var stmt = try prepare(gpa); try stmt.bind(v); stmt.finalize(); }
        \\fn write(gpa: Allocator, file: File, n: usize) !void { const buf = try gpa.alloc(u8, n); try file.writeAll(buf); gpa.free(buf); }
        \\fn sync(path: []const u8) !void { const fd = try posix.open(path, .{}, 0); try posix.fsync(fd); posix.close(fd); }
        \\fn read(dir: Dir, io: Io, bad: bool) !void { var file = try dir.openFile(io, "a", .{}); if (bad) return error.Bad; file.close(io); }
        \\fn caught(gpa: Allocator) !void { var x = try make(gpa); flush() catch |err| { log(err); return err; }; x.deinit(); }
        \\fn rows(r: Self, rs: []const Row) !void { var stmt = try r.conn.prepare(sql); for (rs) |row| try bindRow(&stmt, row); stmt.finalize(); }
        \\fn two(gpa: Allocator) !void { var list: List = .empty; try list.append(gpa, 1); try list.append(gpa, 2); list.deinit(gpa); }
        \\fn arena(gpa: Allocator) !void { var state = std.heap.ArenaAllocator.init(gpa); const a = state.allocator(); try build(a); state.deinit(); }
        \\fn made(gpa: Allocator, io: Io) !void { const link = try gpa.create(Link); try link.init(io); gpa.destroy(link); }
        \\fn sqlite(db: *Db) !void { const stmt = try prepare(db); try step(stmt); _ = c.sqlite3_finalize(stmt); }
        \\fn api(schema: Schema) !void { var stored = try schema.create(.{ .avro = true }); try more(); stored.deinit(); }
        \\fn handed(gpa: Allocator, ok: bool) !Thing { var x = try make(gpa); if (ok) return x; try more(); x.deinit(); return error.No; }
    ,
        \\3:71 stmt <- stmt.bind, stmt.finalize()
        \\4:90 buf <- file.writeAll, gpa.free(buf)
        \\5:76 fd <- posix.fsync, posix.close(fd)
        \\6:98 file <- error.Bad, file.close(io)
        \\7:90 x <- err, x.deinit()
        \\8:94 stmt <- bindRow, stmt.finalize()
        \\9:82 list <- list.append, list.deinit(gpa)
        \\10:110 state <- build, state.deinit()
        \\11:76 link <- link.init, gpa.destroy(link)
        \\12:58 stmt <- step, c.sqlite3_finalize(stmt)
        \\13:83 stored <- more, stored.deinit()
        \\14:87 x <- more, x.deinit() errdefer
        \\
    );
}

test "not reported: covered, released on the way out, after, not made here, moved, an arena, a check" {
    try expectLeaks(
        \\fn deferred(gpa: Allocator, v: u8) !void { var stmt = try prepare(gpa); errdefer stmt.finalize(); try stmt.bind(v); stmt.finalize(); }
        \\fn restored(self: *S) !void { var snap = try self.defs.snapshot(); errdefer self.defs.restore(&snap); try self.add(); snap.deinit(); }
        \\fn onTheWayOut(gpa: Allocator, bad: bool) !void { var stmt = try prepare(gpa); if (bad) { stmt.finalize(); return error.Bad; } stmt.finalize(); }
        \\fn plainReturn(gpa: Allocator, done: bool) !void { var stmt = try prepare(gpa); if (done) return; stmt.finalize(); }
        \\fn after(gpa: Allocator) !void { var stmt = try prepare(gpa); stmt.finalize(); try more(); }
        \\fn lookup(map: *Map, k: u32) !void { const slot = map.get(k) orelse return error.Missing; try more(); slot.deinit(); }
        \\fn view(self: *L, gpa: Allocator, n: usize) !void { const old = self.allocatedSlice(); const new = try gpa.alloc(u8, n); gpa.free(old); self.items = new; }
        \\fn reassigned(gpa: Allocator) !void { var buf = try gpa.alloc(u8, 4); buf = try gpa.realloc(buf, 8); try more(); gpa.free(buf); }
        \\fn stored(self: *S, gpa: Allocator, keep: bool) !void { var stmt = try prepare(gpa); if (keep) { self.stmt = stmt; try more(); return; } stmt.finalize(); }
        \\fn returned(p: []const u8, match: bool) !?Deferred { var face = try Face.init(p); if (match) return try wrap(face); face.deinit(); return null; }
        \\fn arenaList(p: *P) !void { var cells: List = .empty; try cells.append(p.arena, 1); try more(); cells.deinit(p.arena); }
        \\fn arenaMade(ctx: Ctx) !void { var layout = std.heap.ArenaAllocator.init(ctx.arena); const a = layout.allocator(); try draw(a); layout.deinit(); }
        \\fn checked(gpa: Allocator) !void { var x = try make(gpa); try std.testing.expect(x.ok); try expectEqual(1, x.n); x.deinit(); }
        \\fn firstUse(gpa: Allocator) !void { var list: List = .empty; try list.append(gpa, 1); use(list); list.deinit(gpa); }
        \\fn pool(self: *G) !void { const reg = try self.allocReg(); try self.emit(reg); self.codegen.freeGeneral(reg); }
        \\fn builder(ctx: *Ctx) !void { var scope = try push(ctx); try scope.add(1); try scope.finalize(); }
        \\fn initOnly(gpa: Allocator, io: Io) !void { const link = try gpa.create(Link); try link.init(io); link.deinit(); }
        \\fn words(gpa: Allocator) !void { var x = try make(gpa); try more(); x.closest(); x.freeze(); }
        \\fn handedIo(file: File) !void { const io = try makeIo(); try more(); file.close(io); }
        \\test "held" { var x = try make(std.testing.allocator); try more(); x.deinit(); }
    , "");
}

test "an error an else capture returns before the release (#118)" {
    try expectLeaks(
        \\fn run(gpa: Allocator, v: u8) !bool { var stmt = try prepare(gpa, v); const done = if (stmt.step()) |d| d else |err| return err; stmt.finalize(); return done; }
    ,
        \\1:118 stmt <- err, stmt.finalize()
        \\
    );
}
