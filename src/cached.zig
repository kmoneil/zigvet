//! Rule seventeen, cached: a build script that lists a directory to decide
//! what to build, and never tells Zig's configure cache.
//!
//!     var dir = try b.root.openDir(b.graph.io, "test", .{ .iterate = true });
//!     defer dir.close(b.graph.io);
//!     var it = dir.iterate();
//!     while (try it.next(b.graph.io)) |entry| { ... } // one addTest per file
//!
//! Zig 0.17 caches the configure phase: when nothing it tracks has changed,
//! `zig build` reuses the last build graph without running `build()`. A
//! file added to `test/` changes nothing it tracks, so its test is never
//! built, and `zig build test` passes without running it until something
//! else invalidates the cache. `b.dependOnDirectoryContents(b.path("test"))`
//! makes the directory's entries something it tracks, and
//! `b.graph.poisonCache()` turns the cache off for the build. It compiles
//! clean in every build mode, and works on every run that configures anew.
//!
//! What lists a directory is a call to `openDir` with `.iterate = true` in
//! its options and `b.root` in it, `b` a `*std.Build` parameter of the
//! function: `b.root.openDir(...)`, `b.root.root_dir.handle.openDir(...)`,
//! or `cwd().openDir(io, try b.root.joinString(...), ...)`. It is reported
//! when the function calls none of `dependOnDirectoryContents`,
//! `dependOnDirectoryMetadata` and `poisonCache`; or, when it also calls a
//! `walk`, which goes into subdirectories, when no `dependOnDirectory...`
//! call of it is in a loop, as one for each directory the walk enters is:
//! neither is recursive.
//!
//! Not reported: `b.build_root`, the field of a Zig before 0.17, whose
//! configure phase always runs; a directory opened by another path
//! (`cwd().openDir(io, "test", ...)`, `openDirAbsolute`), which the syntax
//! cannot place in the build root or a Zig version; and a dependency the
//! caller declares, which only the caller shows.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;

/// Appends a finding for every directory a build function lists without
/// telling the configure cache. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const proto_node, const body = tree.nodeData(node).node_and_node;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, proto_node).?;
        const b = buildParam(tree, proto) orelse continue;
        var seen: Seen = .{};
        try scan(arena, tree, body, b, false, &seen);
        if (seen.poisoned) continue;
        // Told of the directory, when a walk goes on into those under it.
        if (seen.depends and (!seen.walks or seen.depends_in_loop)) continue;
        for (seen.lists.items) |call| try add(arena, tree, findings, call, b, seen);
    }
}

/// The name of `proto`'s `*std.Build` parameter: `b` of `b: *std.Build`.
pub fn buildParam(tree: *const Ast, proto: Ast.full.FnProto) ?[]const u8 {
    var params = proto.iterate(tree);
    while (params.next()) |param| {
        const name = param.name_token orelse continue;
        const t = param.type_expr orelse continue;
        const text = tree.getNodeSource(t);
        if (std.mem.eql(u8, text, "*std.Build") or std.mem.eql(u8, text, "*Build")) return tree.tokenSlice(name);
    }
    return null;
}

/// What a function's body does that the rule asks about.
const Seen = struct {
    /// The `openDir` calls that list a directory of the build root.
    lists: std.ArrayList(Node.Index) = .empty,
    depends: bool = false,
    /// A `dependOnDirectory...` call in a loop, as a walk makes one for
    /// each directory it enters.
    depends_in_loop: bool = false,
    poisoned: bool = false,
    walks: bool = false,
};

