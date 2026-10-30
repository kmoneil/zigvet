//! Rule twenty, hoard: a fuzz target that keeps memory past one input.
//!
//!     var seen: std.ArrayList([]const u8) = .empty;
//!
//!     fn one(_: void, smith: *std.testing.Smith) anyerror!void {
//!         var buf: [256]u8 = undefined;
//!         const input = buf[0..smith.slice(&buf)];
//!         try seen.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, input));
//!         try std.testing.expect(parse(input) != null);
//!     }
//!
//! In fuzz mode, Zig 0.17's test runner calls the function passed to
//! `std.testing.fuzz` once for each input, each time with a fresh
//! `std.testing.allocator`, and exits 1 when an input leaks from it. Memory
//! taken from any other allocator is not checked, and what a target keeps
//! of it grows with every input: over a run of millions of inputs,
//! gigabytes, out of memory, or a fuzzer that slows to a crawl, while the
//! leak check passes. A global grown with `std.testing.allocator` fails
//! that check on the first input, which is how one comes to be grown with
//! another allocator.
//!
//! The target is the second argument of `std.testing.fuzz` or
//! `testing.fuzz`: a function of the file named alone, through a container
//! the file declares (`Context.testOne`), or written in place
//! (`struct { fn f(...) ... }.f`). In it, a call takes memory from an
//! allocator the runner does not check when that allocator is the call's
//! receiver for `alloc`, `create`, `dupe` and the like, or one of its
//! arguments (`list.append(gpa, x)`, `std.fmt.allocPrint(gpa, ...)`,
//! `ArenaAllocator.init(gpa)`). Such an allocator is written in the file:
//! `std.heap.page_allocator`, `smp_allocator`, `c_allocator` or
//! `raw_c_allocator`, a local or container-level constant set to one, or a
//! field of the context that the fuzz call writes as one
//! (`std.testing.fuzz(Context{ .gpa = std.heap.page_allocator }, ...)`).
//!
//! What holds the memory is the local the call's result is bound to, or
//! else the receiver it is called on (`seen` of `seen.append`). The call is
//! reported unless the target gives it back: a call there, deferred or not
//! (an `errdefer` runs only on failure), that frees, destroys, deinits,
//! resets or clears what holds it (`gpa.free(copy)`, `list.deinit(gpa)`,
//! `arena.reset(.retain_capacity)`, or `list.clearRetainingCapacity()`,
//! whose capacity stops growing at the largest input). A call in the
//! arguments of one that is reported is left to that one.
//!
//! Not reported: memory from `std.testing.allocator`, or from an arena or
//! other allocator made on it, which the runner checks after each input;
//! memory made once and kept for every later input, in the branch that
//! fills a container-level `var` the first time it is found empty and
//! stores into it (`keywords orelse made: { ...; keywords = parsed; ... }`,
//! `if (cache == null) { cache = ...; }` with `null` on either side, or the
//! `else` of `if (cache != null)`); a call that hands the allocator to one
//! of the file's own functions that gives back all it takes with it, read
//! one level with the parameter as the allocator
//! (`try validate(std.heap.page_allocator, s)`, with a `validate` that
//! frees its copy); the `test` block that calls `fuzz`, which runs once; a
//! function the target calls that takes from such an allocator itself,
//! rather than one it is handed; and a container that carries its own
//! allocator, grown without naming one.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every call in a fuzz target that takes memory from
/// an allocator the runner does not check and that the target never gives
/// back. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    // Most files fuzz nothing: look for the call, which `zig fmt` writes
    // `.fuzz(`, before building anything.
    if (std.mem.find(u8, tree.source, ".fuzz(") == null) return;
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings, .types = try .init(arena, tree) };
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (!isFuzz(tree, call.ast.fn_expr) or call.ast.params.len < 2) continue;
        const target = rule.targetOf(call.ast.params[1]) orelse continue;
        try rule.target(target, call.ast.params[0]);
    }
}

const hint = "take it from std.testing.allocator, which the runner checks after each input, or give it back before the input ends (`defer`)";

/// What allocates through a receiver that is the allocator itself.
const allocating = [_][]const u8{ "alloc", "alignedAlloc", "allocSentinel", "allocWithOptions", "create", "dupe", "dupeZ", "realloc" };

