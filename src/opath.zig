//! Rule twenty-six, opath: a directory opened without `.iterate = true`,
//! then used for what needs it.
//!
//!     const d = try dir.openDir(io, sub, .{});
//!     defer d.close(io);
//!     const as_file: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
//!     try as_file.sync(io);
//!
//! On Linux, Zig opens a directory that is not for iterating with `O_PATH`
//! (`std/Io/Threaded.zig`, `dirOpenDirPosix`): a descriptor that names the
//! directory, good for opening what is under it and for `fstat`, and
//! nothing else. `fsync`, `getdents64`, `fchmod` and `fchown` of one are
//! `EBADF`, which std answers with `errnoBug`: a panic in Debug, and
//! `error.Unexpected` in the other modes. macOS has no `O_PATH`, so there
//! the same code works and its tests pass. A blob store that synced the
//! directory after renaming a new file into it failed every write of a new
//! file on Linux for days while every test on macOS passed (#208).
//!
//! What is reported is the call that opens it, `openDir`, `openDirAbsolute`,
//! `createDirPathOpen` or `tmpDir`, a local's initializer, when its options
//! are written there and leave `iterate` false, and later in the local's
//! block the directory is:
//!
//! - listed: `d.iterate()`, `d.iterateAssumeFirstIteration()`, `d.walk(...)`
//!   or `d.walkSelectively(...)`;
//! - synced: `sync` of a file made from its handle (`.{ .handle = d.handle,
//!   ... }`, as a local or in place), or `fsync(d.handle)` and
//!   `fdatasync(d.handle)` by any path;
//! - given new permissions or a new owner: `d.setPermissions(...)`,
//!   `d.setOwner(...)`, both of which std documents as needing `iterate`;
//! - or handed to a function of the same file that does one of these with
//!   the parameter it arrives in, a `Dir` by its type.
//!
//! A `tmpDir`'s directory is its `dir` field: `tmp.dir.iterate()`.
//!
//! Not reported: options held in a name or computed (`.{ .iterate =
//! recursive }`, `opts`), which the syntax does not show the value of; a
//! directory kept in a field or handed in, which only another function
//! shows the opening of; a local assigned again before the use, which may
//! by then be another directory; a function handed the directory that
//! hands it on again, since one call is followed and no further, or one
//! whose name two functions of the file have, since the call does not say
//! which; and a use `fstat` or a path under the directory serves (`stat`,
//! `openFile`, `access`, `close`), which an `O_PATH` descriptor allows.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
const ints = @import("ints.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const Use = Finding.Opath.Use;

/// Appends a finding for every directory a block opens without
/// `.iterate = true` and then uses for what needs it. Everything is
/// allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    // Most files open no directory: look before reading a node.
    for (std.enums.values(Opener)) |opener| {
        if (std.mem.find(u8, tree.source, @tagName(opener)) != null) break;
    } else return;
    var helpers: ?[]const Helper = null;
    for (0..tree.nodes.len) |i| {
        const block: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        for (statements, 0..) |statement, at| {
            const opened = pathOnly(tree, statement) orelse continue;
            // Read once, and only for a file that opens a directory so.
            if (helpers == null) helpers = try helpersOf(arena, tree);
            const need = try needIn(arena, tree, statements[at + 1 ..], opened.dir, helpers.?) orelse continue;
            try add(arena, tree, findings, opened, need);
        }
    }
}

/// The calls that open a directory, by the last name of what is called.
const Opener = enum { openDir, openDirAbsolute, createDirPathOpen, tmpDir };

