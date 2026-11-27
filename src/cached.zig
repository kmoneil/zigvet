//! Rule seventeen, cached: a build script that lists a directory, or asks
//! whether a path is there, to decide what to build, and never tells Zig's
//! configure cache.
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
//!
//! The same goes for a script that only asks whether a path is there
//! (#240):
//!
//!     if (b.root.access(b.graph.io, "locales", .{})) |_| { ... } // a step
//!
//! A `locales/` made after the first run changes nothing the cache tracks,
//! so its step is missing until build.zig's text changes. What asks is a
//! call to `access`, `statFile`, `openFile`, or `openDir` with no
//! `.iterate = true`, reached from the build's root: `b.root` in it, the
//! `owner.root` of a source path (`LazyPath.src_path`), or called on a
//! local declared from one. It is reported when its failure is taken as an
//! answer: it is the condition of an `if`, or under a `catch` whose handler
//! goes on (`catch null`, `catch return false`). Not when the handler stops
//! the configure (`catch @panic(...)`, `catch |err| return err`, a call to
//! `fatal`), or under `try`: a configure that fails is not cached. Not when
//! the function calls `poisonCache`, or a `dependOn...` that names the
//! path or a directory above it: a dependency on a path that is not there
//! fails the configure (Zig 0.17.1), so what tells the cache is one on the
//! directory the path would be in.

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

/// Appends a finding for every directory a build function lists, and every
/// path it asks after, without telling the configure cache. Everything is
/// allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const proto_node, const body = tree.nodeData(node).node_and_node;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, proto_node).?;
        const b = buildParam(tree, proto) orelse continue;
        var seen: Seen = .{ .body = body };
        try scan(arena, tree, body, b, false, &seen);
        if (seen.poisoned) continue;
        for (seen.probes.items) |call| {
            if (!toldOf(tree, seen.told.items, probedPath(tree, call))) try addProbe(arena, tree, findings, call, b);
        }
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
    /// The function's body, where a local a call is made on is declared.
    body: Node.Index,
    /// The `openDir` calls that list a directory of the build root.
    lists: std.ArrayList(Node.Index) = .empty,
    /// The calls that ask whether a path of the build root is there, their
    /// failure taken as an answer.
    probes: std.ArrayList(Node.Index) = .empty,
    /// Every `dependOn...` call, for the paths each names.
    told: std.ArrayList(Node.Index) = .empty,
    /// A `dependOnDirectory...` call.
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
    try noteCall(arena, tree, node, b, in_loop, seen);
    if (answered(tree, node)) |asked| {
        if (probesRoot(tree, asked, b, seen.body)) try seen.probes.append(arena, asked);
    }
    const loop = in_loop or tree.fullWhile(node) != null or tree.fullFor(node) != null;
    var nodes: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, node, &nodes);
    for (nodes.items) |child| try scan(arena, tree, child, b, loop, seen);
}

/// Notes in `seen` what `node` does when it is a method call the rule asks
/// about: a listing, a walk, or something told to the configure cache.
fn noteCall(arena: Allocator, tree: *const Ast, node: Node.Index, b: []const u8, in_loop: bool, seen: *Seen) Allocator.Error!void {
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return;
    const method = tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]);
    if (std.mem.eql(u8, method, "openDir")) {
        if (listsFromRoot(tree, node, call, b)) try seen.lists.append(arena, node);
    } else if (std.mem.eql(u8, method, "dependOnDirectoryContents") or std.mem.eql(u8, method, "dependOnDirectoryMetadata")) {
        try seen.told.append(arena, node);
        seen.depends = true;
        if (in_loop) seen.depends_in_loop = true;
    } else if (std.mem.eql(u8, method, "dependOnFileContents") or std.mem.eql(u8, method, "dependOnFileMetadata")) {
        try seen.told.append(arena, node);
    } else if (std.mem.eql(u8, method, "poisonCache")) {
        seen.poisoned = true;
    } else if (std.mem.eql(u8, method, "walk") or std.mem.eql(u8, method, "walkSelectively")) {
        seen.walks = true;
    }
}

/// The call whose failure `node` takes as an answer: the condition of an
/// `if`, or what is under a `catch` whose handler goes on. Null for a
/// handler that stops the configure, which is then not cached.
fn answered(tree: *const Ast, node: Node.Index) ?Node.Index {
    const asked = if (tree.fullIf(node)) |full|
        full.ast.cond_expr
    else if (tree.nodeTag(node) == .@"catch") asked: {
        const lhs, const handler = tree.nodeData(node).node_and_node;
        const catch_token = tree.nodeMainToken(node);
        const capture = if (tree.tokenTag(catch_token + 1) == .pipe) tree.tokenSlice(catch_token + 2) else null;
        if (stops(tree, handler, capture)) return null;
        break :asked lhs;
    } else return null;
    const call = ints.unparen(tree, asked);
    var buffer: [1]Node.Index = undefined;
    return if (tree.fullCall(&buffer, call) != null) call else null;
}

