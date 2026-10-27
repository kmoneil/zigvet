//! Rule twelve, wipe: a local wiped with `@memset` as the last thing done
//! with it, a dead store release builds drop.
//!
//!     var secret: [64]u8 = undefined;
//!     defer @memset(&secret, 0);
//!
//! Nothing reads `secret` after the `memset`, and its life ends with it, so
//! to the optimizer the store is dead: in ReleaseFast it is not there at
//! all, even when the local's address was handed to a call before, and the
//! secret stays in the stack slot for whatever reads that memory next. It
//! compiles clean in every build mode, and Debug keeps the store, so a test
//! of the wipe passes. `std.crypto.secureZero` writes through a volatile
//! pointer, which the optimizer must keep.
//!
//! What wipes is `@memset(&x, 0)`, `@memset(&x.field, 0)` or
//! `@memset(x[a..b], 0)`, where `x` is a `var` local held by value: an
//! array, or a value made with an initializer or of a struct the file
//! declares. It is reported in a `defer` in `x`'s own block, which runs as
//! the block ends, or as a statement followed in that block only by
//! statements that do not name `x`.
//!
//! Not reported: a `memset` followed by a use of `x` (initialization, or
//! reuse in a loop); one a `defer` declared before it reads after it; what
//! a pointer or slice points at, which may be the heap; a value other than
//! zero, as a test writes `'x'` over a buffer to show a callee kept its own
//! copy; code in a `test` block; and `std.crypto.secureZero`.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const expect = @import("expect.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every `@memset` of a local held by value that
/// nothing reads after. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var t: ?types.Types = null;
    for (0..tree.nodes.len) |i| {
        const block: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        for (statements, 0..) |statement, at| {
            const deferred = tree.nodeTag(statement) == .@"defer";
            const wiping = if (deferred) tree.nodeData(statement).node else statement;
            const name = wiped(tree, wiping) orelse continue;
            if (t == null) t = try .init(arena, tree);
            if (!heldByValue(t.?, statements[0..at], name)) continue;
            if (inTest(tree, t.?.parents, block)) continue;
            if (deferred) {
                // A defer declared before it runs after it, and may read it.
                if (names(tree, statements[0..at], name, true)) continue;
            } else {
                if (names(tree, statements[at + 1 ..], name, false)) continue;
            }
            try findings.append(arena, .{
                .offset = tree.tokenStart(tree.firstToken(wiping)),
                .hint = hint,
                .detail = .{ .wipe = .{ .local = name } },
            });
        }
    }
}

const hint = "wipe it with `std.crypto.secureZero`, which writes through a volatile pointer that release builds keep";

/// The local `node` wipes, `x` of `@memset(&x, v)`, `@memset(&x.f, v)` or
/// `@memset(x[a..b], v)`.
fn wiped(tree: *const Ast, node: Node.Index) ?[]const u8 {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@memset")) return null;
    var buffer: [2]Node.Index = undefined;
    const params = tree.builtinCallParams(&buffer, node).?;
    if (params.len != 2) return null;
    // A wipe writes zero. Another value is a probe, as a test writes `'x'`
    // over a buffer to show a callee kept its own copy.
    if (!isZero(tree, params[1])) return null;
    var n = params[0];
    switch (tree.nodeTag(n)) {
        .address_of => n = tree.nodeData(n).node,
        .slice_open, .slice, .slice_sentinel => n = tree.fullSlice(n).?.ast.sliced,
        else => return null,
    }
    // `&x.bytes`: the local is `x`, held by value if `x` is.
    while (tree.nodeTag(n) == .field_access) n = tree.nodeData(n).node_and_token[0];
    if (tree.nodeTag(n) != .identifier) return null;
    return tree.tokenSlice(tree.nodeMainToken(n));
}

/// Whether `node` is zero: `0`, `0x00` or `'\x00'`.
fn isZero(tree: *const Ast, node: Node.Index) bool {
    const text = tree.tokenSlice(tree.nodeMainToken(node));
    return switch (tree.nodeTag(node)) {
        .number_literal => (std.fmt.parseInt(u64, text, 0) catch return false) == 0,
        .char_literal => std.mem.eql(u8, text, "'\\x00'") or std.mem.eql(u8, text, "'\\0'"),
        else => false,
    };
}

/// Whether `node` is in a `test` block.
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

