//! Rule nine, twice: a deferred release also written out by hand, where
//! both run. An errdefer's, on a path that then fails:
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
//! And a defer's, which needs no failure (#212):
//!
//!     const fd = try listen(address);
//!     defer close(fd);
//!     try expect(accepts(fd));
//!     close(fd); // the defer closes fd again when the block ends
//!
//! A defer runs however its block is left, so every run closes `fd` twice.
//! The second close of a descriptor is harmless only while nobody has been
//! given its number in between: with another thread opening sockets or
//! files, it closes theirs, and a second `free` or `destroy` is undefined
//! like any other.
//!
//! What releases is the deferred call, one whose name says so (a `free`,
//! `destroy`, `deinit`, `close`, `unmap` or `release` of some kind:
//! `gpa.free`, `closeHandle`, `deinitAll`), written again as a statement
//! after it in its block, the same text but for whitespace, not in a
//! `defer` or `errdefer`.
//!
//! Under an errdefer it is reported when, after that statement and on its
//! path, the function fails before it leaves another way: a `try`, a
//! `return error.X`, or a `return` of what a `catch` or an `else |err|`
//! caught. Not when it is followed by a plain `return`, `break` or
//! `continue`, which is correct, since the errdefer does not run; nor for a
//! failure on another branch, or one the syntax cannot see, such as
//! `return f()` with no `try`, whose type it does not know; nor in a `test`
//! block, where a failure ends the test.
//!
//! Under a defer it is reported, each time it is written, when the way on
//! from it leaves the defer's block: by its end, a `return`, or a `break`
//! or `continue` out of it. In a `test` block too, since the defer runs
//! when the test passes. Not when a statement on the way takes the address
//! of a name the call is handed or is called on (`r.get(&c)`), through
//! which it can be made again, or never returns (`unreachable`, `@panic`,
//! a call of an `exit`, `abort`, `panic` or `fatal`, or of a function of
//! the file declared `noreturn`), since no defer runs then; nor after a
//! `continue` of a labeled `switch`, whose way on the rule does not follow.
//!
//! Under either, not reported: one before a statement, on its way out of
//! the block, that assigns to a name the call is handed or is called on,
//! so that the deferred call releases something else; a call safe to run
//! twice (`shrinkRetainingCapacity`, a restore); a function of the file
//! that stores to what it frees, one of its body's statements assigning
//! anything but `undefined` to something that is not a local of its own
//! (`self.* = .{};`, `self.fd = null;`), so the second call frees nothing,
//! found by its name, through its type, or as a method, the receiver's
//! type shown by its declaration or by what made it (`T{ ... }`, a call of
//! a function of the file, by what that is declared to return, a local
//! `struct`); the `close` of a `std.Io.Queue`, which std documents as
//! idempotent, where the file writes the queue's type; and a free inside
//! `if (x.len == 0)` for the `x` it is handed, which frees nothing either
//! time.
//!
//! A release that is no function of the file is read where it is
//! declared, when that file is checked in the same run (#216): a function
//! reached through the constants that import it (`pool.release(conn)`),
//! or a method of a type another file declares, the receiver's type shown
//! by its declaration (`var s: Sock`, `s: *Sock`) or by the call that made
//! it (`try Sock.open(...)`). It is not reported when it stores to what
//! it frees there, nor when it leads to a file imported by path that is
//! not among those checked, which cannot be read. Not followed: a type
//! from a module imported by name, which only the build maps to a file,
//! and what a method of a parameter or a field returns; a release of
//! those is reported, as one of the standard library's is.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
const grow = @import("grow.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");
const unlock = @import("unlock.zig");
const unrun = @import("unrun.zig");

/// Appends a finding for every deferred release also written out by hand
/// where both run: an errdefer's on a path that then fails, a defer's
/// wherever its block is then left. Everything is allocated with `arena`.
/// `elsewhere`, when the run checks other files with this one, says what
/// their functions do and how this file's names reach them.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding), elsewhere: ?Elsewhere) Allocator.Error!void {
    var parents: []const Node.OptionalIndex = &.{};
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const plain = switch (tag) {
            .@"errdefer" => false,
            .@"defer" => true,
            else => continue,
        };
        const defer_node: Node.Index = @fromBackingInt(@intCast(i));
        var deferred = tree.nodeData(defer_node).node;
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
        const t: types.Types = .{ .tree = tree, .parents = parents };
        // A failure ends a test, but a plain defer runs when it passes too.
        if (!plain and inTest(tree, parents, defer_node)) continue;
        if (try safeTwice(arena, t, call.ast.fn_expr, elsewhere)) continue;
        // What the call is handed: its arguments, and the receiver of a
        // method (`current` of `current.close(io)`).
        var handed: std.ArrayList(Node.Index) = .empty;
        try handed.appendSlice(arena, call.ast.params);
        if (tree.nodeTag(call.ast.fn_expr) == .field_access) try handed.append(arena, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
        const release: Deferred = .{
            .arena = arena,
            .t = t,
            .plain = plain,
            .node = defer_node,
            .call = deferred,
            .block = parents[@backingInt(defer_node)].unwrap() orelse continue,
            .handed = handed.items,
        };
        try release.byHand(findings);
    }
}