/// Whether `node`, what runs when a call fails, ends the configure: a
/// panic, `unreachable`, a call to `fatal`, `exit` or `abort`, or a
/// `return` of an error, the one caught as `capture` or one written out.
/// A block does when its last statement does, and a `switch` or an `if`
/// when every branch does.
fn stops(tree: *const Ast, node: Node.Index, capture: ?[]const u8) bool {
    var buffer: [2]Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| {
        return statements.len > 0 and stops(tree, statements[statements.len - 1], capture);
    }
    if (tree.fullSwitch(node)) |full| {
        for (full.ast.cases) |case| {
            if (!stops(tree, tree.fullSwitchCase(case).?.ast.target_expr, capture)) return false;
        }
        return full.ast.cases.len > 0;
    }
    if (tree.fullIf(node)) |full| {
        const otherwise = full.ast.else_expr.unwrap() orelse return false;
        return stops(tree, full.ast.then_expr, capture) and stops(tree, otherwise, capture);
    }
    return switch (tree.nodeTag(node)) {
        .unreachable_literal => true,
        .grouped_expression => stops(tree, tree.nodeData(node).node_and_token[0], capture),
        .builtin_call_two, .builtin_call_two_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@panic"),
        .@"return" => returnsError(tree, node, capture),
        else => callsOff(tree, node),
    };
}

/// Whether `node`, a `return`, returns an error: one written out, or the
/// one caught as `capture`.
fn returnsError(tree: *const Ast, node: Node.Index, capture: ?[]const u8) bool {
    const value = tree.nodeData(node).opt_node.unwrap() orelse return false;
    if (tree.nodeTag(value) == .error_value) return true;
    const caught = capture orelse return false;
    return tree.nodeTag(value) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), caught);
}

/// Whether `node` is a call that does not return, by its name: `panic`,
/// `fatal`, `exit` or `abort`, of any namespace.
fn callsOff(tree: *const Ast, node: Node.Index) bool {
    var buffer: [1]Node.Index = undefined;
    const callee = (tree.fullCall(&buffer, node) orelse return false).ast.fn_expr;
    const name = switch (tree.nodeTag(callee)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(callee)),
        .field_access => tree.tokenSlice(tree.nodeData(callee).node_and_token[1]),
        else => return false,
    };
    for ([_][]const u8{ "panic", "fatal", "exit", "abort" }) |ends| {
        if (std.mem.eql(u8, name, ends)) return true;
    }
    return false;
}

/// Whether `node`, a call, asks after a path of the build root: `access`,
/// `statFile`, `openFile`, or `openDir` without `.iterate = true`, which is
/// a listing, with the root in it or called on a local of `body` declared
/// from it.
fn probesRoot(tree: *const Ast, node: Node.Index, b: []const u8, body: Node.Index) bool {
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node).?;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const receiver, const method_token = tree.nodeData(call.ast.fn_expr).node_and_token;
    const method = tree.tokenSlice(method_token);
    const asks = for ([_][]const u8{ "access", "statFile", "openFile", "openDir" }) |name| {
        if (std.mem.eql(u8, method, name)) break true;
    } else false;
    if (!asks or call.ast.params.len < 2) return false;
    if (hasField(tree, call.ast.params[call.ast.params.len - 1], "iterate", "true")) return false;
    if (namesRoot(tree, tree.firstToken(node), tree.lastToken(node), b)) return true;
    if (tree.nodeTag(receiver) != .identifier) return false;
    return declaredFromRoot(tree, body, tree.tokenSlice(tree.nodeMainToken(receiver)), b);
}

