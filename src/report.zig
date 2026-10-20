//! What zigvet reports, and how it writes it. The text form is
//! `path:line:col: <rule>: <message>`, then the fix hint on its own line.
//! An allow comment that suppresses nothing has `allow` in the rule's place,
//! and a parse error `error`. For CI the same reports can be written as
//! GitHub Actions workflow commands or as JSON.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Every rule, by the one lowercase word that names it in reports and in
/// allow comments.
pub const Rule = enum { escape, alias };

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
        alias: Alias,
        allow: Allow,
    };

    pub const Escape = struct {
        /// What is made on the stack, such as "anonymous array".
        what: []const u8,
        /// The name of the function it leaves.
        function: []const u8,
        sink: Sink,
    };

    pub const Alias = struct {
        /// What the element reads, as written.
        read: []const u8,
        /// Where the initializer is stored, as written.
        target: []const u8,
        /// What an earlier element stored that the read overlaps.
        stored: []const u8,
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
            .alias => .alias,
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
        .alias => |a| try w.print("{s} read here, but the initializer is written straight into {s} and has already stored {s}", .{
            a.read, a.target, a.stored,
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

/// How a run writes its reports: text, GitHub Actions workflow commands,
/// which annotate a pull request's diff, or one JSON array.
pub const Format = enum { text, github, json };

/// Writes every report of a run in one format. Call `begin` before the
/// first and `end` after the last: JSON needs its brackets.
pub const Out = struct {
    w: *Writer,
    format: Format,
    /// A message rendered whole, for the formats that escape it.
    message: Writer.Allocating,
    count: usize = 0,

    pub fn init(gpa: Allocator, w: *Writer, format: Format) Out {
        return .{ .w = w, .format = format, .message = .init(gpa) };
    }

    pub fn deinit(out: *Out) void {
        out.message.deinit();
    }

    pub fn begin(out: *Out) Writer.Error!void {
        if (out.format == .json) try out.w.writeByte('[');
    }

    pub fn end(out: *Out) Writer.Error!void {
        if (out.format == .json) try out.w.writeAll(if (out.count > 0) "\n]\n" else "]\n");
    }

    /// `loc` is where `finding.offset` is, from `location`.
    pub fn finding(out: *Out, path: []const u8, loc: Ast.Location, f: Finding) Writer.Error!void {
        if (out.format == .text) {
            out.count += 1;
            return write(out.w, path, loc, f);
        }
        out.message.clearRetainingCapacity();
        try writeMessage(&out.message.writer, f);
        try out.entry(path, loc.line + 1, loc.column + 1, @tagName(f.detail), out.message.written(), f.hint);
    }

    pub fn parseError(out: *Out, path: []const u8, tree: Ast, parse_error: Ast.Error) Writer.Error!void {
        if (out.format == .text) {
            out.count += 1;
            return writeParseError(out.w, path, tree, parse_error);
        }
        const loc = tree.tokenLocation(0, parse_error.token);
        out.message.clearRetainingCapacity();
        try tree.renderError(parse_error, &out.message.writer);
        try out.entry(path, loc.line + 1, loc.column + tree.errorOffset(parse_error) + 1, "error", out.message.written(), null);
    }

    /// One report in the GitHub or JSON form; `line` and `column` from 1.
    fn entry(out: *Out, path: []const u8, line: usize, column: usize, kind: []const u8, message: []const u8, hint: ?[]const u8) Writer.Error!void {
        defer out.count += 1;
        const w = out.w;
        switch (out.format) {
            .text => unreachable,
            .github => {
                try w.writeAll("::error file=");
                try writeGithub(w, path, .path);
                try w.print(",line={d},col={d},title=zigvet {s}::", .{ line, column, kind });
                try writeGithub(w, message, .message);
                if (hint) |h| {
                    try w.writeAll(". hint: ");
                    try writeGithub(w, h, .message);
                }
                try w.writeByte('\n');
            },
            .json => {
                try w.writeAll(if (out.count == 0) "\n" else ",\n");
                try std.json.Stringify.value(.{
                    .path = path,
                    .line = line,
                    .column = column,
                    .rule = kind,
                    .message = message,
                    .hint = hint,
                }, .{}, w);
            },
        }
    }
};

/// GitHub's escaping for a workflow command: `%`, CR and LF anywhere, and
/// `:` and `,` in a property, where they would end it. A path is written
/// with `/`, as GitHub names files.
fn writeGithub(w: *Writer, text: []const u8, part: enum { path, message }) Writer.Error!void {
    for (text) |c| switch (c) {
        '%' => try w.writeAll("%25"),
        '\r' => try w.writeAll("%0D"),
        '\n' => try w.writeAll("%0A"),
        ':' => try w.writeAll(if (part == .path) "%3A" else ":"),
        ',' => try w.writeAll(if (part == .path) "%2C" else ","),
        '\\' => try w.writeByte(if (part == .path) '/' else '\\'),
        else => try w.writeByte(c),
    };
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

/// The reports for `source` in `format`, as one run of one file writes them.
fn expectFormat(format: Format, path: []const u8, source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    var buffer: Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var out: Out = .init(gpa, &buffer.writer, format);
    defer out.deinit();
    try out.begin();
    for (tree.errors) |parse_error| try out.parseError(path, tree, parse_error);
    if (tree.errors.len == 0) {
        const amp = std.mem.findScalar(u8, source, '&').?;
        try out.finding(path, location(source, amp), .{
            .offset = amp,
            .hint = "make it 100% `comptime`",
            .detail = .{ .escape = .{ .what = "anonymous array", .function = "f", .sink = .@"return" } },
        });
        try out.finding(path, location(source, 0), .{ .offset = 0, .hint = "write it, then", .detail = .{ .allow = .no_rule } });
    }
    try out.end();
    try std.testing.expectEqualStrings(expected, buffer.written());
}

test "Out: text is what write and writeParseError give" {
    try expectFormat(.text, "src/a.zig", "fn f() []const u8 {\n    return &.{g()};\n}\n",
        \\src/a.zig:2:12: escape: anonymous array made here leaves f through return
        \\    hint: make it 100% `comptime`
        \\src/a.zig:1:1: allow: names no rule, so it suppresses nothing
        \\    hint: write it, then
        \\
    );
    try expectFormat(.text, "src/bad.zig", "fn f( {}\n",
        \\src/bad.zig:1:7: error: expected type expression, found '{'
        \\
    );
}

test "Out: github workflow commands, escaped" {
    try expectFormat(.github, "src\\a,b:c.zig", "fn f() []const u8 {\n    return &.{g()};\n}\n",
        \\::error file=src/a%2Cb%3Ac.zig,line=2,col=12,title=zigvet escape::anonymous array made here leaves f through return. hint: make it 100%25 `comptime`
        \\::error file=src/a%2Cb%3Ac.zig,line=1,col=1,title=zigvet allow::names no rule, so it suppresses nothing. hint: write it, then
        \\
    );
    try expectFormat(.github, "src/bad.zig", "fn f( {}\n",
        \\::error file=src/bad.zig,line=1,col=7,title=zigvet error::expected type expression, found '{'
        \\
    );
}

test "Out: one JSON array, an object per report" {
    try expectFormat(.json, "src/a.zig", "fn f() []const u8 {\n    return &.{g()};\n}\n",
        \\[
        \\{"path":"src/a.zig","line":2,"column":12,"rule":"escape","message":"anonymous array made here leaves f through return","hint":"make it 100% `comptime`"},
        \\{"path":"src/a.zig","line":1,"column":1,"rule":"allow","message":"names no rule, so it suppresses nothing","hint":"write it, then"}
        \\]
        \\
    );
    try expectFormat(.json, "src/bad.zig", "fn f( {}\n",
        \\[
        \\{"path":"src/bad.zig","line":1,"column":7,"rule":"error","message":"expected type expression, found '{'","hint":null}
        \\]
        \\
    );
    var buffer: Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var out: Out = .init(std.testing.allocator, &buffer.writer, .json);
    defer out.deinit();
    try out.begin();
    try out.end();
    try std.testing.expectEqualStrings("[]\n", buffer.written());
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