/// Notes in `seen` what `node`, inside the function with the build
/// parameter `b`, does, and what is under it, but not in nested functions
/// and types. `in_loop` says whether a loop is around it.
fn scan(arena: Allocator, tree: *const Ast, node: Node.Index, b: []const u8, in_loop: bool, seen: *Seen) Allocator.Error!void {
    if (kept.isNested(tree.nodeTag(node))) return;
    var buffer: [1]Node.Index = undefined;
    if (tree.fullCall(&buffer, node)) |call| if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const method = tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]);
        if (std.mem.eql(u8, method, "openDir")) {
            if (listsFromRoot(tree, node, call, b)) try seen.lists.append(arena, node);
        } else if (std.mem.eql(u8, method, "dependOnDirectoryContents") or std.mem.eql(u8, method, "dependOnDirectoryMetadata")) {
            seen.depends = true;
            if (in_loop) seen.depends_in_loop = true;
        } else if (std.mem.eql(u8, method, "poisonCache")) {
            seen.poisoned = true;
        } else if (std.mem.eql(u8, method, "walk") or std.mem.eql(u8, method, "walkSelectively")) {
            seen.walks = true;
        }
    };
    const loop = in_loop or tree.fullWhile(node) != null or tree.fullFor(node) != null;
    var nodes: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, node, &nodes);
    for (nodes.items) |child| try scan(arena, tree, child, b, loop, seen);
}

/// Whether `call`, an `openDir`, opens for iterating (`.iterate = true` in
/// its last argument) a directory reached from `b.root`, in its receiver or
/// its path.
fn listsFromRoot(tree: *const Ast, node: Node.Index, call: Ast.full.Call, b: []const u8) bool {
    const params = call.ast.params;
    if (params.len < 2) return false;
    if (!hasField(tree, params[params.len - 1], "iterate", "true")) return false;
    const last = tree.lastToken(node);
    var token = tree.firstToken(node);
    while (token + 2 <= last) : (token += 1) {
        if (tree.tokenTag(token) != .identifier or !std.mem.eql(u8, tree.tokenSlice(token), b)) continue;
        if (token > 0 and tree.tokenTag(token - 1) == .period) continue;
        if (tree.tokenTag(token + 1) == .period and std.mem.eql(u8, tree.tokenSlice(token + 2), "root")) return true;
    }
    return false;
}

/// Whether `node` holds `.field = value`, as written.
fn hasField(tree: *const Ast, node: Node.Index, field: []const u8, value: []const u8) bool {
    const last = tree.lastToken(node);
    var token = tree.firstToken(node);
    while (token + 3 <= last) : (token += 1) {
        if (tree.tokenTag(token) != .period or tree.tokenTag(token + 2) != .equal) continue;
        if (std.mem.eql(u8, tree.tokenSlice(token + 1), field) and std.mem.eql(u8, tree.tokenSlice(token + 3), value)) return true;
    }
    return false;
}