const errdefer_hint = "the errdefer above runs again when this path fails; drop this one and let the errdefer do it";
const defer_hint = "the defer above runs however its block is left; drop this one, or to release here, make the defer conditional (`defer if (open) ...`) and clear what it tests";

/// A `defer` or `errdefer` that runs one release.
const Deferred = struct {
    arena: Allocator,
    t: types.Types,
    /// A `defer`, which runs however its block is left, where an
    /// `errdefer` runs only when the function fails.
    plain: bool,
    node: Node.Index,
    /// The call it runs.
    call: Node.Index,
    /// The block it is a statement of.
    block: Node.Index,
    /// What the call is handed.
    handed: []const Node.Index,

    /// Appends a finding for the same call written as a statement after
    /// it in its block, where the deferred one then runs as well: the
    /// first such for an errdefer, each for a defer.
    fn byHand(d: Deferred, findings: *std.ArrayList(Finding)) Allocator.Error!void {
        const tree = d.t.tree;
        const parents = d.t.parents;
        const text = try squeeze(d.arena, tree.getNodeSource(d.call));
        var nodes: std.ArrayList(Node.Index) = .empty;
        try within(d.arena, tree, d.block, &nodes);
        for (nodes.items) |node| {
            if (tree.nodeMainToken(node) <= tree.nodeMainToken(d.node)) continue;
            if (!isStatement(tree, parents, node)) continue;
            if (!std.mem.eql(u8, try squeeze(d.arena, tree.getNodeSource(node)), text)) continue;
            if (onlyWhenEmpty(tree, parents, node, d.block, d.handed)) continue;
            const fails = try d.runsToo(node) orelse continue;
            try findings.append(d.arena, .{
                .offset = tree.tokenStart(tree.firstToken(node)),
                .hint = if (d.plain) defer_hint else errdefer_hint,
                .detail = .{ .twice = .{ .call = tree.getNodeSource(node), .fails = fails } },
            });
            if (!d.plain) break;
        }
    }

    /// Whether the deferred call runs as well as `statement`, the same
    /// call by hand: for an errdefer, what fails after it, as the message
    /// says it; for a defer, which needs no failure, nothing.
    fn runsToo(d: Deferred, statement: Node.Index) Allocator.Error!?[]const u8 {
        if (d.plain) return if (try leftReleased(d.arena, d.t, statement, d.block, d.handed)) "" else null;
        const point = try failsAfter(d.arena, d.t.tree, d.t.parents, statement, d.block, d.handed) orelse return null;
        return try what(d.arena, d.t.tree, point);
    }
};

/// The name of the function `fn_expr` calls: `free` of `gpa.free`.
fn calledName(tree: *const Ast, fn_expr: Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(fn_expr)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(fn_expr)),
        .field_access => tree.tokenSlice(tree.nodeData(fn_expr).node_and_token[1]),
        else => null,
    };
}

/// Whether the function `fn_expr` names releases what it is handed, by its
/// name: a `free`, `destroy`, `deinit`, `close`, `unmap` or `release` of
/// some kind (`gpa.free`, `closeHandle`, `deinitAll`). A call run twice
/// that is safe to run twice, such as `shrinkRetainingCapacity` or a
/// restore, is no bug.
pub fn releases(tree: *const Ast, fn_expr: Node.Index) bool {
    return releasesByName(calledName(tree, fn_expr) orelse return false);
}

fn releasesByName(name: []const u8) bool {
    var lower: [64]u8 = undefined;
    if (name.len > lower.len) return false;
    const folded = std.ascii.lowerString(&lower, name);
    for ([_][]const u8{ "free", "destroy", "deinit", "close", "unmap", "release" }) |word| {
        if (std.mem.indexOf(u8, folded, word) != null) return true;
    }
    return false;
}

/// Whether the release `fn_expr` names frees nothing the second time, as
/// far as the files checked show: the `close` of a `std.Io.Queue`, or a
/// function that stores to what it frees, of this file or, when it is
/// not one of this file's, of another that `elsewhere` leads to.
fn safeTwice(arena: Allocator, t: types.Types, fn_expr: Node.Index, elsewhere: ?Elsewhere) Allocator.Error!bool {
    if (closesQueue(t, fn_expr)) return true;
    if (t.callee(fn_expr)) |found| return clears(t.tree, found[0]);
    const e = elsewhere orelse return false;
    return e.safe(arena, t, fn_expr);
}

/// A function a file declares, as a release written in another file needs
/// to know it: what the run reads of each file before any is checked.
pub const Fn = struct {
    /// The type, declared at the top of the file, that it is a member of.
    /// Empty for a function of the file itself.
    container: []const u8,
    name: []const u8,
    /// It releases, and stores to what it frees, as `clears` reads one.
    clears: bool,
    /// The type of the file it is declared to return, as `container`
    /// names one. Null for any other type.
    returns: ?[]const u8,
};

