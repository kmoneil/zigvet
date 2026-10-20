//! What zigvet reports, and the one format it prints it in:
//! `path:line:col: <rule>: <message>`, then the fix hint on its own line.
//! An allow comment that suppresses nothing has `allow` in the rule's place,
//! and a parse error `error`.

const std = @import("std");
const Ast = std.zig.Ast;
const Writer = std.Io.Writer;

/// Every rule, by the one lowercase word that names it in reports and in
/// allow comments.
pub const Rule = enum { escape };

/// Where a value made on the stack leaves the function that made it.
pub const Sink = enum {
    @"return",
    field,
    global,
    out_param,

    pub fn text(sink: Sink) []const u8 {
        return switch (sink) {
            .out_param => "out param",
            else => @tagName(sink),
        };
    }
};

pub const Finding = struct {
    /// The byte in the source the report points at.
    offset: usize,
    /// One line on how to fix it.
    hint: []const u8,
    detail: Detail,

    pub const Detail = union(enum) {
        escape: Escape,
        allow: Allow,
    };

    pub const Escape = struct {
        /// What is made on the stack, such as "anonymous array".
        what: []const u8,
        /// The name of the function it leaves.
        function: []const u8,
        sink: Sink,
    };

    /// An allow comment that suppresses nothing, and why.
    pub const Allow = union(enum) {
        /// Well formed, but nothing on the line below breaks the rule.
        stale: Rule,
        unknown_rule: []const u8,
        no_rule,
        no_reason,
        /// At the end of a line of code, where it applies to nothing.
        trailing,
    };

    /// The rule an allow comment would name to suppress it. None for a
    /// report about an allow comment, which nothing can suppress.
    pub fn rule(finding: Finding) ?Rule {
        return switch (finding.detail) {
            .escape => .escape,
            .allow => null,
        };
    }
};

/// Where byte `offset` of `source` is, counted as `Ast.tokenLocation`
/// counts: lines and columns from 0, a column a byte.
pub fn location(source: []const u8, offset: usize) Ast.Location {
    const line_start = if (std.mem.findScalarLast(u8, source[0..offset], '\n')) |i| i + 1 else 0;
    return .{
        .line = std.mem.count(u8, source[0..line_start], "\n"),
        .column = offset - line_start,
        .line_start = line_start,
        .line_end = std.mem.findScalarPos(u8, source, offset, '\n') orelse source.len,
    };
}

/// Every rule's name, for a message that lists them.
const rule_names = names: {
    var names: []const u8 = "";
    for (std.enums.values(Rule)) |r| names = names ++ (if (names.len > 0) ", " else "") ++ @tagName(r);
    break :names names;
};

/// `loc` is where `finding.offset` is, from `location`.
pub fn write(w: *Writer, path: []const u8, loc: Ast.Location, finding: Finding) Writer.Error!void {
    try w.print("{s}:{d}:{d}: {t}: ", .{ path, loc.line + 1, loc.column + 1, finding.detail });
    try writeMessage(w, finding);
    try w.print("\n    hint: {s}\n", .{finding.hint});
}

/// The message alone: no location, rule name or hint.
pub fn writeMessage(w: *Writer, finding: Finding) Writer.Error!void {
    switch (finding.detail) {
        .escape => |e| try w.print("{s} made here leaves {s} through {s}", .{
            e.what, e.function, e.sink.text(),
        }),
        .allow => |a| switch (a) {
            .stale => |r| try w.print("suppresses nothing: no {t} finding on the line below it", .{r}),
            .unknown_rule => |name| try w.print("no rule named '{s}' (rules: {s})", .{ name, rule_names }),
            .no_rule => try w.writeAll("names no rule, so it suppresses nothing"),
            .no_reason => try w.writeAll("gives no reason, so it suppresses nothing"),
            .trailing => try w.writeAll("applies to the line below it, not its own line"),
        },
    }
}

pub fn writeParseError(w: *Writer, path: []const u8, tree: Ast, parse_error: Ast.Error) Writer.Error!void {
    const loc = tree.tokenLocation(0, parse_error.token);
    const column = loc.column + tree.errorOffset(parse_error);
    try w.print("{s}:{d}:{d}: error: ", .{ path, loc.line + 1, column + 1 });
    try tree.renderError(parse_error, w);
    try w.writeByte('\n');
}

test "write: escape finding" {
    const source = "fn f() []const u8 {\n    return &.{g()};\n}\n";
    var tree = try Ast.parse(std.testing.allocator, source, .{});
    defer tree.deinit(std.testing.allocator);
    const amp: Ast.TokenIndex = @intCast(std.mem.findScalar(std.zig.Token.Tag, tree.tokens.items(.tag), .ampersand).?);

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, "src/a.zig", tree.tokenLocation(0, amp), .{
        .offset = tree.tokenStart(amp),
        .hint = "make the element comptime or move the array to a container-level const",
        .detail = .{ .escape = .{ .what = "anonymous array", .function = "f", .sink = .@"return" } },
    });
    try std.testing.expectEqualStrings(
        \\src/a.zig:2:12: escape: anonymous array made here leaves f through return
        \\    hint: make the element comptime or move the array to a container-level const
        \\
    , out.written());
}

test "location: counted as Ast.tokenLocation counts" {
    const source = "fn f() []const u8 {\n\treturn &.{g()};\n}\n";
    var tree = try Ast.parse(std.testing.allocator, source, .{});
    defer tree.deinit(std.testing.allocator);
    for (0..tree.tokens.len) |i| {
        const token: Ast.TokenIndex = @intCast(i);
        try std.testing.expectEqual(tree.tokenLocation(0, token), location(source, tree.tokenStart(token)));
    }
}

test "Sink.text: out param reads as two words" {
    try std.testing.expectEqualStrings("out param", Sink.out_param.text());
    try std.testing.expectEqualStrings("return", Sink.@"return".text());
}