/// A directory as the code names it: the local `d`, or `tmp.dir` for the
/// local `tmp` a `tmpDir` call made.
const Dir = struct {
    name: []const u8,
    /// Whether it is the `dir` field of `name`, a `TmpDir`.
    of_tmp: bool = false,

    /// Whether `node` is the directory: `d`, `(d)`, `&d`, `tmp.dir`.
    fn is(dir: Dir, tree: *const Ast, node: Node.Index) bool {
        var n = ints.unparen(tree, node);
        if (tree.nodeTag(n) == .address_of) n = ints.unparen(tree, tree.nodeData(n).node);
        if (dir.of_tmp) {
            if (tree.nodeTag(n) != .field_access) return false;
            const of, const field = tree.nodeData(n).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(field), "dir")) return false;
            n = ints.unparen(tree, of);
        }
        return tree.nodeTag(n) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(n)), dir.name);
    }

    /// Whether `node` is its descriptor: `d.handle`, or `d.fd`, the field's
    /// name before `std.Io`.
    fn handleIs(dir: Dir, tree: *const Ast, node: Node.Index) bool {
        const n = ints.unparen(tree, node);
        if (tree.nodeTag(n) != .field_access) return false;
        const of, const field = tree.nodeData(n).node_and_token;
        const name = tree.tokenSlice(field);
        if (!std.mem.eql(u8, name, "handle") and !std.mem.eql(u8, name, "fd")) return false;
        return dir.is(tree, of);
    }
};

/// A local a statement opens a directory into, without `iterate`.
const Opened = struct {
    dir: Dir,
    /// The call that opens it.
    call: Node.Index,
    opener: Opener,
};

/// The directory `statement` opens into a local with options that leave
/// `iterate` false: `const d = try dir.openDir(io, sub, .{});`.
fn pathOnly(tree: *const Ast, statement: Node.Index) ?Opened {
    const decl = tree.fullVarDecl(statement) orelse return null;
    var init = decl.ast.init_node.unwrap() orelse return null;
    // `try`, `catch` and parentheses around the call change nothing here.
    while (true) switch (tree.nodeTag(init)) {
        .@"try" => init = tree.nodeData(init).node,
        .@"catch" => init = tree.nodeData(init).node_and_node[0],
        .grouped_expression => init = tree.nodeData(init).node_and_token[0],
        else => break,
    };
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, init) orelse return null;
    const opener = std.meta.stringToEnum(Opener, tree.tokenSlice(tree.lastToken(call.ast.fn_expr))) orelse return null;
    const params = call.ast.params;
    if (params.len == 0 or !withoutIterate(tree, params[params.len - 1])) return null;
    return .{
        .dir = .{ .name = tree.tokenSlice(decl.ast.mut_token + 1), .of_tmp = opener == .tmpDir },
        .call = init,
        .opener = opener,
    };
}

/// Whether `options`, the last argument of a call that opens a directory,
/// is an initializer that leaves `iterate` false: it does not name it, or
/// writes `.iterate = false`, in itself or in the `.open_options` that
/// `createDirPathOpen` takes. Options held in a name are not read.
fn withoutIterate(tree: *const Ast, options: Node.Index) bool {
    var buffer: [2]Node.Index = undefined;
    const init = tree.fullStructInit(&buffer, options) orelse return false;
    for (init.ast.fields) |field| {
        const name = tree.tokenSlice(tree.firstToken(field) - 2);
        if (std.mem.eql(u8, name, "iterate")) return std.mem.eql(u8, tree.getNodeSource(field), "false");
        if (std.mem.eql(u8, name, "open_options")) return withoutIterate(tree, field);
    }
    return true;
}

/// What needs a directory's descriptor, and the call that does.
const Need = struct {
    use: Use,
    /// The call that lists it, syncs it or changes it.
    call: Node.Index,
    /// The call that hands it to the function of this file that makes
    /// `call`, when the function that opens it does not.
    handed: ?Node.Index = null,
    /// That function's name.
    helper: []const u8 = "",
};

/// A function of the file that needs the descriptor of a directory it is
/// handed.
const Helper = struct {
    name: []const u8,
    /// Which parameter the directory arrives in, from 0, and how many
    /// parameters there are.
    param: usize,
    params: usize,
    use: Use,
    call: Node.Index,
};