/// The functions of `tree` that a release in another file may lead to,
/// of the file itself and of each type it declares at the top: those
/// that release and store to what they free, and those that return a type
/// of the file, which say what a local they make is. Nothing for a file
/// with no release that stores to what it frees, which is most files.
/// `gpa` is for what it needs while it reads; what it returns is allocated
/// with `arena`, every name copied.
pub fn functions(gpa: Allocator, arena: Allocator, tree: *const Ast) Allocator.Error![]const Fn {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    var reader: Reader = .{ .scratch = scratch_state.allocator(), .tree = tree };
    try reader.listContainers();
    for (reader.containers.items) |container| try reader.read(container);
    if (!reader.stores) return &.{};
    const copied = try arena.alloc(Fn, reader.found.items.len);
    for (copied, reader.found.items) |*to, from| to.* = .{
        .container = try arena.dupe(u8, from.container),
        .name = try arena.dupe(u8, from.name),
        .clears = from.clears,
        .returns = if (from.returns) |name| try arena.dupe(u8, name) else null,
    };
    return copied;
}

/// Reads a file's functions for `functions`, into memory of its own.
const Reader = struct {
    scratch: Allocator,
    tree: *const Ast,
    /// The file, then each type it declares at the top.
    containers: std.ArrayList(Container) = .empty,
    /// Made when a return type is first asked about.
    types: ?types.Types = null,
    found: std.ArrayList(Fn) = .empty,
    /// Whether a function found releases and stores to what it frees.
    stores: bool = false,

    const Container = struct { node: Node.Index, name: []const u8 };

    fn listContainers(r: *Reader) Allocator.Error!void {
        const tree = r.tree;
        try r.containers.append(r.scratch, .{ .node = .root, .name = "" });
        for (tree.rootDecls()) |member| {
            const decl = tree.fullVarDecl(member) orelse continue;
            const value = decl.ast.init_node.unwrap() orelse continue;
            var buffer: [2]Node.Index = undefined;
            if (tree.fullContainerDecl(&buffer, value) == null) continue;
            try r.containers.append(r.scratch, .{ .node = value, .name = tree.tokenSlice(decl.ast.mut_token + 1) });
        }
    }

    /// Appends the functions of `container` that `functions` keeps.
    fn read(r: *Reader, container: Container) Allocator.Error!void {
        const tree = r.tree;
        var buffer: [2]Node.Index = undefined;
        for (tree.fullContainerDecl(&buffer, container.node).?.ast.members) |member| {
            if (tree.nodeTag(member) != .fn_decl) continue;
            var proto_buffer: [1]Node.Index = undefined;
            const proto = tree.fullFnProto(&proto_buffer, tree.nodeData(member).node_and_node[0]).?;
            const name = tree.tokenSlice(proto.name_token orelse continue);
            const stores = releasesByName(name) and clears(tree, member);
            const returns = try r.typeReturned(member);
            if (!stores and returns == null) continue;
            r.stores = r.stores or stores;
            try r.found.append(r.scratch, .{ .container = container.name, .name = name, .clears = stores, .returns = returns });
        }
    }

    /// The type of the file `fn_decl` is declared to return, by its name
    /// among `containers`.
    fn typeReturned(r: *Reader, fn_decl: Node.Index) Allocator.Error!?[]const u8 {
        const type_expr = types.returned(r.tree, fn_decl) orelse return null;
        if (r.types == null) r.types = try .init(r.scratch, r.tree);
        const made = r.types.?.containerOf(type_expr, 0) orelse return null;
        for (r.containers.items) |container| {
            if (container.node == made) return container.name;
        }
        return null;
    }
};

