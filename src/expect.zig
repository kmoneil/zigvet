//! The rule tests' expected findings, compared with what a rule reports,
//! and rewritten to it under `zig build test -Dupdate`. A rewrite is for a
//! change that moves where findings point, or rewords them: read the diff
//! after it, as an expectation is only as right as its reading. One that
//! expected nothing and now finds something, or the other way round, is
//! left to fail, as that is a rule gaining or losing a finding, not one
//! moving.

const std = @import("std");
const Allocator = std.mem.Allocator;

const test_options = @import("test_options");

/// Fails unless `found` is `expected`, a multiline string literal in the
/// file `src` is in, a rule's test helper given `@src()`. Under `-Dupdate`,
/// rewrites that literal to `found` instead, when it is in the file
/// exactly once, and says so. The tests run from the repository root, and
/// `src.file` is the path under `src/`.
pub fn findings(src: std.builtin.SourceLocation, expected: []const u8, found: []const u8) !void {
    if (std.mem.eql(u8, expected, found)) return;
    if (test_options.update and expected.len > 0 and found.len > 0) {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        const path = try std.fs.path.join(gpa, &.{ "src", src.file });
        defer gpa.free(path);
        const cwd = std.Io.Dir.cwd();
        const source = try cwd.readFileAlloc(io, path, gpa, .limited(1 << 24));
        defer gpa.free(source);
        if (try rewriteLiteral(gpa, source, expected, found)) |rewritten| {
            defer gpa.free(rewritten.source);
            try cwd.writeFile(io, .{ .sub_path = path, .data = rewritten.source });
            std.debug.print("{s}:{d}: -Dupdate rewrote the expected findings to:\n{s}\n", .{ path, rewritten.line, found });
            return;
        }
        std.debug.print("{s}: -Dupdate left the expected findings as they are: they are not one multiline string literal, there once\n", .{path});
    }
    return std.testing.expectEqualStrings(expected, found);
}

/// `source` with the multiline string literal that holds exactly `old`
/// written to hold `new`, at the same indentation, owned by `gpa`, and the
/// line the literal starts on, from 1. Null when no literal, or more than
/// one, holds `old`.
pub fn rewriteLiteral(gpa: Allocator, source: []const u8, old: []const u8, new: []const u8) Allocator.Error!?struct { source: []u8, line: usize } {
    // The one literal holding `old`: the offsets of its first line's start
    // and its last line's end.
    var found: ?struct { usize, usize } = null;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var start: usize = 0;
    var run_start: ?usize = null;
    while (start <= source.len) {
        const end = std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..end];
        const body = literalLine(line);
        if (body) |b| {
            if (run_start == null) {
                run_start = start;
                content.clearRetainingCapacity();
            } else try content.append(gpa, '\n');
            try content.appendSlice(gpa, b);
        }
        const next_is_literal = end < source.len and literalLine(nextLine(source, end + 1)) != null;
        if (run_start) |first| if (!next_is_literal) {
            if (std.mem.eql(u8, content.items, old)) {
                if (found != null) return null;
                found = .{ first, end };
            }
            run_start = null;
        };
        if (end == source.len) break;
        start = end + 1;
    }
    const first, const last = found orelse return null;
    const indent = source[first .. first + (source[first..].len - std.mem.trimStart(u8, source[first..], " \t").len)];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, source[0..first]);
    var parts = std.mem.splitScalar(u8, new, '\n');
    var at_first = true;
    while (parts.next()) |part| {
        if (!at_first) try out.append(gpa, '\n');
        at_first = false;
        try out.appendSlice(gpa, indent);
        try out.appendSlice(gpa, "\\\\");
        try out.appendSlice(gpa, part);
    }
    try out.appendSlice(gpa, source[last..]);
    return .{ .source = try out.toOwnedSlice(gpa), .line = std.mem.countScalar(u8, source[0..first], '\n') + 1 };
}

/// What a line of a multiline string literal holds, after its `\\`, or
/// null for any other line.
fn literalLine(line: []const u8) ?[]const u8 {
    return std.mem.cutPrefix(u8, std.mem.trimStart(u8, line, " \t"), "\\\\");
}

/// The line of `source` that starts at `start`, without its newline.
fn nextLine(source: []const u8, start: usize) []const u8 {
    const end = std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;
    return source[start..end];
}

test "rewriteLiteral: the one literal holding the old text, at its indentation" {
    const gpa = std.testing.allocator;
    const source =
        \\test "a" {
        \\    try expectGrow(
        \\        \\fn f() void {}
        \\    ,
        \\        \\1:9 list.append
        \\        \\
        \\    );
        \\}
        \\
    ;
    const rewritten = (try rewriteLiteral(gpa, source, "1:9 list.append\n", "1:7 list.append\n2:3 map.put\n")).?;
    defer gpa.free(rewritten.source);
    try std.testing.expectEqual(5, rewritten.line);
    try std.testing.expectEqualStrings(
        \\test "a" {
        \\    try expectGrow(
        \\        \\fn f() void {}
        \\    ,
        \\        \\1:7 list.append
        \\        \\2:3 map.put
        \\        \\
        \\    );
        \\}
        \\
    , rewritten.source);
}

test "rewriteLiteral: not a literal there once, or only part of one" {
    const gpa = std.testing.allocator;
    const twice =
        \\    \\1:9 a
        \\    \\
        \\,
        \\    \\1:9 a
        \\    \\
        \\
    ;
    try std.testing.expectEqual(null, try rewriteLiteral(gpa, twice, "1:9 a\n", "1:8 a\n"));
    const longer =
        \\    \\1:9 a
        \\    \\2:4 b
        \\    \\
        \\
    ;
    try std.testing.expectEqual(null, try rewriteLiteral(gpa, longer, "1:9 a\n", "1:8 a\n"));
    try std.testing.expectEqual(null, try rewriteLiteral(gpa, longer, "3:1 c\n", "3:2 c\n"));
}
