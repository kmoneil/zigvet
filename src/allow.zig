//! The allow comment, `// zigvet: allow <rule> <reason>`, suppresses a report
//! of `rule` on the line after it. It may sit anywhere in the run of `//`
//! comment lines directly above the reported line, so a reason can wrap.
//! The reason is required: an allow comment without one suppresses nothing,
//! so every exception says why it is there.

const std = @import("std");
const Rule = @import("report.zig").Rule;

/// Whether the comment lines directly above the line that starts at byte
/// `line_start` of `source` hold an allow comment for `rule`.
pub fn allows(source: []const u8, line_start: usize, rule: Rule) bool {
    var end = line_start;
    while (end > 0) {
        // `end` is just past a '\n'; the line above runs up to that '\n'.
        const start = if (std.mem.findScalarLast(u8, source[0 .. end - 1], '\n')) |i| i + 1 else 0;
        const line = std.mem.trim(u8, source[start .. end - 1], " \t\r");
        if (!std.mem.startsWith(u8, line, "//")) return false;
        if (isAllow(line, rule)) return true;
        end = start;
    }
    return false;
}

/// `line` is trimmed and starts with `//`. Doc comments (`///`, `//!`) do not
/// count: the `/` or `!` after `//` stops the `zigvet:` match.
fn isAllow(line: []const u8, rule: Rule) bool {
    const body = std.mem.trimStart(u8, line[2..], " \t");
    const rest = std.mem.cutPrefix(u8, body, "zigvet:") orelse return false;
    var words = std.mem.tokenizeAny(u8, rest, " \t");
    const verb = words.next() orelse return false;
    const name = words.next() orelse return false;
    if (words.next() == null) return false; // no reason
    return std.mem.eql(u8, verb, "allow") and std.mem.eql(u8, name, @tagName(rule));
}

/// The byte offset where line `n` (0-based) of `source` starts. For tests.
fn lineStart(source: []const u8, n: usize) usize {
    var start: usize = 0;
    for (0..n) |_| start = std.mem.findScalarPos(u8, source, start, '\n').? + 1;
    return start;
}

fn expectAllows(expected: bool, source: []const u8, line: usize) !void {
    try std.testing.expectEqual(expected, allows(source, lineStart(source, line), .escape));
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