/// What the run knows of the other files checked with this one: each
/// file's functions, by its place among them, where a name written in
/// this one leads, and this file's place.
pub const Elsewhere = struct {
    functions: []const []const Fn,
    resolver: *unrun.Resolver,
    file: usize,

    /// Whether the release `fn_expr` names, which is no function of this
    /// file, frees nothing the second time, as far as the other files
    /// show: a function another file checked declares that stores to what
    /// it frees, reached through the constants that import it
    /// (`pool.release(conn)`), or a method of a type one declares, the
    /// receiver's type shown by its declaration (`var s: Sock`) or by the
    /// call that made it (`try Sock.open(...)`). One that leads to a file
    /// imported by path that is not among those checked cannot be read,
    /// and is taken to be safe: the rule misses rather than reports.
    fn safe(e: Elsewhere, arena: Allocator, t: types.Types, fn_expr: Node.Index) Allocator.Error!bool {
        const tree = t.tree;
        switch (try e.leadsTo(arena, tree, fn_expr)) {
            .unchecked => return true,
            .place => |place| if (e.declared(place)) |f| return f.clears,
            .nowhere => {},
        }
        if (tree.nodeTag(fn_expr) != .field_access) return false;
        const receiver, const name = tree.nodeData(fn_expr).node_and_token;
        return switch (try e.typeOf(arena, t, receiver)) {
            .unchecked => true,
            .type => |owner| (e.find(owner.file, owner.name, tree.tokenSlice(name)) orelse return false).clears,
            .nowhere => false,
        };
    }

    /// Where a name of this file leads, of what this rule reads there.
    const Lead = union(enum) {
        /// To a declaration of another file checked.
        place: unrun.Place,
        /// To a file imported by path that is not among those checked.
        unchecked,
        /// Nowhere the files show: this file itself, which `function`
        /// reads, the standard library, a local.
        nowhere,
    };

    /// What a receiver's type is, of what this rule reads of it.
    const Owner = union(enum) {
        /// A type another file checked declares, by its name there, as
        /// `Fn.container` names one.
        type: struct { file: usize, name: []const u8 },
        /// One a file that is not among those checked declares.
        unchecked,
        /// Nothing the files show.
        nowhere,
    };

    /// The type of `receiver`, where another file declares it: as this
    /// file writes it, a pointer to it included, or, for a local with none
    /// written, what the function that made it is declared to return.
    fn typeOf(e: Elsewhere, arena: Allocator, t: types.Types, receiver: Node.Index) Allocator.Error!Owner {
        const tree = t.tree;
        if (t.typeOf(receiver, 0)) |type_expr| {
            return switch (try e.leadsTo(arena, tree, types.pointee(tree, type_expr) orelse type_expr)) {
                .unchecked => .unchecked,
                .nowhere => .nowhere,
                .place => |place| switch (place.names.len) {
                    0 => .{ .type = .{ .file = place.file, .name = "" } },
                    1 => .{ .type = .{ .file = place.file, .name = place.names[0] } },
                    else => .nowhere,
                },
            };
        }
        if (tree.nodeTag(receiver) != .identifier) return .nowhere;
        const init = t.localInit(receiver) orelse return .nowhere;
        const made = if (tree.nodeTag(init) == .@"try") tree.nodeData(init).node else init;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, made) orelse return .nowhere;
        const place = switch (try e.leadsTo(arena, tree, call.ast.fn_expr)) {
            .unchecked => return .unchecked,
            .nowhere => return .nowhere,
            .place => |place| place,
        };
        const returns = (e.declared(place) orelse return .nowhere).returns orelse return .nowhere;
        return .{ .type = .{ .file = place.file, .name = returns } };
    }

    /// Where `node`, a name and the fields after it, leads.
    fn leadsTo(e: Elsewhere, arena: Allocator, tree: *const Ast, node: Node.Index) Allocator.Error!Lead {
        var fields: std.ArrayList([]const u8) = .empty;
        var root = node;
        while (tree.nodeTag(root) == .field_access) {
            const lhs, const field = tree.nodeData(root).node_and_token;
            try fields.insert(arena, 0, tree.tokenSlice(field));
            root = lhs;
        }
        if (tree.nodeTag(root) != .identifier) return .nowhere;
        const lead = try e.resolver.leadOf(e.file, .{
            .root = .{ .name = tree.tokenSlice(tree.nodeMainToken(root)) },
            .fields = fields.items,
            .use = .plain,
        }) orelse return .nowhere;
        return switch (lead) {
            .unchecked => .unchecked,
            .place => |place| if (place.file == e.file) .nowhere else .{ .place = place },
        };
    }

    /// The function at `place`: one of the file itself, or of a type it
    /// declares at the top.
    fn declared(e: Elsewhere, place: unrun.Place) ?Fn {
        return switch (place.names.len) {
            1 => e.find(place.file, "", place.names[0]),
            2 => e.find(place.file, place.names[0], place.names[1]),
            else => null,
        };
    }

    /// The function `name` that `file` declares in `container`, as
    /// `Fn.container` names it.
    fn find(e: Elsewhere, file: usize, container: []const u8, name: []const u8) ?Fn {
        for (e.functions[file]) |f| {
            if (std.mem.eql(u8, f.container, container) and std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

/// Whether `fn_expr` is the `close` of a `std.Io.Queue`, the one release
/// a queue has, where the file writes the receiver's type. std documents
/// it as idempotent: it marks the queue closed and wakes who waits on it,
/// and releases nothing.
fn closesQueue(t: types.Types, fn_expr: Node.Index) bool {
    const tree = t.tree;
    if (tree.nodeTag(fn_expr) != .field_access) return false;
    const type_expr = t.typeOf(tree.nodeData(fn_expr).node_and_token[0], 0) orelse return false;
    return std.mem.indexOf(u8, tree.getNodeSource(type_expr), "Io.Queue(") != null;
}

/// Whether `fn_decl`, a function that releases, stores to what it frees,
/// so that a second call finds nothing there: one of its body's
/// statements assigns anything but `undefined` to something that is not
/// a local of its own (`self.* = .{};`, `self.fd = null;`, a variable of
/// the file).
pub fn clears(tree: *const Ast, fn_decl: Node.Index) bool {
    var buffer: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, tree.nodeData(fn_decl).node_and_node[1]) orelse return false;
    for (statements) |statement| {
        if (tree.nodeTag(statement) != .assign) continue;
        const lhs, const rhs = tree.nodeData(statement).node_and_node;
        if (tree.nodeTag(rhs) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(rhs)), "undefined")) continue;
        const root = kept.rootOf(tree, lhs) orelse continue;
        const name = tree.tokenSlice(tree.nodeMainToken(root));
        // `_ = close(fd);` stores nothing.
        if (std.mem.eql(u8, name, "_")) continue;
        if (!declares(tree, statements, name)) return true;
    }
    return false;
}

/// Whether one of `statements` declares the local `name`.
fn declares(tree: *const Ast, statements: []const Node.Index, name: []const u8) bool {
    for (statements) |statement| {
        const decl = tree.fullVarDecl(statement) orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)) return true;
    }
    return false;
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
pub fn failsAfter(arena: Allocator, tree: *const Ast, parents: []const Node.OptionalIndex, statement: Node.Index, block: Node.Index, handed: []const Node.Index) Allocator.Error!?Node.Index {
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
        if (isHanded(tree, tree.nodeData(n).node_and_node[0], handed)) return true;
    }
    return false;
}

