//! Checks one file: parse it, run every rule, print what is left after the
//! allow comments.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const allow = @import("allow.zig");
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

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);
    // The rules run here. None is written yet; escape is the first.
    return writeFindings(w, path, tree, findings.items);
}

/// Writes the findings no allow comment covers, in source order. Returns
/// how many it wrote.
fn writeFindings(w: *Writer, path: []const u8, tree: Ast, findings: []Finding) Writer.Error!usize {
    std.mem.sort(Finding, findings, {}, before);
    var written: usize = 0;
    for (findings) |finding| {
        const loc = tree.tokenLocation(0, finding.token);
        if (allow.allows(tree.source, loc.line_start, finding.rule())) continue;
        try report.write(w, path, loc, finding);
        written += 1;
    }
    return written;
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

test "findings are written in source order and an allow comment drops one" {
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
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    const tags = tree.tokens.items(.tag);
    const first: Ast.TokenIndex = @intCast(std.mem.findScalar(std.zig.Token.Tag, tags, .ampersand).?);
    const second: Ast.TokenIndex = @intCast(std.mem.findScalarPos(std.zig.Token.Tag, tags, first + 1, .ampersand).?);
    const detail: Finding.Detail = .{ .escape = .{ .what = "anonymous array", .function = "f", .sink = .@"return" } };
    var findings = [_]Finding{
        .{ .token = second, .hint = "fix it", .detail = detail },
        .{ .token = first, .hint = "fix it", .detail = detail },
    };

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectEqual(1, try writeFindings(&out.writer, "a.zig", tree, &findings));
    try std.testing.expectEqualStrings(
        \\a.zig:6:12: escape: anonymous array made here leaves f through return
        \\    hint: fix it
        \\
    , out.written());
}