/// Every function of the file with a parameter written as a `Dir` whose
/// body lists, syncs or changes it. What such a function hands on in turn
/// is not followed, and a name two functions of the file have is left
/// out: a call by it does not say which of them it reaches.
fn helpersOf(arena: Allocator, tree: *const Ast) Allocator.Error![]const Helper {
    var named: std.StringHashMapUnmanaged(usize) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]Node.Index = undefined;
        const name = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]).?.name_token orelse continue;
        const entry = try named.getOrPutValue(arena, tree.tokenSlice(name), 0);
        entry.value_ptr.* += 1;
    }
    var helpers: std.ArrayList(Helper) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const proto_node, const body = tree.nodeData(node).node_and_node;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, proto_node).?;
        const name = proto.name_token orelse continue;
        if (named.get(tree.tokenSlice(name)).? > 1) continue;
        var count: usize = 0;
        var counted = proto.iterate(tree);
        while (counted.next()) |_| count += 1;
        var params = proto.iterate(tree);
        var index: usize = 0;
        while (params.next()) |param| : (index += 1) {
            const param_name = param.name_token orelse continue;
            const param_type = param.type_expr orelse continue;
            if (!std.mem.endsWith(u8, tree.getNodeSource(param_type), "Dir")) continue;
            const need = try needIn(arena, tree, &.{body}, .{ .name = tree.tokenSlice(param_name) }, &.{}) orelse continue;
            try helpers.append(arena, .{
                .name = tree.tokenSlice(name),
                .param = index,
                .params = count,
                .use = need.use,
                .call = need.call,
            });
        }
    }
    return helpers.items;
}

/// The first of `nodes`, in source order, to need the descriptor of `dir`,
/// or to hand it to one of `helpers`.
fn needIn(arena: Allocator, tree: *const Ast, nodes: []const Node.Index, dir: Dir, helpers: []const Helper) Allocator.Error!?Need {
    var search: Search = .{ .arena = arena, .tree = tree, .dir = dir, .helpers = helpers };
    for (nodes) |node| if (try search.in(node)) |need| return need;
    return null;
}

const Search = struct {
    arena: Allocator,
    tree: *const Ast,
    dir: Dir,
    helpers: []const Helper,
    /// The locals made from the directory's handle: `as_file` of
    /// `const as_file: Io.File = .{ .handle = d.handle, ... };`.
    files: std.ArrayList([]const u8) = .empty,
    /// Set where the local is assigned again: from there on it may be
    /// another directory, opened another way.
    reassigned: bool = false,

    /// What `node` or anything under it needs, up to where the local is
    /// assigned again.
    fn in(s: *Search, node: Node.Index) Allocator.Error!?Need {
        const tree = s.tree;
        if (s.reassigned) return null;
        if (tree.nodeTag(node) == .assign) {
            if (kept.rootOf(tree, tree.nodeData(node).node_and_node[0])) |root| {
                s.reassigned = std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(root)), s.dir.name);
            }
        }
        if (tree.fullVarDecl(node)) |decl| if (decl.ast.init_node.unwrap()) |init| {
            if (s.holdsHandle(init)) try s.files.append(s.arena, tree.tokenSlice(decl.ast.mut_token + 1));
        };
        if (s.at(node)) |need| return need;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(s.arena, tree, node, &nodes);
        for (nodes.items) |child| if (try s.in(child)) |need| return need;
        return null;
    }

    /// What the call `node` needs of the directory, if it is a call that
    /// needs its descriptor.
    fn at(s: *const Search, node: Node.Index) ?Need {
        const tree = s.tree;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse return null;
        const params = call.ast.params;
        const callee = call.ast.fn_expr;
        const name = tree.tokenSlice(tree.lastToken(callee));
        // `posix.fsync(d.handle)`, by whatever path it is named.
        if (std.mem.eql(u8, name, "fsync") or std.mem.eql(u8, name, "fdatasync")) {
            if (params.len == 1 and s.dir.handleIs(tree, params[0])) return .{ .use = .synced, .call = node };
        }
        if (tree.nodeTag(callee) == .field_access) {
            const receiver = tree.nodeData(callee).node_and_token[0];
            if (s.dir.is(tree, receiver)) {
                if (methods.get(name)) |use| return .{ .use = use, .call = node };
            } else if (std.mem.eql(u8, name, "sync") and s.isFile(receiver)) {
                return .{ .use = .synced, .call = node };
            }
        }
        for (params, 0..) |param, index| {
            if (!s.dir.is(tree, param)) continue;
            const helper = helperFor(tree, s.helpers, call, index) orelse continue;
            return .{ .use = helper.use, .call = helper.call, .handed = node, .helper = helper.name };
        }
        return null;
    }

    /// Whether `node` is a file over the directory's handle: a local made
    /// from it, or the initializer in place.
    fn isFile(s: *const Search, node: Node.Index) bool {
        const n = ints.unparen(s.tree, node);
        if (s.tree.nodeTag(n) != .identifier) return s.holdsHandle(n);
        const name = s.tree.tokenSlice(s.tree.nodeMainToken(n));
        for (s.files.items) |file| if (std.mem.eql(u8, file, name)) return true;
        return false;
    }

    /// Whether `node` is an initializer with the directory's handle as its
    /// own: `.{ .handle = d.handle, ... }`, `Io.File{ .handle = d.handle }`.
    fn holdsHandle(s: *const Search, node: Node.Index) bool {
        var buffer: [2]Node.Index = undefined;
        const init = s.tree.fullStructInit(&buffer, ints.unparen(s.tree, node)) orelse return false;
        for (init.ast.fields) |field| {
            if (!std.mem.eql(u8, s.tree.tokenSlice(s.tree.firstToken(field) - 2), "handle")) continue;
            if (s.dir.handleIs(s.tree, field)) return true;
        }
        return false;
    }
};