fn add(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding), node: Node.Index, b: []const u8, seen: Seen) Allocator.Error!void {
    var buffer: [1]Node.Index = undefined;
    const params = tree.fullCall(&buffer, node).?.ast.params;
    const path = params[params.len - 2];
    // The path as written, when it is short enough to read in a hint.
    const shown = switch (tree.nodeTag(path)) {
        .string_literal, .identifier => tree.getNodeSource(path),
        else => "...",
    };
    const hint = if (seen.depends)
        try arena.print("call `{s}.dependOnDirectoryContents` on each directory the walk enters too, or `{s}.graph.poisonCache()`", .{ b, b })
    else if (seen.walks)
        try arena.print("call `{s}.dependOnDirectoryContents({s}.path({s}))`, and the same on each directory the walk enters, or `{s}.graph.poisonCache()`", .{ b, b, shown, b })
    else
        try arena.print("say so next to it with `{s}.dependOnDirectoryContents({s}.path({s}))`, or `{s}.graph.poisonCache()`", .{ b, b, shown, b });
    try findings.append(arena, .{
        .offset = tree.tokenStart(tree.firstToken(node)),
        .hint = hint,
        .detail = .{ .cached = .{
            .path = tree.getNodeSource(path),
            .walked = seen.depends,
        } },
    });
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col path`, and `walked` for a walk, in source order.
fn expectCached(source: [:0]const u8, expected: []const u8) !void {
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
        const c = finding.detail.cached;
        try out.writer.print("{d}:{d} {s}{s}\n", .{ loc.line + 1, loc.column + 1, c.path, if (c.walked) " walked" else "" });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a directory of the build root listed with nothing told to the configure cache (#94)" {
    try expectCached(
        \\pub fn build(b: *std.Build) void { var dir = b.root.openDir(b.graph.io, "test", .{ .iterate = true }) catch return; var it = dir.iterate(); while (it.next(b.graph.io) catch null) |e| use(e); }
        \\fn benches(b: *std.Build, io: Io) !void { var dir = try b.root.openDir(io, "src/bench", .{ .iterate = true }); defer dir.close(io); var it = dir.iterate(); _ = &it; }
        \\fn handle(b: *Build) !void { const dir = try b.root.root_dir.handle.openDir(b.graph.io, "tests/rendering", .{ .iterate = true }); var it = dir.iterateAssumeFirstIteration(); _ = &it; }
        \\fn joined(b: *std.Build, path: []const u8) !void { var dir = try std.Io.Dir.cwd().openDir(b.graph.io, try b.root.joinString(b.allocator, path), .{ .iterate = true }); _ = &dir; }
        \\fn walked(b: *std.Build) !void { b.dependOnDirectoryContents(b.path("test")); var dir = try b.root.openDir(b.graph.io, "test", .{ .iterate = true }); var w = try dir.walk(b.allocator); while (try w.next(b.graph.io)) |e| use(e); }
    ,
        \\1:46 "test"
        \\2:57 "src/bench"
        \\3:46 "tests/rendering"
        \\4:66 try b.root.joinString(b.allocator, path)
        \\5:93 "test" walked
        \\
    );
}

test "not reported: told to the configure cache, poisoned, before 0.17, another path, not listed (#94)" {
    try expectCached(
        \\pub fn build(b: *std.Build) void { b.dependOnDirectoryContents(b.path("test")); var dir = b.root.openDir(b.graph.io, "test", .{ .iterate = true }) catch return; var it = dir.iterate(); _ = &it; }
        \\fn metadata(b: *std.Build, cases: []const u8) !void { var dir = try b.root.openDir(b.graph.io, cases, .{ .iterate = true }); b.dependOnDirectoryMetadata(b.path(cases)); _ = &dir; }
        \\fn poisoned(b: *std.Build) !void { b.graph.poisonCache(); var dir = try b.root.openDir(b.graph.io, "dist", .{ .iterate = true }); _ = &dir; }
        \\fn eachDir(b: *std.Build, root: []const u8) !void { b.dependOnDirectoryContents(b.path(root)); var dir = try b.root.openDir(b.graph.io, root, .{ .iterate = true }); var w = try dir.walk(b.allocator); while (try w.next(b.graph.io)) |e| switch (e.kind) { .directory => b.dependOnDirectoryContents(b.path(e.path)), else => {} }; }
        \\fn old(b: *std.Build, io: Io) !void { var dir = try b.build_root.handle.openDir(io, "test", .{ .iterate = true }); _ = &dir; }
        \\fn cwd(b: *std.Build) !void { var dir = try std.Io.Dir.cwd().openDir(b.graph.io, "test", .{ .iterate = true }); _ = &dir; }
        \\fn opened(b: *std.Build) !void { var dir = try b.root.openDir(b.graph.io, "assets", .{}); _ = &dir; }
        \\fn noBuild(root: Path, io: Io) !void { var dir = try root.openDir(io, "test", .{ .iterate = true }); _ = &dir; }
        \\fn dependency(b: *std.Build, dep: *std.Build.Dependency) !void { var dir = try dep.builder.root.openDir(b.graph.io, "src", .{ .iterate = true }); _ = &dir; }
    , "");
}