/// Whether `node` takes the address of a name among `handed`
/// (`r.get(&c)`), through which what was released can be made again.
fn takesAddress(arena: Allocator, tree: *const Ast, node: Node.Index, handed: []const Node.Index) Allocator.Error!bool {
    var nodes: std.ArrayList(Node.Index) = .empty;
    try within(arena, tree, node, &nodes);
    for (nodes.items) |n| {
        if (tree.nodeTag(n) != .address_of) continue;
        if (isHanded(tree, tree.nodeData(n).node, handed)) return true;
    }
    return false;
}

/// Whether `place` is reached from the variable one of `handed` is
/// reached from: `state.rows` for `&state`, `self.fd` for `self.conn`.
fn isHanded(tree: *const Ast, place: Node.Index, handed: []const Node.Index) bool {
    const root = kept.rootOf(tree, place) orelse return false;
    const name = tree.tokenSlice(tree.nodeMainToken(root));
    for (handed) |argument| {
        const of = if (tree.nodeTag(argument) == .address_of) tree.nodeData(argument).node else argument;
        const handed_root = kept.rootOf(tree, of) orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(handed_root)), name)) return true;
    }
    return false;
}

/// Whether, after `statement`, a release written by hand, `block` is left
/// with what it released still in the names it was `handed`, so that a
/// defer of `block` releases it again: the way from `statement` reaches
/// the end of `block`, a `return`, or a `break` or `continue` that leaves
/// `block`, before a statement that assigns to one of those names or
/// takes its address, and before one that never returns, where no defer
/// runs. A `break` or `continue` that stays inside `block` goes on after
/// the loop or block it leaves; one whose target the syntax does not
/// show, a `continue` of a labeled `switch`, is taken to be safe.
fn leftReleased(arena: Allocator, t: types.Types, statement: Node.Index, block: Node.Index, handed: []const Node.Index) Allocator.Error!bool {
    const tree = t.tree;
    // The loop or block a jump on the way leaves: what is between is not
    // on the way.
    var jump: ?Node.Index = null;
    var child = statement;
    var up = t.parents[@backingInt(statement)].unwrap();
    while (up) |parent| : ({
        child = parent;
        up = t.parents[@backingInt(parent)].unwrap();
    }) {
        if (jump) |target| {
            if (parent == block) return true;
            if (parent == target) jump = null;
            continue;
        }
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, parent) orelse continue;
        const at = std.mem.findScalar(Node.Index, statements, child) orelse return false;
        switch (try following(arena, t, statements[at + 1 ..], handed)) {
            .spared => return false,
            .leaves => return true,
            .jumps => |target| jump = target,
            .goes_on => {},
        }
        if (parent == block) return true;
    }
    return false;
}

/// What the statements after a release by hand come to first.
const Following = union(enum) {
    /// What was released is made again, or nothing runs after: the defer
    /// releases something else, or does not run.
    spared,
    /// A `return`: every defer runs.
    leaves,
    /// A `break` or `continue`, out of this loop or block.
    jumps: Node.Index,
    /// The end of the statements.
    goes_on,
};

/// What `statements`, those after a release by hand in a block on its way
/// out, come to first, for the names the release was `handed`.
fn following(arena: Allocator, t: types.Types, statements: []const Node.Index, handed: []const Node.Index) Allocator.Error!Following {
    const tree = t.tree;
    for (statements) |statement| {
        if (try reassigns(arena, tree, statement, handed)) return .spared;
        if (try takesAddress(arena, tree, statement, handed)) return .spared;
        if (neverReturns(t, statement)) return .spared;
        switch (tree.nodeTag(statement)) {
            .@"return" => return .leaves,
            .@"break", .@"continue" => return if (grow.jumpTarget(tree, t.parents, statement)) |target| .{ .jumps = target } else .spared,
            else => {},
        }
    }
    return .goes_on;
}

/// Whether `statement` never returns, so that no defer runs after it:
/// `unreachable`, `@panic`, a call of an `exit`, `abort`, `panic` or
/// `fatal` (`std.process.exit(1)`), or of a function of the file declared
/// `noreturn`.
fn neverReturns(t: types.Types, statement: Node.Index) bool {
    const tree = t.tree;
    switch (tree.nodeTag(statement)) {
        .unreachable_literal => return true,
        .builtin_call_two, .builtin_call_two_comma => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(statement)), "@panic"),
        else => {},
    }
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, statement) orelse return false;
    const name = calledName(tree, call.ast.fn_expr) orelse return false;
    for ([_][]const u8{ "exit", "abort", "panic", "fatal" }) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    const fn_decl = (t.callee(call.ast.fn_expr) orelse return false)[0];
    const return_type = types.returned(tree, fn_decl) orelse return false;
    return std.mem.eql(u8, tree.getNodeSource(return_type), "noreturn");
}