/// What gives memory back, called on what holds it or with it.
const releasing = [_][]const u8{ "free", "destroy", "deinit", "reset", "clearAndFree", "clearRetainingCapacity", "shrinkAndFree", "shrinkRetainingCapacity" };

/// The allocators the runner does not check, by their names in `std.heap`.
const unchecked_names = [_][]const u8{ "page_allocator", "smp_allocator", "c_allocator", "raw_c_allocator" };

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),
    types: types.Types,

    /// What else names an allocator the runner does not check, in the
    /// function read: the target's first parameter and the context the
    /// fuzz call passes it, for a field of the context set to one; or, in a
    /// function the target calls, the parameter the target hands one.
    const Context = struct { name: ?[]const u8 = null, value: ?Node.Index = null, param: ?[]const u8 = null };

    /// A call that takes memory, what it takes it from, and whether the
    /// function it is in keeps it, never giving it back.
    const Taker = struct { call: Node.Index, from: Node.Index, kept: bool };

    /// The function `node`, a fuzz call's second argument, names: one of
    /// the file's by name, one in a container the file declares, or one in
    /// a container written in place.
    fn targetOf(r: *const Rule, node: Node.Index) ?Node.Index {
        const tree = r.tree;
        switch (tree.nodeTag(node)) {
            .identifier => return r.types.declaredFn(node, tree.tokenSlice(tree.nodeMainToken(node))),
            .field_access => {
                const receiver, const field = tree.nodeData(node).node_and_token;
                var buffer: [2]Node.Index = undefined;
                const container = if (tree.fullContainerDecl(&buffer, receiver) != null) receiver else r.types.containerOf(receiver, 0) orelse return null;
                return types.memberFn(tree, container, tree.tokenSlice(field));
            },
            else => return null,
        }
    }

    /// Reports the calls in `fn_decl`, a fuzz target given `context`, that
    /// take memory it never gives back.
    fn target(r: *Rule, fn_decl: Node.Index, context: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
        const target_name = tree.tokenSlice(proto.name_token orelse return);
        var params = proto.iterate(tree);
        const first = params.next();
        const ctx: Context = .{ .name = if (first) |p| if (p.name_token) |t| tree.tokenSlice(t) else null else null, .value = context };

        const takers = try r.takersOf(fn_decl, ctx, true);
        outer: for (takers) |taker| {
            if (!taker.kept) continue;
            // In the arguments of another that keeps what it takes: left to it.
            for (takers) |other| {
                if (other.call != taker.call and other.kept and r.within(taker.call, other.call)) continue :outer;
            }
            const offset = tree.tokenStart(tree.firstToken(taker.call));
            // A target fuzzed more than once is reported once.
            for (r.findings.items) |finding| if (finding.offset == offset and finding.detail == .hoard) continue :outer;
            var call_buffer: [1]Node.Index = undefined;
            try r.findings.append(r.arena, .{
                .offset = offset,
                .hint = hint,
                .detail = .{ .hoard = .{
                    .call = tree.getNodeSource(tree.fullCall(&call_buffer, taker.call).?.ast.fn_expr),
                    .allocator = tree.getNodeSource(taker.from),
                    .target = target_name,
                } },
            });
        }
    }

    /// The calls in `fn_decl` that take memory from an allocator the runner
    /// does not check, given `ctx`, each with whether `fn_decl` keeps it:
    /// never gives it back, and takes it on every input rather than once.
    /// With `follow`, a call that hands the allocator to one of the file's
    /// own functions that gives back all it takes with it is no taker.
    fn takersOf(r: *const Rule, fn_decl: Node.Index, ctx: Context, follow: bool) Allocator.Error![]const Taker {
        const tree = r.tree;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try descendants(r.arena, tree, tree.nodeData(fn_decl).node_and_node[1], &nodes);
        var takers: std.ArrayList(Taker) = .empty;
        for (nodes.items) |node| {
            var call_buffer: [1]Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, node) orelse continue;
            const from = r.takesFrom(call, ctx) orelse continue;
            if (follow and try r.helperGivesBack(call, from)) continue;
            const holder = r.holderOf(node, call, from);
            const kept = if (holder) |h| !r.givenBack(nodes.items, h) else true;
            try takers.append(r.arena, .{ .call = node, .from = from, .kept = kept and !try r.once(node, fn_decl) });
        }
        return takers.items;
    }

    /// Whether `call` hands `from`, as an argument, to one of the file's own
    /// functions that gives back all it takes with it: read one level,
    /// with the parameter it lands in as the allocator.
    fn helperGivesBack(r: *const Rule, call: Ast.full.Call, from: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        const fn_decl, const offset = r.types.callee(call.ast.fn_expr) orelse return false;
        const at = for (call.ast.params, 0..) |param, i| {
            if (param == from) break i + offset;
        } else return false;
        var buffer: [1]Node.Index = undefined;
        var params = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?.iterate(tree);
        var i: usize = 0;
        const name = while (params.next()) |param| : (i += 1) {
            if (i == at) break tree.tokenSlice(param.name_token orelse return false);
        } else return false;
        for (try r.takersOf(fn_decl, .{ .param = name }, false)) |taker| if (taker.kept) return false;
        return true;
    }

    /// The allocator `call` takes memory from, when it is one the runner
    /// does not check: its receiver, for `alloc` and the like, or one of
    /// its arguments. A call that gives memory back with one
    /// (`list.deinit(gpa)`) gives back what it is called on, so it is never
    /// reported.
    fn takesFrom(r: *const Rule, call: Ast.full.Call, ctx: Context) ?Node.Index {
        const tree = r.tree;
        if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
            const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
            if (oneOf(tree.tokenSlice(method), &allocating) and r.unchecked(receiver, ctx, 0)) return receiver;
        }
        for (call.ast.params) |param| if (r.unchecked(param, ctx, 0)) return param;
        return null;
    }

    /// Whether `node` is an allocator the runner does not check, as the
    /// file writes it: one of `std.heap`'s, a local or container-level
    /// constant set to one, or a field of the context set to one.
    fn unchecked(r: *const Rule, node: Node.Index, ctx: Context, depth: u8) bool {
        const tree = r.tree;
        if (depth > 4) return false;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return r.unchecked(tree.nodeData(node).node_and_token[0], ctx, depth + 1),
            .field_access => {
                const receiver, const field = tree.nodeData(node).node_and_token;
                const name = tree.tokenSlice(field);
                if (oneOf(name, &unchecked_names)) return std.mem.eql(u8, lastName(tree, receiver), "heap");
                // `ctx.gpa`, with the fuzz call's context writing `.gpa`.
                const ctx_name = ctx.name orelse return false;
                if (tree.nodeTag(receiver) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(receiver)), ctx_name)) return false;
                const value = r.fieldOf(ctx.value orelse return false, name) orelse return false;
                return r.unchecked(value, .{}, depth + 1);
            },
            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                if (ctx.param) |param| if (std.mem.eql(u8, name, param)) return true;
                if (r.types.localInit(node)) |init| return r.unchecked(init, ctx, depth + 1);
                var around = r.types.enclosingContainer(node);
                while (around) |container| : (around = r.types.enclosingContainer(container)) {
                    const decl = types.memberDecl(tree, container, name) orelse continue;
                    const init = tree.fullVarDecl(decl).?.ast.init_node.unwrap() orelse return false;
                    return r.unchecked(init, ctx, depth + 1);
                }
                return false;
            },
            else => return false,
        }
    }

    /// The value the struct initializer `node`, or a local made with one,
    /// gives its field `name`.
    fn fieldOf(r: *const Rule, node: Node.Index, name: []const u8) ?Node.Index {
        const tree = r.tree;
        const literal = if (tree.nodeTag(node) == .identifier) r.types.localInit(node) orelse return null else node;
        var buffer: [2]Node.Index = undefined;
        const init = tree.fullStructInit(&buffer, literal) orelse return null;
        for (init.ast.fields) |value| {
            // `.name = value`: the name is two tokens before the value.
            if (std.mem.eql(u8, tree.tokenSlice(tree.firstToken(value) - 2), name)) return value;
        }
        return null;
    }

    /// What holds the memory `node`, a call, takes from `from`: the local
    /// or place its result is stored in, or else its receiver, unless that
    /// is the allocator itself.
    fn holderOf(r: *const Rule, node: Node.Index, call: Ast.full.Call, from: Node.Index) ?[]const u8 {
        const tree = r.tree;
        var child = node;
        var up = r.types.parents[@backingInt(node)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = r.types.parents[@backingInt(parent)].unwrap();
        }) {
            switch (tree.nodeTag(parent)) {
                .@"try", .grouped_expression => continue,
                .@"catch", .@"orelse" => if (tree.nodeData(parent).node_and_node[0] == child) continue,
                .assign => if (tree.nodeData(parent).node_and_node[1] == child) return tree.getNodeSource(tree.nodeData(parent).node_and_node[0]),
                else => if (tree.fullVarDecl(parent)) |decl| {
                    if (decl.ast.init_node.unwrap() == child) return tree.tokenSlice(decl.ast.mut_token + 1);
                },
            }
            break;
        }
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
        const receiver = tree.nodeData(call.ast.fn_expr).node_and_token[0];
        if (receiver == from) return null;
        return tree.getNodeSource(receiver);
    }

    /// Whether a call among `nodes`, outside an `errdefer`, gives back what
    /// `holder` holds: frees, destroys, deinits, resets or clears it.
    fn givenBack(r: *const Rule, nodes: []const Node.Index, holder: []const u8) bool {
        const tree = r.tree;
        for (nodes) |node| {
            var buffer: [1]Node.Index = undefined;
            const call = tree.fullCall(&buffer, node) orelse continue;
            if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
            const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
            if (!oneOf(tree.tokenSlice(method), &releasing)) continue;
            if (r.inErrdefer(node)) continue;
            if (std.mem.eql(u8, tree.getNodeSource(receiver), holder)) return true;
            for (call.ast.params) |param| {
                const named = if (tree.nodeTag(param) == .address_of) tree.nodeData(param).node else param;
                if (std.mem.eql(u8, tree.getNodeSource(named), holder)) return true;
            }
        }
        return false;
    }

    /// Whether `node`, in `fn_decl`, runs for one input only: in the branch
    /// that fills a container-level `var` the first time it is found
    /// empty, and stores into it (`g orelse made: { ...; g = x; ... }`,
    /// `if (g == null) { ...; g = x; }` with `null` on either side, or the
    /// `else` of `if (g != null)`), so later inputs reuse it.
    fn once(r: *const Rule, node: Node.Index, fn_decl: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        var child = node;
        var up = r.types.parents[@backingInt(node)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = r.types.parents[@backingInt(parent)].unwrap();
        }) {
            if (parent == fn_decl) return false;
            const empty: Node.Index, const branch: Node.Index = switch (tree.nodeTag(parent)) {
                .@"orelse" => tree.nodeData(parent).node_and_node,
                .if_simple, .@"if" => fill: {
                    const full = tree.fullIf(parent).?;
                    const tag = tree.nodeTag(full.ast.cond_expr);
                    if (tag != .equal_equal and tag != .bang_equal) continue;
                    const lhs, const rhs = tree.nodeData(full.ast.cond_expr).node_and_node;
                    // `g == null` or `null == g`.
                    const g = if (isNull(tree, rhs)) lhs else if (isNull(tree, lhs)) rhs else continue;
                    // For `g != null`, the fill is in the `else`.
                    break :fill .{ g, if (tag == .equal_equal) full.ast.then_expr else full.ast.else_expr.unwrap() orelse continue };
                },
                else => continue,
            };
            if (child != branch or !r.global(empty)) continue;
            var nodes: std.ArrayList(Node.Index) = .empty;
            try descendants(r.arena, tree, branch, &nodes);
            const name = tree.getNodeSource(empty);
            for (nodes.items) |n| {
                if (tree.nodeTag(n) == .assign and std.mem.eql(u8, tree.getNodeSource(tree.nodeData(n).node_and_node[0]), name)) return true;
            }
        }
        return false;
    }

    /// Whether `node` names a container-level `var`, which keeps its value
    /// from one input to the next.
    fn global(r: *const Rule, node: Node.Index) bool {
        const tree = r.tree;
        if (tree.nodeTag(node) != .identifier) return false;
        const name = tree.tokenSlice(tree.nodeMainToken(node));
        var around = r.types.enclosingContainer(node);
        while (around) |container| : (around = r.types.enclosingContainer(container)) {
            const decl = types.memberDecl(tree, container, name) orelse continue;
            return tree.tokenTag(tree.fullVarDecl(decl).?.ast.mut_token) == .keyword_var;
        }
        return false;
    }

    /// Whether `node` is in an `errdefer`, short of the function around it.
    fn inErrdefer(r: *const Rule, node: Node.Index) bool {
        var up = r.types.parents[@backingInt(node)].unwrap();
        while (up) |parent| : (up = r.types.parents[@backingInt(parent)].unwrap()) {
            switch (r.tree.nodeTag(parent)) {
                .@"errdefer" => return true,
                .fn_decl => return false,
                else => {},
            }
        }
        return false;
    }

    /// Whether `node` is under `ancestor`.
    fn within(r: *const Rule, node: Node.Index, ancestor: Node.Index) bool {
        var up = r.types.parents[@backingInt(node)].unwrap();
        while (up) |parent| : (up = r.types.parents[@backingInt(parent)].unwrap()) {
            if (parent == ancestor) return true;
        }
        return false;
    }
};