/// Whether `name` is a `var` local declared among `statements`, held by
/// value: an array, made with an initializer, or of a struct the file
/// declares.
fn heldByValue(t: types.Types, statements: []const Node.Index, name: []const u8) bool {
    const tree = t.tree;
    for (statements) |statement| {
        const decl = tree.fullVarDecl(statement) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)) continue;
        if (tree.tokenTag(decl.ast.mut_token) != .keyword_var) return false;
        if (decl.ast.type_node.unwrap()) |type_node| {
            switch (tree.nodeTag(type_node)) {
                .array_type, .array_type_sentinel => return true,
                else => {},
            }
            if (tree.fullPtrType(type_node) != null or tree.nodeTag(type_node) == .optional_type) return false;
            if (t.containerOf(type_node, 0) != null) return true;
        }
        const init = decl.ast.init_node.unwrap() orelse return false;
        var buffer: [2]Node.Index = undefined;
        return tree.fullStructInit(&buffer, init) != null or tree.fullArrayInit(&buffer, init) != null;
    }
    return false;
}

/// Whether one of `statements` names `name`: as a token anywhere in it,
/// or, with `defers_only`, in a `defer` among them.
fn names(tree: *const Ast, statements: []const Node.Index, name: []const u8, defers_only: bool) bool {
    for (statements) |statement| {
        if (defers_only and tree.nodeTag(statement) != .@"defer") continue;
        for (tree.firstToken(statement)..tree.lastToken(statement) + 1) |token| {
            if (tree.tokenTag(@intCast(token)) == .identifier and std.mem.eql(u8, tree.tokenSlice(@intCast(token)), name)) return true;
        }
    }
    return false;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col local`, in source order.
fn expectWipe(source: [:0]const u8, expected: []const u8) !void {
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
        try out.writer.print("{d}:{d} {s}\n", .{ loc.line + 1, loc.column + 1, finding.detail.wipe.local });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a local wiped with @memset as the last thing done with it (#62)" {
    try expectWipe(
        \\const Answer = struct { bytes: [64]u8 = undefined, len: usize = 0 };
        \\fn signIn(p: [*]const u8, n: usize) u32 { var secret: [64]u8 = undefined; defer @memset(&secret, 0); @memcpy(secret[0..n], p[0..n]); return use(&secret, n); }
        \\fn answer() u32 { var a: Answer = .{}; defer @memset(&a.bytes, 0); return fill(&a); }
        \\fn last(p: []const u8) u32 { var key: [32]u8 = undefined; @memcpy(&key, p[0..32]); const h = hash(&key); @memset(&key, 0); return h; }
        \\fn sliced(n: usize) u32 { var buf: [128]u8 = undefined; defer @memset(buf[0..], 0); return fill(buf[0..n]); }
        \\fn typed() u32 { var a = Answer{}; defer @memset(&a.bytes, 0); return fill(&a); }
    ,
        \\2:81 secret
        \\3:46 a
        \\4:106 key
        \\5:63 buf
        \\6:42 a
        \\
    );
}

test "not reported: initialization, reuse, a pointer or slice, read by an earlier defer, secureZero" {
    try expectWipe(
        \\fn init() u32 { var buf: [16]u8 = undefined; @memset(&buf, 0); return sum(&buf); }
        \\fn loop(items: []const u8) void { var buf: [16]u8 = undefined; for (items) |it| { @memset(&buf, 0); buf[0] = it; send(&buf); } }
        \\fn heap(gpa: Allocator) !void { var buf: []u8 = try gpa.alloc(u8, 16); defer gpa.free(buf); defer @memset(buf, 0); fill(buf); }
        \\fn pointer(p: *[16]u8) void { var q = p; defer @memset(q, 0); fill(q); }
        \\fn earlier() u32 { var buf: [16]u8 = undefined; defer log(&buf); defer @memset(&buf, 0); return fill(&buf); }
        \\fn secure() u32 { var buf: [16]u8 = undefined; defer std.crypto.secureZero(u8, &buf); return fill(&buf); }
        \\fn constant() u32 { const table = [_]u8{1, 2}; return table[0]; }
        \\fn probe(c: *Client) !void { var first = [_]u8{ 'a', 'b' }; try c.keep(&first); @memset(&first, 'x'); try c.check(); }
        \\test "wiped" { var key: [4]u8 = undefined; fill(&key); @memset(&key, 0); }
    , "");
}