/// The first node of `statement` that makes the function fail: a `try`, a
/// `return error.X`, or a `return` of what a capture around it caught.
fn failing(arena: Allocator, tree: *const Ast, parents: []const Node.OptionalIndex, statement: Node.Index) Allocator.Error!?Node.Index {
    var nodes: std.ArrayList(Node.Index) = .empty;
    try within(arena, tree, statement, &nodes);
    var first: ?Node.Index = null;
    for (nodes.items) |node| {
        const fails = switch (tree.nodeTag(node)) {
            .@"try" => true,
            .@"return" => unlock.returnsError(tree, parents, node),
            else => false,
        };
        if (!fails) continue;
        if (first == null or tree.nodeMainToken(node) < tree.nodeMainToken(first.?)) first = node;
    }
    return first;
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
/// `line:col call <- what fails`, or `<- defer` for a defer's, which needs
/// no failure, in source order.
fn expectTwice(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var findings: std.ArrayList(Finding) = .empty;
    try check(arena_state.allocator(), &tree, &findings, null);
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
        try out.writer.print("{d}:{d} {s} <- {s}\n", .{ loc.line + 1, loc.column + 1, t.call, if (t.fails.len == 0) "defer" else t.fails });
    }
    try expect.findings(@src(), expected, out.written());
}

test "an errdefer's free written out by hand on a path that then fails (#61)" {
    try expectTwice(
        \\fn open(gpa: Allocator, fd: i32) !*Conn { const conn = try gpa.create(Conn); errdefer gpa.destroy(conn); if (fd < 0) { gpa.destroy(conn); return error.BadConfig; } return conn; }
        \\fn map(handle: Handle, size: usize) !*Header { errdefer platform.closeHandle(handle, true); const base = try platform.map(handle, size); errdefer platform.unmap(base, size); if (!commit(base)) { platform.unmap(base, size); platform.closeHandle(handle, true); return error.OutOfMemory; } return @ptrCast(base); }
        \\fn caught(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); use(b) catch |err| { gpa.free(b); return err; }; }
        \\fn tried(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); if (b.len == 4) { gpa.free(b); try report(); } }
        \\fn spaced(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free( b ); if (bad()) { gpa.free(b); return error.Bad; } }
        \\fn bare(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); if (bad()) gpa.free(b); try more(); }
        \\fn opened(gpa: Allocator) !*Conn { const conn = try gpa.create(Conn); errdefer gpa.destroy(conn); if (open()) |fd| { conn.fd = fd; } else |err| { gpa.destroy(conn); return err; } return conn; }
    ,
        \\1:120 gpa.destroy(conn) <- it returns error.BadConfig
        \\2:196 platform.unmap(base, size) <- it returns error.OutOfMemory
        \\2:224 platform.closeHandle(handle, true) <- it returns error.OutOfMemory
        \\3:110 gpa.free(b) <- it returns err
        \\4:106 gpa.free(b) <- report fails
        \\5:104 gpa.free(b) <- it returns error.Bad
        \\6:98 gpa.free(b) <- more fails
        \\7:147 gpa.destroy(conn) <- it returns err
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
        \\fn pronged(gpa: Allocator, kind: Kind) !void { const b = try gpa.alloc(u8, 4); errdefer gpa.free(b); switch (kind) { .a => gpa.free(b), .b => {} } try more(); }
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

test "a defer's release written out by hand, however its block is then left (#212)" {
    try expectTwice(
        \\fn file(io: Io, dir: Dir) !void { const f = try dir.openFile(io, "x", .{}); defer f.close(io); f.close(io); }
        \\fn early(gpa: Allocator, skip: bool) !void { const b = try gpa.alloc(u8, 4); defer gpa.free(b); if (skip) { gpa.free(b); return; } try use(b); }
        \\fn each(gpa: Allocator, a: bool, c: bool) !void { const b = try gpa.alloc(u8, 4); defer gpa.free(b); if (a) { gpa.free(b); return; } if (c) { gpa.free(b); return error.Bad; } }
        \\fn turns(gpa: Allocator, items: []Item) !void { for (items) |it| { const b = try gpa.alloc(u8, 4); defer gpa.free(b); if (it.skip) { gpa.free(b); continue; } try keep(b); } }
        \\fn stops(gpa: Allocator, items: []Item) !void { for (items) |it| { const b = try gpa.alloc(u8, 4); defer gpa.free(b); if (it.last) { gpa.free(b); break; } try keep(b); } }
        \\fn inner(gpa: Allocator, items: []Item) !void { var b = try gpa.alloc(u8, 4); defer gpa.free(b); for (items) |it| { if (it.last) { gpa.free(b); break; } b = try gpa.realloc(b, 8); } }
        \\fn labeled(gpa: Allocator, skip: bool) !void { const b = try gpa.alloc(u8, 4); blk: { defer gpa.free(b); if (skip) { gpa.free(b); break :blk; } try use(b); } }
        \\fn braced(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); defer { gpa.free(b); } try use(b); gpa.free(b); try more(); }
        \\test "a descriptor" { const fd = socket(); defer close(fd); listen(fd); close(fd); }
    ,
        \\1:96 f.close(io) <- defer
        \\2:109 gpa.free(b) <- defer
        \\3:111 gpa.free(b) <- defer
        \\3:143 gpa.free(b) <- defer
        \\4:134 gpa.free(b) <- defer
        \\5:134 gpa.free(b) <- defer
        \\6:132 gpa.free(b) <- defer
        \\7:118 gpa.free(b) <- defer
        \\8:102 gpa.free(b) <- defer
        \\9:73 close(fd) <- defer
        \\
    );
}

