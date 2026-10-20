//! The allow comment, `// zigvet: allow <rule> <reason>`, suppresses a report
//! of `rule` on the line after it. It may sit anywhere in the run of `//`
//! comment lines directly above the reported line, so a reason can wrap.
//! The reason is required: an allow comment without one suppresses nothing,
//! so every exception says why it is there.
//!
//! Every allow comment is accounted for. One that suppresses nothing, because
//! nothing on the line below breaks its rule any more, or because it names no
//! rule zigvet has, gives no reason, or sits at the end of a line of code, is
//! reported itself: an allow that outlived the code it excused would
//! otherwise excuse whatever is written there next.

const std = @import("std");
const Allocator = std.mem.Allocator;

const report = @import("report.zig");
const Finding = report.Finding;
const Rule = report.Rule;

/// An allow comment, by where its `//` is and what it says.
pub const Comment = struct {
    start: usize,
    meaning: Meaning,
};

pub const Meaning = union(enum) {
    /// Well formed: suppresses a report of the rule on the line below.
    allows: Rule,
    unknown_rule: []const u8,
    no_rule,
    no_reason,
    /// At the end of a line of code, where it applies to nothing.
    trailing,
};

/// Every allow comment in `source`, in order: each `//` comment, doc
/// comments aside, whose text starts `zigvet: allow`.
pub fn scan(arena: Allocator, source: []const u8) Allocator.Error![]Comment {
    var comments: std.ArrayList(Comment) = .empty;
    var line_start: usize = 0;
    while (line_start < source.len) {
        const line_end = std.mem.findScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = source[line_start..line_end];
        if (commentStart(line)) |at| {
            if (parse(line[at..])) |meaning| {
                const after_code = std.mem.trim(u8, line[0..at], " \t").len > 0;
                try comments.append(arena, .{ .start = line_start + at, .meaning = if (after_code) .trailing else meaning });
            }
        }
        line_start = line_end + 1;
    }
    return comments.items;
}

/// The `//` of the allow comment that suppresses a report of `rule` on the
/// line that starts at byte `line_start` of `source`, if there is one in
/// the comment lines directly above it.
pub fn covering(source: []const u8, line_start: usize, rule: Rule) ?usize {
    var end = line_start;
    while (end > 0) {
        // `end` is just past a '\n'; the line above runs up to that '\n'.
        const start = if (std.mem.findScalarLast(u8, source[0 .. end - 1], '\n')) |i| i + 1 else 0;
        const raw = source[start .. end - 1];
        const line = std.mem.trimStart(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, "//")) return null;
        if (parse(line)) |meaning| switch (meaning) {
            .allows => |allowed| if (allowed == rule) return start + (raw.len - line.len),
            else => {},
        };
        end = start;
    }
    return null;
}

/// The report for an allow comment that suppressed nothing.
pub fn unused(comment: Comment) Finding {
    const form = "write it as `// zigvet: allow <rule> <reason>`";
    return switch (comment.meaning) {
        .allows => |rule| .{
            .offset = comment.start,
            .hint = "delete it, or move it directly above the line it excuses",
            .detail = .{ .allow = .{ .stale = rule } },
        },
        .unknown_rule => |name| .{ .offset = comment.start, .hint = form, .detail = .{ .allow = .{ .unknown_rule = name } } },
        .no_rule => .{ .offset = comment.start, .hint = form, .detail = .{ .allow = .no_rule } },
        .no_reason => .{
            .offset = comment.start,
            .hint = "after the rule's name, say why the report is wrong",
            .detail = .{ .allow = .no_reason },
        },
        .trailing => .{
            .offset = comment.start,
            .hint = "move it onto its own line, directly above the line it excuses",
            .detail = .{ .allow = .trailing },
        },
    };
}

/// What `comment`, from its `//`, says as an allow comment; null if it is
/// not one. Doc comments (`///`, `//!`) are not: the `/` or `!` after `//`
/// stops the `zigvet:` match.
fn parse(comment: []const u8) ?Meaning {
    const body = std.mem.trimStart(u8, comment[2..], " \t");
    const rest = std.mem.cutPrefix(u8, body, "zigvet:") orelse return null;
    var words = std.mem.tokenizeAny(u8, rest, " \t\r");
    const verb = words.next() orelse return null;
    if (!std.mem.eql(u8, verb, "allow")) return null;
    const name = words.next() orelse return .no_rule;
    const rule = std.meta.stringToEnum(Rule, name) orelse return .{ .unknown_rule = name };
    if (words.next() == null) return .no_reason;
    return .{ .allows = rule };
}