/// Whether the tokens from `first` to `last` reach a build's root: `b.root`
/// of the build parameter, or the `owner.root` of a source path.
fn namesRoot(tree: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex, b: []const u8) bool {
    var token = first;
    while (token + 2 <= last) : (token += 1) {
        if (tree.tokenTag(token) != .identifier or tree.tokenTag(token + 1) != .period) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(token + 2), "root")) continue;
        const reached = token > 0 and tree.tokenTag(token - 1) == .period;
        const name = tree.tokenSlice(token);
        if (if (reached) std.mem.eql(u8, name, "owner") else std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

/// Whether the local `name` is declared in `body`, alone or as one of a
/// destructure's, from something that reaches a build's root.
fn declaredFromRoot(tree: *const Ast, body: Node.Index, name: []const u8, b: []const u8) bool {
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.firstToken(node);
        if (at < first or at > last) continue;
        const declares = if (tree.fullVarDecl(node)) |decl|
            std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)
        else if (tree.nodeTag(node) == .assign_destructure) declares: {
            const full = tree.assignDestructure(node);
            for (full.ast.variables) |variable| {
                const decl = tree.fullVarDecl(variable) orelse continue;
                if (std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)) break :declares true;
            }
            break :declares false;
        } else false;
        if (declares and namesRoot(tree, at, tree.lastToken(node), b)) return true;
    }
    return false;
}

/// The path a probe asks after, its second argument.
fn probedPath(tree: *const Ast, node: Node.Index) Node.Index {
    var buffer: [1]Node.Index = undefined;
    return tree.fullCall(&buffer, node).?.ast.params[1];
}

/// Whether one of `told`, the function's `dependOn...` calls, names
/// `path`: its tokens, or for a string a directory above it, `"db"` or
/// `"."` for `"db/seeds.zig"`.
fn toldOf(tree: *const Ast, told: []const Node.Index, path: Node.Index) bool {
    const literal = tree.nodeTag(path) == .string_literal;
    for (told) |call| {
        const last = tree.lastToken(call);
        var token = tree.firstToken(call);
        while (token <= last) : (token += 1) {
            if (if (literal) namesAbove(tree, token, path) else sameTokensAt(tree, token, last, path)) return true;
        }
    }
    return false;
}

/// Whether `token` is a string that names `path`, a string too, or a
/// directory above it: the same text, `"."`, or its start up to a `/`.
fn namesAbove(tree: *const Ast, token: Ast.TokenIndex, path: Node.Index) bool {
    if (tree.tokenTag(token) != .string_literal) return false;
    const asked = std.mem.trim(u8, tree.tokenSlice(tree.firstToken(path)), "\"");
    const named = std.mem.trimEnd(u8, std.mem.trim(u8, tree.tokenSlice(token), "\""), "/");
    if (named.len == 0 or std.mem.eql(u8, named, ".") or std.mem.eql(u8, named, asked)) return true;
    return std.mem.startsWith(u8, asked, named) and asked[named.len] == '/';
}

/// Whether the tokens at `token`, up to `last`, are `path`'s, and not a
/// field of something else.
fn sameTokensAt(tree: *const Ast, token: Ast.TokenIndex, last: Ast.TokenIndex, path: Node.Index) bool {
    const first = tree.firstToken(path);
    const len = tree.lastToken(path) - first;
    if (token + len > last) return false;
    if (token > 0 and tree.tokenTag(token - 1) == .period) return false;
    for (0..len + 1) |k| {
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(first + k)), tree.tokenSlice(@intCast(token + k)))) return false;
    }
    return true;
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
            .shape = if (seen.depends) .walked else .listed,
        } },
    });
}