test "not reported: a defer's release whose name is then made again, or that no defer runs after (#212)" {
    try expectTwice(
        \\fn usage() noreturn { std.process.exit(2); }
        \\fn again(gpa: Allocator) !void { var b = try gpa.alloc(u8, 4); defer gpa.free(b); gpa.free(b); b = try gpa.alloc(u8, 8); try use(b); }
        \\fn later(gpa: Allocator, grow: bool) !void { var b = try gpa.alloc(u8, 4); defer gpa.free(b); if (grow) { gpa.free(b); } b = try gpa.alloc(u8, 8); }
        \\fn turned(gpa: Allocator, items: []Item) !void { var b = try gpa.alloc(u8, 4); defer gpa.free(b); for (items) |it| { if (it.grow) { gpa.free(b); continue; } try keep(b); } b = try gpa.alloc(u8, 8); }
        \\fn remade(r: *Running) !void { var c: Client = undefined; defer c.close(); _ = try r.get(&c, "/a"); c.close(); _ = try r.get(&c, "/b"); }
        \\fn handed(gpa: Allocator) !void { var state: other.State = .{}; defer other.freeAll(&state, gpa); other.freeAll(&state, gpa); state.rows = try other.rows(gpa); }
        \\fn child(fd: i32) !void { defer close(fd); if (try fork() == 0) { close(fd); std.process.exit(0); } }
        \\fn dies(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); defer gpa.free(b); if (bad()) { gpa.free(b); @panic("bad"); } }
        \\fn never(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); defer gpa.free(b); if (bad()) { gpa.free(b); unreachable; } }
        \\fn told(gpa: Allocator) !void { const b = try gpa.alloc(u8, 4); defer gpa.free(b); if (bad()) { gpa.free(b); usage(); } }
        \\fn flagged(fd: i32) void { var open = true; defer if (open) close(fd); listen(fd); close(fd); open = false; }
        \\fn machine(gpa: Allocator, start: State) !void { const b = try gpa.alloc(u8, 4); defer gpa.free(b); sw: switch (start) { .a => { gpa.free(b); continue :sw .b; }, .b => {} } }
        \\fn several(gpa: Allocator) !void { const a = try gpa.alloc(u8, 4); const b = try gpa.alloc(u8, 4); defer { gpa.free(a); gpa.free(b); } gpa.free(a); }
    , "");
}

test "a release that stores to what it frees, and a queue's close, run twice safely (#212)" {
    try expectTwice(
        \\const Client = struct {
        \\    fd: ?i32 = null,
        \\    buf: []u8 = &.{},
        \\    fn close(self: *Client) void { if (self.fd) |fd| sys.close(fd); self.fd = null; }
        \\    fn deinit(self: *Client, gpa: Allocator) void { var n: usize = 0; n = self.buf.len; gpa.free(self.buf[0..n]); }
        \\    fn release(self: *Client) void { _ = sys.close(self.fd.?); }
        \\};
        \\const Index = struct {
        \\    rows: ?[]u8 = null,
        \\    fn open(gpa: Allocator) Allocator.Error!Index { return .{ .rows = try gpa.alloc(u8, 4) }; }
        \\    fn deinitIndex(self: *Index, gpa: Allocator) void { if (self.rows) |rows| gpa.free(rows); self.rows = null; self.names.clearAndFree(gpa); }
        \\};
        \\const Sub = struct {
        \\    queue: std.Io.Queue(u8),
        \\    pipe: other.Pipe,
        \\    fn run(self: *Sub, io: Io) void { defer self.queue.close(io); self.queue.close(io); }
        \\    fn stop(self: *Sub, io: Io) void { defer self.pipe.close(io); self.pipe.close(io); }
        \\};
        \\fn freeCluster(state: *State, gpa: Allocator) void { gpa.free(state.rows); state.rows = &.{}; }
        \\fn field(c: *Client) void { defer c.close(); c.close(); }
        \\fn local(gpa: Allocator) void { var c: Client = .{}; defer c.deinit(gpa); c.deinit(gpa); }
        \\fn discard(c: *Client) void { defer c.release(); c.release(); }
        \\fn returns(gpa: Allocator) !void { var index = try Index.open(gpa); defer index.deinitIndex(gpa); index.deinitIndex(gpa); }
        \\fn elsewhere(gpa: Allocator) !void { var index = try other.Index.open(gpa); defer index.deinitIndex(gpa); index.deinitIndex(gpa); }
        \\fn cluster(gpa: Allocator) void { var state: State = .{}; defer freeCluster(&state, gpa); freeCluster(&state, gpa); }
        \\fn static(gpa: Allocator) void { const S = struct { var last: ?[]u8 = null; fn deinit(a: Allocator) void { if (last) |d| a.free(d); last = null; } }; defer S.deinit(gpa); S.deinit(gpa); }
    ,
        \\17:67 self.pipe.close(io) <- defer
        \\21:75 c.deinit(gpa) <- defer
        \\22:50 c.release() <- defer
        \\24:107 index.deinitIndex(gpa) <- defer
        \\
    );
}