/// Whether `node` is `null`, which the parser reads as a name.
fn isNull(tree: *const Ast, node: Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "null");
}

/// Whether `fn_expr` names `std.testing.fuzz` or `testing.fuzz`.
fn isFuzz(tree: *const Ast, fn_expr: Node.Index) bool {
    if (tree.nodeTag(fn_expr) != .field_access) return false;
    const receiver, const field = tree.nodeData(fn_expr).node_and_token;
    return std.mem.eql(u8, tree.tokenSlice(field), "fuzz") and std.mem.eql(u8, lastName(tree, receiver), "testing");
}

/// The last name of `node`: `heap` of `std.heap`, `x` of `x`.
fn lastName(tree: *const Ast, node: Node.Index) []const u8 {
    return switch (tree.nodeTag(node)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
        else => "",
    };
}

fn oneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Appends every node under `node`, not counting `node` itself.
fn descendants(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    const start = out.items.len;
    try children.append(arena, tree, node, out);
    const end = out.items.len;
    for (start..end) |i| try descendants(arena, tree, out.items[i], out);
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col call from allocator in target`, in source order.
fn expectHoard(source: [:0]const u8, expected: []const u8) !void {
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
        const h = finding.detail.hoard;
        try out.writer.print("{d}:{d} {s} from {s} in {s}\n", .{ loc.line + 1, loc.column + 1, h.call, h.allocator, h.target });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a fuzz target that keeps memory past one input (#132)" {
    try expectHoard(
        \\const std = @import("std");
        \\const heap = std.heap;
        \\const shared = std.heap.page_allocator;
        \\var seen: std.ArrayList([]const u8) = .empty;
        \\fn one(_: void, smith: *std.testing.Smith) anyerror!void { var buf: [256]u8 = undefined; const input = buf[0..smith.slice(&buf)]; try seen.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, input)); }
        \\fn local(_: void, smith: *std.testing.Smith) anyerror!void { const gpa = std.heap.smp_allocator; const copy = try gpa.alloc(u8, smith.value(u8)); _ = copy; }
        \\fn global(_: void, _: *std.testing.Smith) anyerror!void { _ = try shared.create(u64); }
        \\fn printed(_: void, _: *std.testing.Smith) anyerror!void { try std.testing.expect((try std.fmt.allocPrint(heap.c_allocator, "{d}", .{1})).len == 1); }
        \\fn context(ctx: Ctx, _: *std.testing.Smith) anyerror!void { var list: std.ArrayList(u8) = .empty; try list.append(ctx.gpa, 1); }
        \\fn arena(_: void, _: *std.testing.Smith) anyerror!void { var a = std.heap.ArenaAllocator.init(std.heap.page_allocator); _ = try a.allocator().alloc(u8, 4); }
        \\fn onFailure(_: void, _: *std.testing.Smith) anyerror!void { const copy = try std.heap.page_allocator.dupe(u8, "x"); errdefer std.heap.page_allocator.free(copy); }
        \\fn elements(_: void, _: *std.testing.Smith) anyerror!void { var list: std.ArrayList([]u8) = .empty; defer list.deinit(shared); try list.append(shared, try shared.dupe(u8, "x")); }
        \\fn unbound(_: void, _: *std.testing.Smith) anyerror!void { const a = try shared.alloc(u8, 1); defer shared.free(a); try std.testing.expect((try shared.dupe(u8, "x")).len == 1); }
        \\fn memoLocal(_: void, _: *std.testing.Smith) anyerror!void { var cache: ?[]u8 = null; const c = cache orelse made: { const x = try shared.dupe(u8, "x"); cache = x; break :made x; }; _ = c; }
        \\var never: ?[]u8 = null;
        \\fn unfilled(_: void, _: *std.testing.Smith) anyerror!void { var last: []u8 = undefined; const c = never orelse made: { last = try shared.dupe(u8, "x"); break :made last; }; _ = c; }
        \\fn keep(gpa: std.mem.Allocator, s: []const u8) !void { try seen.append(gpa, try gpa.dupe(u8, s)); }
        \\fn keeping(_: void, _: *std.testing.Smith) anyerror!void { try keep(std.heap.page_allocator, "x"); }
        \\fn copyOf(gpa: std.mem.Allocator, s: []const u8) ![]u8 { return gpa.dupe(u8, s); }
        \\fn copied(_: void, _: *std.testing.Smith) anyerror!void { _ = try copyOf(shared, "x"); }
        \\const Bag = struct { items: std.ArrayList(u8) = .empty, fn put(b: *Bag, gpa: std.mem.Allocator) !void { try b.items.append(gpa, 1); } };
        \\var bag: Bag = .{};
        \\fn bagged(_: void, _: *std.testing.Smith) anyerror!void { try bag.put(std.heap.page_allocator); }
        \\const Ctx = struct { gpa: std.mem.Allocator };
        \\const Context = struct { fn testOne(_: Context, _: *std.testing.Smith) anyerror!void { _ = try std.heap.raw_c_allocator.alloc(u8, 1); } };
        \\test "fuzz" {
        \\    try std.testing.fuzz({}, one, .{});
        \\    try std.testing.fuzz({}, one, .{});
        \\    try std.testing.fuzz({}, local, .{});
        \\    try std.testing.fuzz({}, global, .{});
        \\    const testing = std.testing;
        \\    try testing.fuzz({}, printed, .{});
        \\    try std.testing.fuzz(Ctx{ .gpa = std.heap.page_allocator }, context, .{});
        \\    try std.testing.fuzz({}, arena, .{});
        \\    try std.testing.fuzz({}, onFailure, .{});
        \\    try std.testing.fuzz({}, elements, .{});
        \\    try std.testing.fuzz({}, unbound, .{});
        \\    try std.testing.fuzz({}, memoLocal, .{});
        \\    try std.testing.fuzz({}, unfilled, .{});
        \\    try std.testing.fuzz({}, keeping, .{});
        \\    try std.testing.fuzz({}, copied, .{});
        \\    try std.testing.fuzz({}, bagged, .{});
        \\    try std.testing.fuzz(Context{}, Context.testOne, .{});
        \\    try std.testing.fuzz({}, struct { fn f(_: void, _: *std.testing.Smith) anyerror!void { _ = try std.heap.page_allocator.alloc(u8, 1); } }.f, .{});
        \\}
    ,
        \\5:135 seen.append from std.heap.page_allocator in one
        \\6:115 gpa.alloc from gpa in local
        \\7:67 shared.create from shared in global
        \\8:88 std.fmt.allocPrint from heap.c_allocator in printed
        \\9:103 list.append from ctx.gpa in context
        \\10:66 std.heap.ArenaAllocator.init from std.heap.page_allocator in arena
        \\11:79 std.heap.page_allocator.dupe from std.heap.page_allocator in onFailure
        \\12:156 shared.dupe from shared in elements
        \\13:145 shared.dupe from shared in unbound
        \\14:132 shared.dupe from shared in memoLocal
        \\16:131 shared.dupe from shared in unfilled
        \\18:64 keep from std.heap.page_allocator in keeping
        \\20:67 copyOf from shared in copied
        \\23:63 bag.put from std.heap.page_allocator in bagged
        \\25:96 std.heap.raw_c_allocator.alloc from std.heap.raw_c_allocator in testOne
        \\44:100 std.heap.page_allocator.alloc from std.heap.page_allocator in f
        \\
    );
}

test "given back, checked by the runner, or not a fuzz target: not reported" {
    try expectHoard(
        \\const std = @import("std");
        \\var seen: std.ArrayList(u8) = .empty;
        \\fn checked(_: void, _: *std.testing.Smith) anyerror!void { const copy = try std.testing.allocator.dupe(u8, "x"); _ = copy; }
        \\fn freed(_: void, _: *std.testing.Smith) anyerror!void { const copy = try std.heap.page_allocator.dupe(u8, "x"); defer std.heap.page_allocator.free(copy); }
        \\fn destroyed(_: void, _: *std.testing.Smith) anyerror!void { const n = try std.heap.page_allocator.create(u64); std.heap.page_allocator.destroy(n); }
        \\fn listed(_: void, _: *std.testing.Smith) anyerror!void { var list: std.ArrayList(u8) = .empty; defer list.deinit(std.heap.page_allocator); try list.append(std.heap.page_allocator, 1); }
        \\fn cleared(_: void, _: *std.testing.Smith) anyerror!void { defer seen.clearRetainingCapacity(); try seen.append(std.heap.page_allocator, 1); }
        \\fn arena(_: void, _: *std.testing.Smith) anyerror!void { var a = std.heap.ArenaAllocator.init(std.heap.page_allocator); defer a.deinit(); _ = try a.allocator().alloc(u8, 4); }
        \\fn onArena(_: void, _: *std.testing.Smith) anyerror!void { var a = std.heap.ArenaAllocator.init(std.testing.allocator); _ = try a.allocator().alloc(u8, 4); }
        \\fn context(ctx: Ctx, _: *std.testing.Smith) anyerror!void { var list: std.ArrayList(u8) = .empty; try list.append(ctx.gpa, 1); }
        \\fn helper() !void { _ = try std.heap.page_allocator.alloc(u8, 1); }
        \\fn calls(_: void, _: *std.testing.Smith) anyerror!void { try helper(); }
        \\fn notFuzzed(_: void, _: *std.testing.Smith) anyerror!void { _ = try std.heap.page_allocator.alloc(u8, 1); }
        \\fn other(_: void, _: *std.testing.Smith) anyerror!void { _ = try mine.page_allocator.alloc(u8, 1); }
        \\var keywords: ?[]u8 = null;
        \\var cached: ?[]u8 = null;
        \\fn memo(_: void, _: *std.testing.Smith) anyerror!void { const k = keywords orelse made: { const x = try std.heap.page_allocator.dupe(u8, "x"); keywords = x; break :made x; }; _ = k; }
        \\fn filled(_: void, _: *std.testing.Smith) anyerror!void { if (cached == null) { cached = try std.heap.page_allocator.dupe(u8, "y"); } }
        \\var first: ?[]u8 = null;
        \\var later: ?[]u8 = null;
        \\fn nullFirst(_: void, _: *std.testing.Smith) anyerror!void { if (null == first) { first = try std.heap.page_allocator.dupe(u8, "x"); } }
        \\fn notNull(_: void, _: *std.testing.Smith) anyerror!void { if (later != null) {} else { later = try std.heap.page_allocator.dupe(u8, "z"); } }
        \\fn validate(gpa: std.mem.Allocator, s: []const u8) !void { const copy = try gpa.dupe(u8, s); gpa.free(copy); }
        \\fn scratch(_: void, _: *std.testing.Smith) anyerror!void { try validate(std.heap.page_allocator, "x"); }
        \\const Box = struct { fn check(b: *Box, gpa: std.mem.Allocator) !void { _ = b; const c = try gpa.alloc(u8, 1); defer gpa.free(c); } };
        \\fn boxed(_: void, _: *std.testing.Smith) anyerror!void { var b: Box = .{}; try b.check(std.heap.page_allocator); }
        \\const Ctx = struct { gpa: std.mem.Allocator };
        \\const mine = struct { const page_allocator = std.testing.allocator; };
        \\test "fuzz" {
        \\    const once = try std.heap.page_allocator.alloc(u8, 1);
        \\    _ = once;
        \\    try std.testing.fuzz({}, checked, .{});
        \\    try std.testing.fuzz({}, freed, .{});
        \\    try std.testing.fuzz({}, destroyed, .{});
        \\    try std.testing.fuzz({}, listed, .{});
        \\    try std.testing.fuzz({}, cleared, .{});
        \\    try std.testing.fuzz({}, arena, .{});
        \\    try std.testing.fuzz({}, onArena, .{});
        \\    try std.testing.fuzz(Ctx{ .gpa = std.testing.allocator }, context, .{});
        \\    try std.testing.fuzz({}, calls, .{});
        \\    try std.testing.fuzz({}, other, .{});
        \\    try std.testing.fuzz({}, memo, .{});
        \\    try std.testing.fuzz({}, filled, .{});
        \\    try std.testing.fuzz({}, nullFirst, .{});
        \\    try std.testing.fuzz({}, notNull, .{});
        \\    try std.testing.fuzz({}, scratch, .{});
        \\    try std.testing.fuzz({}, boxed, .{});
        \\    try app_testing.fuzz({}, notFuzzed, .{});
        \\}
    , "");
}