/// Where the `//` comment on `line` starts, if it has one. A string or
/// character literal cannot span lines in Zig, and `\\` starts a multiline
/// string line that runs to the end of the line, so the line alone says.
fn commentStart(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) switch (line[i]) {
        '"', '\'' => |quote| {
            i += 1;
            while (i < line.len and line[i] != quote) : (i += 1) {
                if (line[i] == '\\') i += 1;
            }
        },
        '/' => if (i + 1 < line.len and line[i + 1] == '/') return i,
        '\\' => if (i + 1 < line.len and line[i + 1] == '\\') return null,
        else => {},
    };
    return null;
}

/// The byte offset where line `n` (0-based) of `source` starts. For tests.
fn lineStart(source: []const u8, n: usize) usize {
    var start: usize = 0;
    for (0..n) |_| start = std.mem.findScalarPos(u8, source, start, '\n').? + 1;
    return start;
}

fn expectAllows(expected: bool, source: []const u8, line: usize) !void {
    try std.testing.expectEqual(expected, covering(source, lineStart(source, line), .escape) != null);
}

test "allow comment on the line before" {
    const source =
        \\fn f() void {
        \\    // zigvet: allow escape only called at comptime
        \\    return &.{g()};
        \\}
    ;
    try expectAllows(true, source, 2);
}

test "allow comment with extra spacing and CRLF line ends" {
    try expectAllows(true, "\t//zigvet:   allow\tescape  why\r\n    x;\r\n", 1);
}

test "reason may wrap onto following comment lines" {
    const source =
        \\    // zigvet: allow escape only called at comptime,
        \\    // from build.zig's options step
        \\    return &.{g()};
    ;
    try expectAllows(true, source, 2);
}

test "no reason, no suppression" {
    try expectAllows(false, "// zigvet: allow escape\nx;\n", 1);
    try expectAllows(false, "// zigvet: allow escape   \nx;\n", 1);
}

test "a different rule, verb or prefix does not suppress" {
    try expectAllows(false, "// zigvet: allow escapes because\nx;\n", 1);
    try expectAllows(false, "// zigvet: deny escape because\nx;\n", 1);
    try expectAllows(false, "// escape-lint: allow escape because\nx;\n", 1);
    try expectAllows(false, "// note zigvet: allow escape because\nx;\n", 1);
}

test "doc comments do not count" {
    try expectAllows(false, "/// zigvet: allow escape because\nx;\n", 1);
    try expectAllows(false, "//! zigvet: allow escape because\nx;\n", 1);
}

test "only the comment run directly above counts" {
    // A code line or a blank line ends the run.
    try expectAllows(false, "// zigvet: allow escape because\ny;\nx;\n", 2);
    try expectAllows(false, "// zigvet: allow escape because\n\nx;\n", 2);
    // A trailing comment on the line itself is not the line before.
    try expectAllows(false, "x; // zigvet: allow escape because\n", 0);
}

test "a multiline string line that looks like a comment does not count" {
    const source =
        \\const s =
        \\    \\// zigvet: allow escape because
        \\;
    ;
    try expectAllows(false, source, 2);
}

test "first line of the file has no line before" {
    try expectAllows(false, "x;\n", 0);
}

test "covering gives the allow comment's `//`" {
    const source = "f();\n    // zigvet: allow escape why\nx;\n";
    try std.testing.expectEqual(std.mem.find(u8, source, "//").?, covering(source, lineStart(source, 2), .escape).?);
}

test "scan: every allow comment, and what it says" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const source =
        \\// zigvet: allow escape why
        \\    // zigvet: allow escpae why
        \\// zigvet: allow escape
        \\// zigvet:   allow
        \\x; // zigvet: allow escape why
        \\/// zigvet: allow escape why
        \\// zigvet: deny escape why
        \\// see zigvet: allow escape why
        \\const s = "// zigvet: allow escape why";
        \\const c = '"'; // zigvet: allow escape why
        \\const m =
        \\    \\// zigvet: allow escape why
        \\;
    ;
    const comments = try scan(arena_state.allocator(), source);
    const expected = [_]Comment{
        .{ .start = lineStart(source, 0), .meaning = .{ .allows = .escape } },
        .{ .start = lineStart(source, 1) + 4, .meaning = .{ .unknown_rule = "escpae" } },
        .{ .start = lineStart(source, 2), .meaning = .no_reason },
        .{ .start = lineStart(source, 3), .meaning = .no_rule },
        .{ .start = lineStart(source, 4) + 3, .meaning = .trailing },
        .{ .start = lineStart(source, 9) + 15, .meaning = .trailing },
    };
    try std.testing.expectEqualDeep(@as([]const Comment, &expected), comments);
}
