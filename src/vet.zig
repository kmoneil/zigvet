//! Checks one file: parse it, run every rule, print what is left after the
//! allow comments.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const alias = @import("alias.zig");
const allow = @import("allow.zig");
const cancel = @import("cancel.zig");
const escape = @import("escape.zig");
const fit = @import("fit.zig");
// Named for the rule, apart from the findings this file keeps.
const kept_rule = @import("kept.zig");
const owner = @import("owner.zig");
const torn = @import("torn.zig");
const twice = @import("twice.zig");
const sweep = @import("sweep.zig");
const unlock = @import("unlock.zig");
const wipe = @import("wipe.zig");
const refill = @import("refill.zig");
const report = @import("report.zig");
const Finding = report.Finding;

pub const Error = Allocator.Error || Writer.Error;

/// Writes `source`'s parse errors or, if it parses, its findings to `out`,
/// naming the file `path`. Returns how many it wrote.
pub fn vetSource(gpa: Allocator, path: []const u8, source: [:0]const u8, out: *report.Out) Error!usize {
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);

    if (tree.errors.len > 0) {
        for (tree.errors) |parse_error| try out.parseError(path, tree, parse_error);
        return tree.errors.len;
    }

    // The rules' working memory and their findings live until the file is
    // written out.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const kept = try findings(arena_state.allocator(), &tree);
    for (kept) |finding| try out.finding(path, report.location(source, finding.offset), finding);
    return kept.len;
}

/// `vetSource` in the text format, for tests.
fn vetText(path: []const u8, source: [:0]const u8, w: *Writer) Error!usize {
    var out: report.Out = .init(std.testing.allocator, w, .text);
    defer out.deinit();
    return vetSource(std.testing.allocator, path, source, &out);
}

/// Runs every rule over `tree` and returns the findings no allow comment
/// covers, and a report for each allow comment that covers none, in source
/// order. Allocated with `arena`.
pub fn findings(arena: Allocator, tree: *const Ast) Allocator.Error![]Finding {
    var all: std.ArrayList(Finding) = .empty;
    try escape.check(arena, tree, &all);
    try alias.check(arena, tree, &all);
    try cancel.check(arena, tree, &all);
    try fit.check(arena, tree, &all);
    try refill.check(arena, tree, &all);
    try owner.check(arena, tree, &all);
    try kept_rule.check(arena, tree, &all);
    try torn.check(arena, tree, &all);
    try twice.check(arena, tree, &all);
    try sweep.check(arena, tree, &all);
    try unlock.check(arena, tree, &all);
    try wipe.check(arena, tree, &all);
    return keep(arena, tree.source, all.items);
}

/// Drops the findings an allow comment covers, adds a report for each allow
/// comment that covers none, and sorts the lot into source order.
fn keep(arena: Allocator, source: []const u8, all: []const Finding) Allocator.Error![]Finding {
    const comments = try allow.scan(arena, source);
    const used = try arena.alloc(bool, comments.len);
    @memset(used, false);
    var kept: std.ArrayList(Finding) = .empty;
    for (all) |finding| {
        if (finding.rule()) |rule| {
            const line_start = report.location(source, finding.offset).line_start;
            if (allow.covering(source, line_start, rule)) |start| {
                for (comments, used) |comment, *u| {
                    if (comment.start == start) u.* = true;
                }
                continue;
            }
        }
        try kept.append(arena, finding);
    }
    for (comments, used) |comment, u| {
        if (!u) try kept.append(arena, allow.unused(comment));
    }
    std.mem.sort(Finding, kept.items, {}, before);
    return kept.items;
}

fn before(_: void, a: Finding, b: Finding) bool {
    return a.offset < b.offset;
}

test "a file that fails to parse reports the parse error with its path" {
    // Same location and message as `zig ast-check` on this source.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const count = try vetText("src/bad.zig", "const a = 1;\nfn f( {}\n", &out.writer);
    try std.testing.expectEqual(1, count);
    try std.testing.expectEqualStrings(
        "src/bad.zig:2:7: error: expected type expression, found '{'\n",
        out.written(),
    );
}

test "a file that parses and breaks no rule reports nothing" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const count = try vetText("src/ok.zig", "fn f() void {}\n", &out.writer);
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
    try std.testing.expectEqual(1, try vetText("a.zig", source, &out.writer));
    try std.testing.expectEqualStrings(
        \\a.zig:6:12: escape: anonymous array made here leaves f through return
        \\    hint: make it comptime-known (`comptime` on the runtime elements) or a container-level const
        \\
    , out.written());
}

test "an allow comment that suppresses nothing is reported, with why" {
    const gpa = std.testing.allocator;
    const source =
        \\fn stale(x: u32) u32 {
        \\    // zigvet: allow escape returned by value since the refactor
        \\    return x + 1;
        \\}
        \\fn typo(x: u32) []const u32 {
        \\    // zigvet: allow escpae only run at comptime
        \\    return &.{x + 1};
        \\}
        \\fn noReason(x: u32) []const u32 {
        \\    // zigvet: allow escape
        \\    return &.{x + 1};
        \\}
        \\fn trailing(x: u32) []const u32 {
        \\    return &.{x + 1}; // zigvet: allow escape only run at comptime
        \\}
        \\fn used(x: u32) []const u32 {
        \\    // zigvet: allow escape only run at comptime
        \\    return &.{x + 1};
        \\}
        \\
    ;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectEqual(7, try vetText("a.zig", source, &out.writer));
    try std.testing.expectEqualStrings(
        \\a.zig:2:5: allow: suppresses nothing: no escape finding on the line below it
        \\    hint: delete it, or move it directly above the line it excuses
        \\a.zig:6:5: allow: no rule named 'escpae' (rules: escape, alias, cancel, fit, refill, owner, kept, torn, twice, sweep, unlock, wipe)
        \\    hint: write it as `// zigvet: allow <rule> <reason>`
        \\a.zig:7:12: escape: anonymous array made here leaves typo through return
        \\    hint: make it comptime-known (`comptime` on the runtime elements) or a container-level const
        \\a.zig:10:5: allow: gives no reason, so it suppresses nothing
        \\    hint: after the rule's name, say why the report is wrong
        \\a.zig:11:12: escape: anonymous array made here leaves noReason through return
        \\    hint: make it comptime-known (`comptime` on the runtime elements) or a container-level const
        \\a.zig:14:12: escape: anonymous array made here leaves trailing through return
        \\    hint: make it comptime-known (`comptime` on the runtime elements) or a container-level const
        \\a.zig:14:23: allow: applies to the line below it, not its own line
        \\    hint: move it onto its own line, directly above the line it excuses
        \\
    , out.written());
}

test "keep puts findings in source order" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const source = "fn f(n: u8) void { _ = &.{n}; _ = &.{n}; }\n";
    const first = std.mem.findScalar(u8, source, '&').?;
    const second = std.mem.findScalarPos(u8, source, first + 1, '&').?;
    const detail: Finding.Detail = .{ .escape = .{ .what = "anonymous array", .function = "f", .sink = .@"return" } };
    const all = [_]Finding{
        .{ .offset = second, .hint = "", .detail = detail },
        .{ .offset = first, .hint = "", .detail = detail },
    };
    const kept = try keep(arena_state.allocator(), source, &all);
    try std.testing.expectEqual(2, kept.len);
    try std.testing.expectEqual(first, kept[0].offset);
    try std.testing.expectEqual(second, kept[1].offset);
}