/// The `Dir` methods that need a descriptor opened for iterating, and what
/// each does with it.
const methods: std.StaticStringMap(Use) = .initComptime(.{
    .{ "iterate", .listed },
    .{ "iterateAssumeFirstIteration", .listed },
    .{ "walk", .listed },
    .{ "walkSelectively", .listed },
    .{ "setPermissions", .permissions },
    .{ "setOwner", .owner },
});

/// The helper `call` hands its argument `index` to: one of its name that
/// takes as many arguments with the directory in that place, or, called as
/// a method, one more with the directory one further on.
fn helperFor(tree: *const Ast, helpers: []const Helper, call: Ast.full.Call, index: usize) ?Helper {
    const callee = call.ast.fn_expr;
    const name = tree.tokenSlice(tree.lastToken(callee));
    const method = tree.nodeTag(callee) == .field_access;
    for (helpers) |helper| {
        if (!std.mem.eql(u8, helper.name, name)) continue;
        if (helper.params == call.ast.params.len and helper.param == index) return helper;
        if (method and helper.params == call.ast.params.len + 1 and helper.param == index + 1) return helper;
    }
    return null;
}

/// `node` as written when it is one short line, else the name it calls and
/// `(...)`.
fn shown(arena: Allocator, tree: *const Ast, node: Node.Index) Allocator.Error![]const u8 {
    const source = tree.getNodeSource(node);
    if (source.len <= 48 and std.mem.findScalar(u8, source, '\n') == null) return source;
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return source;
    return arena.print("{s}(...)", .{tree.tokenSlice(tree.lastToken(call.ast.fn_expr))});
}

