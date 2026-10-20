//! Checks one file: parse it, run every rule, print what is left after the
//! allow comments.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const allow = @import("allow.zig");
const escape = @import("escape.zig");
const report = @import("report.zig");
const Finding = report.Finding;

pub const Error = Allocator.Error || Writer.Error;

/// Writes `source`'s parse errors or, if it parses, its findings to `w`,
/// naming the file `path`. Returns how many it wrote.
pub fn vetSource(gpa: Allocator, path: []const u8, source: [:0]const u8, w: *Writer) Error!usize {
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);

    if (tree.errors.len > 0) {
        for (tree.errors) |parse_error| try report.writeParseError(w, path, tree, parse_error);
        return tree.errors.len;
    }

    // The rules' working memory and their findings live until the file is
    // written out.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const kept = try findings(arena_state.allocator(), &tree);
    for (kept) |finding| try report.write(w, path, tree.tokenLocation(0, finding.token), finding);
    return kept.len;
}

/// Runs every rule over `tree` and returns the findings no allow comment
/// covers, in source order. Allocated with `arena`.
pub fn findings(arena: Allocator, tree: *const Ast) Allocator.Error![]Finding {
    var all: std.ArrayList(Finding) = .empty;
    try escape.check(arena, tree, &all);
    return keep(tree.*, all.items);
}

/// Sorts `all` into source order and drops the findings an allow comment
/// covers, in place. Returns the ones kept.
fn keep(tree: Ast, all: []Finding) []Finding {
    std.mem.sort(Finding, all, {}, before);
    var kept: usize = 0;
    for (all) |finding| {
        const loc = tree.tokenLocation(0, finding.token);
        if (allow.allows(tree.source, loc.line_start, finding.rule())) continue;
        all[kept] = finding;
        kept += 1;
    }
    return all[0..kept];
}

fn before(_: void, a: Finding, b: Finding) bool {
    return a.token < b.token;
}

test "a file that fails to parse reports the parse error with its path" {
    // Same location and message as `zig ast-check` on this source.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const count = try vetSource(std.testing.allocator, "src/bad.zig", "const a = 1;\nfn f( {}\n", &out.writer);
    try std.testing.expectEqual(1, count);
    try std.testing.expectEqualStrings(
        "src/bad.zig:2:7: error: expected type expression, found '{'\n",
        out.written(),
    );
}

test "a file that parses and breaks no rule reports nothing" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const count = try vetSource(std.testing.allocator, "src/ok.zig", "fn f() void {}\n", &out.writer);
    try std.testing.expectEqual(0, count);
    try std.testing.expectEqualStrings("", out.written());
}

test "the rules run on a file and an allow comment drops one report" {
    const gpa = std.testing.allocator;
    const source =
        \\fn f(n: u8) []const u8 {
        \\    if (n == 0) {
        \\        // zigvet: allow escape only called at comptime
        \\        return &.{n};
        \\    }
        \\    return &.{n};
        \\}
        \\
    ;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectEqual(1, try vetSource(gpa, "a.zig", source, &out.writer));
    try std.testing.expectEqualStrings(
        \\a.zig:6:12: escape: anonymous array made here leaves f through return
        \\    hint: make it comptime-known (`comptime` on the runtime elements) or a container-level const
        \\
    , out.written());
}

test "keep puts findings in source order" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "fn f(n: u8) void { _ = &.{n}; _ = &.{n}; }\n", .{});
    defer tree.deinit(gpa);
    const tags = tree.tokens.items(.tag);
    const first: Ast.TokenIndex = @intCast(std.mem.findScalar(std.zig.Token.Tag, tags, .ampersand).?);
    const second: Ast.TokenIndex = @intCast(std.mem.findScalarPos(std.zig.Token.Tag, tags, first + 1, .ampersand).?);
    const detail: Finding.Detail = .{ .escape = .{ .what = "anonymous array", .function = "f", .sink = .@"return" } };
    var all = [_]Finding{
        .{ .token = second, .hint = "", .detail = detail },
        .{ .token = first, .hint = "", .detail = detail },
    };
    const kept = keep(tree, &all);
    try std.testing.expectEqual(2, kept.len);
    try std.testing.expectEqual(first, kept[0].token);
    try std.testing.expectEqual(second, kept[1].token);
}