fn addProbe(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding), node: Node.Index, b: []const u8) Allocator.Error!void {
    try findings.append(arena, .{
        .offset = tree.tokenStart(tree.firstToken(node)),
        .hint = try arena.print("call `{s}.dependOnDirectoryContents` on the directory it would be in, or the nearest above it that is always there (`{s}.path(\".\")`), as a dependency on a path that is not there fails the configure; or `{s}.graph.poisonCache()`", .{ b, b, b }),
        .detail = .{ .cached = .{
            .path = tree.getNodeSource(probedPath(tree, node)),
            .shape = .probed,
        } },
    });
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col path`, and `walked` for a walk or `probed` for a path asked
/// after, in source order.
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
        try out.writer.print("{d}:{d} {s}{s}\n", .{ loc.line + 1, loc.column + 1, c.path, switch (c.shape) {
            .listed => "",
            .walked => " walked",
            .probed => " probed",
        } });
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

test "a path of the build root asked after, its absence taken as an answer (#240)" {
    try expectCached(
        \\pub fn build(b: *std.Build) void { if (b.root.access(b.graph.io, "locales", .{})) |_| { _ = b.step("locales", "x"); } else |_| {} }
        \\fn seeds(b: *std.Build, step: *Step) void { b.dependOnDirectoryContents(b.path("test")); if (b.root.access(b.graph.io, "db/seeds.zig", .{})) |_| add(b, step) else |_| step.dependOn(&b.addFail("none").step); }
        \\fn dirExists(b: *std.Build, path: []const u8) bool { var d = b.root.openDir(b.graph.io, path, .{}) catch return false; d.close(b.graph.io); return true; }
        \\fn sized(b: *std.Build) u64 { const st = b.root.statFile(b.graph.io, "logo.png") catch |err| { std.log.warn("{t}", .{err}); return 0; }; return st.size; }
        \\fn opened(b: *std.Build) ?std.Io.File { return b.root.openFile(b.graph.io, "LICENSE", .{}) catch null; }
        \\fn handle(b: *std.Build, sub: []const u8) bool { (b.root.root_dir.handle.access(b.graph.io, sub, .{})) catch return false; return true; }
        \\fn source(b: *std.Build, dir: std.Build.LazyPath) ?std.Io.Dir { const root, const sub = switch (dir) { .src_path => |p| .{ p.owner.root, p.sub_path }, else => return null }; return root.openDir(b.graph.io, sub, .{}) catch null; }
        \\fn named(b: *std.Build) bool { const root = b.root; root.access(b.graph.io, "a", .{}) catch |err| switch (err) { error.FileNotFound => return false, else => @panic("x") }; return true; }
    ,
        \\1:40 "locales" probed
        \\2:94 "db/seeds.zig" probed
        \\3:62 path probed
        \\4:42 "logo.png" probed
        \\5:48 "LICENSE" probed
        \\6:51 sub probed
        \\7:182 sub probed
        \\8:53 "a" probed
        \\
    );
}

test "not reported: a probe that stops the configure, is told, or is of another root (#240)" {
    try expectCached(
        \\fn tried(b: *std.Build) !void { try b.root.access(b.graph.io, "icon.png", .{}); }
        \\fn panics(b: *std.Build) void { b.root.access(b.graph.io, "icon.png", .{}) catch @panic("no icon"); }
        \\fn fatal(b: *std.Build) void { b.root.access(b.graph.io, "icon.png", .{}) catch |err| std.process.fatal("no icon: {t}", .{err}); }
        \\fn handed(b: *std.Build) !void { b.root.access(b.graph.io, "icon.png", .{}) catch |err| return err; }
        \\fn renamed(b: *std.Build) !void { b.root.access(b.graph.io, "icon.png", .{}) catch { log("none"); return error.NoIcon; }; }
        \\fn each(b: *std.Build) void { b.root.access(b.graph.io, "icon.png", .{}) catch |err| switch (err) { error.FileNotFound => @panic("none"), else => unreachable }; }
        \\fn poisoned(b: *std.Build, icon: []const u8) ?[]const u8 { b.root.access(b.graph.io, icon, .{}) catch { b.graph.poisonCache(); return "none"; }; return null; }
        \\fn parent(b: *std.Build) bool { b.dependOnDirectoryContents(b.path("db")); b.root.access(b.graph.io, "db/seeds.zig", .{}) catch return false; return true; }
        \\fn rootDir(b: *std.Build) bool { b.dependOnDirectoryMetadata(b.path(".")); b.root.access(b.graph.io, "locales", .{}) catch return false; return true; }
        \\fn sameName(b: *std.Build, path: []const u8) bool { b.root.access(b.graph.io, path, .{}) catch return false; b.dependOnFileMetadata(b.path(path)); return true; }
        \\fn old(b: *std.Build) bool { b.build_root.handle.access("locales", .{}) catch return false; return true; }
        \\fn cwd(b: *std.Build) bool { std.Io.Dir.cwd().access(b.graph.io, "locales", .{}) catch return false; return true; }
        \\fn package(b: *std.Build, dep: *std.Build.Dependency) bool { dep.builder.root.access(b.graph.io, "src", .{}) catch return false; return true; }
        \\fn other(b: *std.Build, root: std.Io.Dir) bool { root.access(b.graph.io, "src", .{}) catch return false; return true; }
        \\fn noBuild(root: Path, io: Io) bool { root.access(io, "src", .{}) catch return false; return true; }
        \\fn local(b: *std.Build) bool { const dir = std.Io.Dir.cwd(); dir.access(b.graph.io, "src", .{}) catch return false; return true; }
    , "");
    // Told of another path, or of one that only shares a name's letters.
    try expectCached(
        \\fn elsewhere(b: *std.Build) bool { b.dependOnDirectoryContents(b.path("test")); b.root.access(b.graph.io, "tests/data", .{}) catch return false; return true; }
        \\fn method(b: *std.Build, path: []const u8, other: []const u8) bool { b.dependOnFileMetadata(b.path(other)); b.root.access(b.graph.io, path, .{}) catch return false; return true; }
    ,
        \\1:81 "tests/data" probed
        \\2:109 path probed
        \\
    );
}