/// Runs the rule over `sources`, each a path and its source, checked
/// together as one run checks them, and compares one line per finding,
/// `path:line:col call <- what fails`, or `<- defer`, in their order.
fn expectTwiceAcross(sources: []const [2][:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const trees = try arena.alloc(Ast, sources.len);
    const summaries = try arena.alloc(unrun.Summary, sources.len);
    const declared = try arena.alloc([]const Fn, sources.len);
    var parsed: usize = 0;
    defer for (trees[0..parsed]) |*tree| tree.deinit(gpa);
    for (sources, trees, summaries, declared) |file, *tree, *summary, *fns| {
        tree.* = try Ast.parse(gpa, file[1], .{});
        parsed += 1;
        try std.testing.expectEqual(0, tree.errors.len);
        summary.* = try unrun.summarize(gpa, arena, try std.fs.path.resolveAlloc(arena, &.{file[0]}), tree);
        fns.* = try functions(gpa, arena, tree);
    }
    var resolver: unrun.Resolver = try .init(arena, summaries);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (sources, trees, 0..) |file, *tree, f| {
        var findings: std.ArrayList(Finding) = .empty;
        try check(arena, tree, &findings, .{ .functions = declared, .resolver = &resolver, .file = f });
        std.mem.sort(Finding, findings.items, {}, struct {
            fn before(_: void, a: Finding, b: Finding) bool {
                return a.offset < b.offset;
            }
        }.before);
        for (findings.items) |finding| {
            const loc = report.location(file[1], finding.offset);
            const t = finding.detail.twice;
            try out.writer.print("{s}:{d}:{d} {s} <- {s}\n", .{ file[0], loc.line + 1, loc.column + 1, t.call, if (t.fails.len == 0) "defer" else t.fails });
        }
    }
    try expect.findings(@src(), expected, out.written());
}

test "a release another file checked declares is read there, and one a file not checked declares is left (#216)" {
    try expectTwiceAcross(&.{
        .{
            "sock.zig",
            \\pub const Sock = struct {
            \\    fd: i32,
            \\    pub fn open() !Sock { return .{ .fd = 3 }; }
            \\    pub fn close(s: *Sock) void { if (s.fd < 0) return; sys.close(s.fd); s.fd = -1; }
            \\    pub fn deinit(s: *Sock) void { sys.close(s.fd); }
            \\};
            \\pub fn freeAll(state: *State, gpa: Allocator) void { gpa.free(state.rows); state.rows = &.{}; }
            \\pub fn destroyAll(state: *State, gpa: Allocator) void { gpa.free(state.rows); }
            \\
        },
        .{
            "Conn.zig",
            \\fd: i32,
            \\const Conn = @This();
            \\pub fn init() Conn { return .{ .fd = 3 }; }
            \\pub fn close(c: *Conn) void { sys.close(c.fd); c.fd = -1; }
            \\
        },
        .{ "lib.zig", "pub const sock = @import(\"sock.zig\");\n" },
        .{
            "use.zig",
            \\const Sock = @import("sock.zig").Sock;
            \\const sock = @import("sock.zig");
            \\const lib = @import("lib.zig");
            \\const Conn = @import("Conn.zig");
            \\const gone = @import("gone.zig");
            \\fn annotated() void { var s: Sock = .{ .fd = 3 }; defer s.close(); s.close(); }
            \\fn pointer(s: *Sock) void { defer s.close(); s.close(); }
            \\fn made() !void { var s = try Sock.open(); defer s.close(); s.close(); }
            \\fn through() !void { var s = try lib.sock.Sock.open(); defer s.close(); s.close(); }
            \\fn whole() void { var c = Conn.init(); defer c.close(); c.close(); }
            \\fn file(c: *Conn) void { defer c.close(); c.close(); }
            \\fn function(gpa: Allocator) void { var state: State = .{}; defer sock.freeAll(&state, gpa); sock.freeAll(&state, gpa); }
            \\fn failing(fail: bool) !void { var s: Sock = .{ .fd = 3 }; errdefer s.close(); s.close(); if (fail) return error.Failed; }
            \\fn unread(g: *gone.Gone) void { defer g.close(); g.close(); }
            \\fn unreadFunction(gpa: Allocator) void { var state: State = .{}; defer gone.freeAll(&state, gpa); gone.freeAll(&state, gpa); }
            \\fn frees(s: *Sock) void { defer s.deinit(); s.deinit(); }
            \\fn destroys(gpa: Allocator) void { var state: State = .{}; defer sock.destroyAll(&state, gpa); sock.destroyAll(&state, gpa); }
            \\fn failingFree(s: *Sock, fail: bool) !void { errdefer s.deinit(); s.deinit(); if (fail) return error.Failed; }
            \\fn standard(io: Io, f: std.Io.File) void { defer f.close(io); f.close(io); }
            \\fn untyped(io: Io, dir: Io.Dir) !void { const f = try dir.openFile(io, "x", .{}); defer f.close(io); f.close(io); }
            \\
        },
    },
        \\use.zig:16:45 s.deinit() <- defer
        \\use.zig:17:96 sock.destroyAll(&state, gpa) <- defer
        \\use.zig:18:67 s.deinit() <- it returns error.Failed
        \\use.zig:19:63 f.close(io) <- defer
        \\use.zig:20:102 f.close(io) <- defer
        \\
    );
}
