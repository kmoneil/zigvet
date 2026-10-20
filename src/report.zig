//! What zigvet reports, and the one format it prints it in:
//! `path:line:col: <rule>: <message>`, then the fix hint on its own line.
//! Parse errors use the same location prefix with `error` in the rule's place.

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
    /// The token the report points at.
    token: Ast.TokenIndex,
    /// One line on how to fix it.
    hint: []const u8,
    detail: Detail,

    pub const Detail = union(Rule) {
        escape: Escape,
    };

    pub const Escape = struct {
        /// What is made on the stack, such as "anonymous array".
        what: []const u8,
        /// The name of the function it leaves.
        function: []const u8,
        sink: Sink,
    };

    pub fn rule(finding: Finding) Rule {
        return finding.detail;
    }
};

/// `loc` is `finding.token`'s location, from `Ast.tokenLocation`.
pub fn write(w: *Writer, path: []const u8, loc: Ast.Location, finding: Finding) Writer.Error!void {
    try w.print("{s}:{d}:{d}: {t}: ", .{ path, loc.line + 1, loc.column + 1, finding.detail });
    switch (finding.detail) {
        .escape => |e| try w.print("{s} made here leaves {s} through {s}\n", .{
            e.what, e.function, e.sink.text(),
        }),
    }
    try w.print("    hint: {s}\n", .{finding.hint});
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
        .token = amp,
        .hint = "make the element comptime or move the array to a container-level const",
        .detail = .{ .escape = .{ .what = "anonymous array", .function = "f", .sink = .@"return" } },
    });
    try std.testing.expectEqualStrings(
        \\src/a.zig:2:12: escape: anonymous array made here leaves f through return
        \\    hint: make the element comptime or move the array to a container-level const
        \\
    , out.written());
}

test "Sink.text: out param reads as two words" {
    try std.testing.expectEqualStrings("out param", Sink.out_param.text());
    try std.testing.expectEqualStrings("return", Sink.@"return".text());
}