fn add(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding), opened: Opened, need: Need) Allocator.Error!void {
    try findings.append(arena, .{
        .offset = tree.tokenStart(tree.firstToken(opened.call)),
        .hint = switch (opened.opener) {
            .createDirPathOpen => "open it with `.open_options = .{ .iterate = true }` in its options, which Linux opens without O_PATH",
            else => "open it with `.iterate = true` in its options, which Linux opens without O_PATH",
        },
        .detail = .{ .opath = .{
            .dir = if (opened.dir.of_tmp) try arena.print("{s}.dir", .{opened.dir.name}) else opened.dir.name,
            .use = need.use,
            .call = try shown(arena, tree, need.call),
            .handed = if (need.handed) |handed| try shown(arena, tree, handed) else "",
            .helper = need.helper,
        } },
    });
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col dir use call`, and `via helper (handed)` for a directory
/// handed on, in source order.
fn expectOpath(source: [:0]const u8, expected: []const u8) !void {
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
        const o = finding.detail.opath;
        try out.writer.print("{d}:{d} {s} {t} {s}", .{ loc.line + 1, loc.column + 1, o.dir, o.use, o.call });
        if (o.helper.len > 0) try out.writer.print(" via {s} ({s})", .{ o.helper, o.handed });
        try out.writer.writeByte('\n');
    }
    try expect.findings(@src(), expected, out.written());
}

test "a directory opened without iterate, then synced through its handle (#208)" {
    try expectOpath(
        \\fn syncDir(io: Io, dir: Io.Dir, sub: []const u8) !void { const d = try dir.openDir(io, sub, .{}); defer d.close(io); const as_file: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } }; try as_file.sync(io); }
        \\fn inPlace(io: Io, dir: Io.Dir) !void { var d = try dir.openDir(io, "blobs", .{ .follow_symlinks = false }); defer d.close(io); try (Io.File{ .handle = d.handle, .flags = .{ .nonblocking = false } }).sync(io); }
        \\fn made(io: Io, root: Io.Dir) !void { var staging = try root.createDirPathOpen(io, "staging", .{}); defer staging.close(io); const f: Io.File = .{ .handle = staging.handle, .flags = .{ .nonblocking = false } }; try f.sync(io); }
        \\fn absolute(io: Io, path: []const u8) !void { const d = Io.Dir.openDirAbsolute(io, path, .{ .iterate = false }) catch return; defer d.close(io); try std.posix.fdatasync(d.handle); }
        \\fn raw(io: Io, dir: Io.Dir) void { const d = dir.openDir(io, "wal", .{}) catch return; defer d.close(io); _ = std.c.fsync(d.handle); }
    ,
        \\1:72 d synced as_file.sync(io)
        \\2:53 d synced sync(...)
        \\3:57 staging synced f.sync(io)
        \\4:57 d synced std.posix.fdatasync(d.handle)
        \\5:46 d synced std.c.fsync(d.handle)
        \\
    );
}

test "a directory opened without iterate, then listed or changed" {
    try expectOpath(
        \\fn list(io: Io, dir: Io.Dir) !void { var d = try dir.openDir(io, "src", .{}); defer d.close(io); var it = d.iterate(); while (try it.next(io)) |e| use(e); }
        \\fn first(io: Io, dir: Io.Dir) !void { var d = try dir.openDir(io, "src", .{ .access_sub_paths = true }); defer d.close(io); var it = d.iterateAssumeFirstIteration(); _ = &it; }
        \\fn walked(io: Io, gpa: Allocator, dir: Io.Dir) !void { var d = try dir.openDir(io, "src", .{}); defer d.close(io); var w = try d.walk(gpa); defer w.deinit(); while (try w.next(io)) |e| use(e); }
        \\fn selective(io: Io, gpa: Allocator, dir: Io.Dir) !void { var d = try dir.openDir(io, "src", .{}); defer d.close(io); var w = try d.walkSelectively(gpa); defer w.deinit(); }
        \\fn chmod(io: Io, dir: Io.Dir) !void { var d = try dir.createDirPathOpen(io, "cache", .{ .open_options = .{} }); defer d.close(io); try d.setPermissions(io, .default_dir); }
        \\fn chown(io: Io, dir: Io.Dir, uid: u32) !void { var d = try dir.openDir(io, "spool", .{}); defer d.close(io); try d.setOwner(io, uid, null); }
        \\test "lists" { var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup(); var it = tmp.dir.iterate(); while (try it.next(io)) |e| use(e); }
        \\fn inner(io: Io, dir: Io.Dir, deep: bool) !void { var d = try dir.openDir(io, "src", .{}); defer d.close(io); if (deep) { var it = d.iterate(); _ = &it; } }
    ,
        \\1:50 d listed d.iterate()
        \\2:51 d listed d.iterateAssumeFirstIteration()
        \\3:68 d listed d.walk(gpa)
        \\4:71 d listed d.walkSelectively(gpa)
        \\5:51 d permissions d.setPermissions(io, .default_dir)
        \\6:61 d owner d.setOwner(io, uid, null)
        \\7:26 tmp.dir listed tmp.dir.iterate()
        \\8:63 d listed d.iterate()
        \\
    );
}

test "a directory opened without iterate, handed to a function of the file that needs it" {
    try expectOpath(
        \\fn syncDir(io: Io, dir: Io.Dir) !void { const as_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } }; try as_file.sync(io); }
        \\fn put(io: Io, root: Io.Dir) !void { var slots = try root.openDir(io, "slots", .{}); defer slots.close(io); try syncDir(io, slots); }
        \\const Store = struct { root: Io.Dir, fn count(store: Store, io: Io, dir: Io.Dir) !usize { _ = store; var n: usize = 0; var it = dir.iterate(); while (try it.next(io)) |_| n += 1; return n; } fn slots(store: Store, io: Io) !usize { var d = try store.root.openDir(io, "slots", .{}); defer d.close(io); return store.count(io, d); } };
        \\fn byPointer(io: Io, dir: *const Io.Dir) !void { var it = dir.iterate(); _ = try it.next(io); }
        \\fn calls(io: Io, root: Io.Dir) !void { var d = try root.openDir(io, "a", .{}); defer d.close(io); try byPointer(io, &d); }
        \\test "counts" { var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup(); try syncDir(io, tmp.dir); }
    ,
        \\2:54 slots synced as_file.sync(io) via syncDir (syncDir(io, slots))
        \\3:244 d listed dir.iterate() via count (store.count(io, d))
        \\5:52 d listed dir.iterate() via byPointer (byPointer(io, &d))
        \\6:27 tmp.dir synced as_file.sync(io) via syncDir (syncDir(io, tmp.dir))
        \\
    );
}

test "not reported: opened to iterate, options not written there, a use O_PATH allows, another directory" {
    try expectOpath(
        \\fn iterable(io: Io, dir: Io.Dir) !void { const d = try dir.openDir(io, "blobs", .{ .iterate = true }); defer d.close(io); const f: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } }; try f.sync(io); }
        \\fn listed(io: Io, dir: Io.Dir) !void { var d = try dir.openDir(io, "src", .{ .iterate = true }); defer d.close(io); var it = d.iterate(); _ = &it; }
        \\fn made(io: Io, dir: Io.Dir) !void { var d = try dir.createDirPathOpen(io, "cache", .{ .open_options = .{ .iterate = true } }); defer d.close(io); try d.setPermissions(io, .default_dir); }
        \\fn computed(io: Io, dir: Io.Dir, deep: bool) !void { var d = try dir.openDir(io, "src", .{ .iterate = deep }); defer d.close(io); if (deep) { var it = d.iterate(); _ = &it; } }
        \\fn named(io: Io, dir: Io.Dir, options: Io.Dir.OpenOptions) !void { var d = try dir.openDir(io, "src", options); defer d.close(io); var it = d.iterate(); _ = &it; }
        \\fn handedOptions(io: Io, dir: Io.Dir, options: Io.Dir.OpenOptions) !void { var d = try dir.createDirPathOpen(io, "src", .{ .open_options = options }); defer d.close(io); var it = d.iterate(); _ = &it; }
        \\fn allowed(io: Io, dir: Io.Dir) !void { var d = try dir.openDir(io, "src", .{}); defer d.close(io); _ = try d.stat(io); const f = try d.openFile(io, "a", .{}); f.close(io); try d.access(io, "b", .{}); }
        \\fn statted(io: Io, dir: Io.Dir) !void { var d = try dir.openDir(io, "src", .{}); defer d.close(io); const f: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } }; _ = try f.stat(io); }
        \\fn other(io: Io, dir: Io.Dir, all: Io.Dir) !void { var d = try dir.openDir(io, "src", .{}); defer d.close(io); var it = all.iterate(); _ = &it; const f: Io.File = .{ .handle = all.handle, .flags = .{ .nonblocking = false } }; try f.sync(io); }
        \\fn wal(io: Io, dir: Io.Dir) !void { var d = try dir.openDir(io, "wal", .{}); defer d.close(io); const f = try d.createFile(io, "log", .{}); defer f.close(io); try f.sync(io); try std.posix.fdatasync(f.handle); }
        \\fn handedIn(io: Io, dir: Io.Dir) !void { var it = dir.iterate(); _ = try it.next(io); }
        \\fn field(self: *Self, io: Io) !void { self.dir = try self.root.openDir(io, "src", .{}); var it = self.dir.iterate(); _ = &it; }
        \\fn before(io: Io, dir: Io.Dir, all: Io.Dir) !void { { var d = all; var it = d.iterate(); _ = &it; } var d = try dir.openDir(io, "src", .{}); defer d.close(io); }
        \\fn sibling(io: Io, dir: Io.Dir, all: Io.Dir) !void { { var d = try dir.openDir(io, "src", .{}); defer d.close(io); } { var d = all; var it = d.iterate(); _ = &it; } }
        \\fn elsewhere(io: Io, dir: Io.Dir) !void { var d = try dir.openDir(io, "src", .{}); defer d.close(io); try lib.syncDir(io, d, 1); }
        \\fn syncDir(io: Io, dir: Io.Dir) !void { const f: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } }; try f.sync(io); }
        \\fn twoHops(io: Io, dir: Io.Dir) !void { try syncDir(io, dir); }
        \\fn far(io: Io, root: Io.Dir) !void { var d = try root.openDir(io, "a", .{}); defer d.close(io); try twoHops(io, d); }
        \\fn notDir(io: Io, d: Thing) !void { var it = d.iterate(); _ = try it.next(io); }
        \\fn thing(io: Io, root: Io.Dir) !void { var d = try root.openDir(io, "a", .{}); defer d.close(io); try notDir(io, d); }
        \\fn copyTree(io: Io, from: Io.Dir, to: Io.Dir) !void { var it = from.iterate(); while (try it.next(io)) |e| try from.copyFile(e.name, to, e.name, io, .{}); }
        \\fn target(io: Io, from: Io.Dir, root: Io.Dir) !void { var to = try root.openDir(io, "files", .{}); defer to.close(io); try copyTree(io, from, to); }
        \\fn again(io: Io, dir: Io.Dir, deep: bool) !void { var d = try dir.openDir(io, "src", .{}); defer d.close(io); if (deep) { d.close(io); d = try dir.openDir(io, "src", .{ .iterate = true }); var it = d.iterate(); _ = &it; } }
        \\const A = struct { fn scan(io: Io, dir: Io.Dir) !void { var it = dir.iterate(); _ = try it.next(io); } };
        \\const B = struct { fn scan(io: Io, dir: Io.Dir) !void { try dir.access(io, "a", .{}); } };
        \\fn either(io: Io, root: Io.Dir) !void { var d = try root.openDir(io, "a", .{}); defer d.close(io); try B.scan(io, d); }
        \\test "made again" { var tmp = std.testing.tmpDir(.{}); tmp.cleanup(); tmp = std.testing.tmpDir(.{ .iterate = true }); defer tmp.cleanup(); var it = tmp.dir.iterate(); _ = &it; }
        \\test "kept" { var tmp = std.testing.tmpDir(.{ .iterate = true }); defer tmp.cleanup(); var it = tmp.dir.iterate(); _ = &it; }
        \\test "its parent" { var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup(); var it = tmp.parent_dir.iterate(); _ = &it; }
    , "");
}

test "the message and the hint name the use, and the function it is handed to" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\fn syncDir(io: Io, dir: Io.Dir) !void { const f: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } }; try f.sync(io); }
        \\fn put(io: Io, root: Io.Dir) !void { var slots = try root.createDirPathOpen(io, "slots", .{}); defer slots.close(io); try syncDir(io, slots); }
        \\fn list(io: Io, dir: Io.Dir) !void { var d = try dir.openDir(io, "src", .{}); defer d.close(io); var it = d.iterate(); _ = &it; }
    , .{});
    defer tree.deinit(gpa);
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
        try report.writeMessage(&out.writer, finding);
        try out.writer.print("\n{s}\n", .{finding.hint});
    }
    try expect.findings(@src(),
        \\`slots` is opened without `.iterate = true`, which on Linux is an O_PATH descriptor, and 'syncDir', which `syncDir(io, slots)` below hands it to, syncs it (`f.sync(io)`): that is EBADF there, a panic in Debug and error.Unexpected otherwise, while macOS, which has no O_PATH, passes
        \\open it with `.open_options = .{ .iterate = true }` in its options, which Linux opens without O_PATH
        \\`d` is opened without `.iterate = true`, which on Linux is an O_PATH descriptor, and `d.iterate()` below lists it: that is EBADF there, a panic in Debug and error.Unexpected otherwise, while macOS, which has no O_PATH, passes
        \\open it with `.iterate = true` in its options, which Linux opens without O_PATH
        \\
    , out.written());
}
