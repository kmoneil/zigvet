//! `zigvet skill`: what an agent needs to work with zigvet, printed by the
//! binary itself, and tested here against what zigvet does: every rule's
//! example trips it and its fix reports nothing, and the output it shows
//! is what zigvet prints.

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const report = @import("report.zig");
const unrun = @import("unrun.zig");
const vet = @import("vet.zig");
const Finding = report.Finding;

pub const text = @embedFile("skill.md");

/// Writes the skill to `dir/zigvet/SKILL.md`, making the directories, and
/// returns the path written.
pub fn install(arena: Allocator, io: Io, dir: []const u8) ![]const u8 {
    const sub = try std.fs.path.join(arena, &.{ dir, "zigvet" });
    try Io.Dir.cwd().createDirPath(io, sub);
    const path = try std.fs.path.join(arena, &.{ sub, "SKILL.md" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
    return path;
}

/// The part of the skill under the `## ` heading `heading`, up to the
/// next one.
fn section(heading: []const u8) ![]const u8 {
    var at: usize = 0;
    while (std.mem.findPos(u8, text, at, heading)) |start| : (at = start + 1) {
        const line_end = start + heading.len;
        if (start > 0 and text[start - 1] != '\n') continue;
        if (line_end < text.len and text[line_end] != '\n') continue;
        return text[start .. std.mem.findPos(u8, text, line_end, "\n## ") orelse text.len];
    }
    return error.NoSection;
}

/// The body of each ```zig block in `doc`, its last newline included.
fn zigBlocks(arena: Allocator, doc: []const u8) ![]const []const u8 {
    const open = "\n```zig\n";
    var blocks: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (std.mem.findPos(u8, doc, at, open)) |start| {
        const body = start + open.len;
        const close = std.mem.findPos(u8, doc, body - 1, "\n```") orelse return error.UnclosedBlock;
        try blocks.append(arena, doc[body .. close + 1]);
        at = close + 1;
    }
    return blocks.items;
}

/// A rule's part of the skill: its name and its zig blocks, the example
/// that trips it and then the fix.
const Rule = struct {
    name: []const u8,
    blocks: []const []const u8,
};

/// Each `### ` part under `## The rules`.
fn rules(arena: Allocator) ![]const Rule {
    var out: std.ArrayList(Rule) = .empty;
    var parts = std.mem.splitSequence(u8, try section("## The rules"), "\n### ");
    _ = parts.next(); // what the rules have in common
    while (parts.next()) |part| {
        const name_end = std.mem.findScalar(u8, part, '\n') orelse part.len;
        try out.append(arena, .{ .name = part[0..name_end], .blocks = try zigBlocks(arena, part) });
    }
    return out.items;
}

const File = struct {
    path: []const u8,
    source: [:0]const u8,
};

/// The files a block holds: one, example.zig, or, where a line is a
/// comment naming a .zig file (`// root.zig`), what follows it up to the
/// next such line as that file.
fn files(arena: Allocator, block: []const u8) ![]const File {
    var out: std.ArrayList(File) = .empty;
    var path: []const u8 = "example.zig";
    var start: usize = 0;
    var at: usize = 0;
    while (at < block.len) {
        const line_end = std.mem.findScalarPos(u8, block, at, '\n') orelse block.len;
        if (fileName(block[at..line_end])) |name| {
            if (at > start) try out.append(arena, .{ .path = path, .source = try arena.dupeSentinel(u8, block[start..at], 0) });
            path = name;
            start = @min(line_end + 1, block.len);
        }
        at = line_end + 1;
    }
    try out.append(arena, .{ .path = path, .source = try arena.dupeSentinel(u8, block[start..], 0) });
    return out.items;
}

/// `name` when `line` is `// name`, and `name` a .zig file.
fn fileName(line: []const u8) ?[]const u8 {
    const name = std.mem.cutPrefix(u8, line, "// ") orelse return null;
    if (!std.mem.endsWith(u8, name, ".zig") or std.mem.findScalar(u8, name, ' ') != null) return null;
    return name;
}

/// What a run over `examples` reports, as main finds it: unrun across them
/// all, then each file's own rules and allow comments.
fn vetFiles(arena: Allocator, examples: []const File) ![]const Finding {
    const trees = try arena.alloc(Ast, examples.len);
    const summaries = try arena.alloc(unrun.Summary, examples.len);
    for (examples, trees, summaries) |file, *tree, *summary| {
        tree.* = try Ast.parse(arena, file.source, .{});
        if (tree.errors.len > 0) {
            std.debug.print("skill: this does not parse:\n{s}\n", .{file.source});
            return error.ExampleDoesNotParse;
        }
        summary.* = try unrun.summarize(std.testing.allocator, arena, file.path, tree);
    }
    var all: std.ArrayList(Finding) = .empty;
    for (trees, try unrun.check(arena, summaries)) |*tree, *found| {
        const extra: []const Finding = if (found.*) |*f| f[0..1] else &.{};
        try all.appendSlice(arena, try vet.findings(arena, tree, extra));
    }
    return all.items;
}

/// The rules each finding is of, for a message: `escape, allow`.
fn kinds(arena: Allocator, found: []const Finding) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    for (found, 0..) |f, i| try out.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", @tagName(f.detail) });
    return out.written();
}

test "every rule has an example that trips it and a fix that reports nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var named: std.EnumSet(report.Rule) = .empty;
    var ok = true;
    for (try rules(arena)) |rule| {
        const which = std.meta.stringToEnum(report.Rule, rule.name) orelse {
            std.debug.print("skill: '### {s}' names no rule zigvet has\n", .{rule.name});
            ok = false;
            continue;
        };
        if (named.contains(which)) {
            std.debug.print("skill: {s} has two sections\n", .{rule.name});
            ok = false;
        }
        named.insert(which);
        if (rule.blocks.len != 2) {
            std.debug.print("skill: {s} has {d} zig blocks, not an example and its fix\n", .{ rule.name, rule.blocks.len });
            ok = false;
            continue;
        }
        const tripped = try vetFiles(arena, try files(arena, rule.blocks[0]));
        const others = for (tripped) |f| {
            if (!std.mem.eql(u8, @tagName(f.detail), rule.name)) break true;
        } else false;
        if (tripped.len == 0 or others) {
            std.debug.print("skill: {s}'s example should report {s} alone, and reports: {s}\n", .{ rule.name, rule.name, try kinds(arena, tripped) });
            ok = false;
        }
        const fixed = try vetFiles(arena, try files(arena, rule.blocks[1]));
        if (fixed.len > 0) {
            std.debug.print("skill: {s}'s fix should report nothing, and reports: {s}\n", .{ rule.name, try kinds(arena, fixed) });
            ok = false;
        }
    }
    for (std.enums.values(report.Rule)) |which| if (!named.contains(which)) {
        std.debug.print("skill: zigvet has {t}, and the skill no section for it\n", .{which});
        ok = false;
    };
    try std.testing.expect(ok);
}

test "a block of several files splits at each comment naming one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const two = try files(arena, "// a.zig\nconst b = @import(\"b.zig\");\n\n// b.zig\ntest {}\n");
    try std.testing.expectEqual(2, two.len);
    try std.testing.expectEqualStrings("a.zig", two[0].path);
    try std.testing.expectEqualStrings("const b = @import(\"b.zig\");\n\n", two[0].source);
    try std.testing.expectEqualStrings("b.zig", two[1].path);
    try std.testing.expectEqualStrings("test {}\n", two[1].source);

    // A comment that is not a file name is code.
    const one = try files(arena, "// the caller frees it\nfn f() void {}\n");
    try std.testing.expectEqual(1, one.len);
    try std.testing.expectEqualStrings("example.zig", one[0].path);
    try std.testing.expectEqualStrings("// the caller frees it\nfn f() void {}\n", one[0].source);
}

test "the output the loop shows is what zigvet prints for escape's example" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const intro = "```console\n$ zigvet src\n";
    const start = (std.mem.find(u8, text, intro) orelse return error.NoSample) + intro.len;
    const shown = text[start .. std.mem.findPos(u8, text, start, "```") orelse return error.NoSample];
    const path = shown[0 .. std.mem.findScalar(u8, shown, ':') orelse return error.NoSample];
    const escape = for (try rules(arena)) |rule| {
        if (std.mem.eql(u8, rule.name, "escape")) break rule;
    } else return error.NoEscape;

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var reports: report.Out = .init(gpa, &out.writer, .text);
    defer reports.deinit();
    _ = try vet.vetSource(gpa, path, try arena.dupeSentinel(u8, escape.blocks[0], 0), &.{}, &reports);
    try std.testing.expectEqualStrings(shown, out.written());
}

test "the allow comment shown suppresses the finding under it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = try zigBlocks(arena, try section("## When a finding looks wrong"));
    try std.testing.expectEqual(1, blocks.len);
    const head = "fn scopes() []const []const u8 {\n";
    const allowed = try vetFiles(arena, &.{.{ .path = "a.zig", .source = try std.mem.concatWithSentinel(arena, u8, &.{ head, blocks[0], "}\n" }, 0) }});
    try std.testing.expectEqualStrings("", try kinds(arena, allowed));
    // And there is a finding to suppress.
    const code = blocks[0][(std.mem.findScalar(u8, blocks[0], '\n') orelse return error.NoComment) + 1 ..];
    const bare = try vetFiles(arena, &.{.{ .path = "a.zig", .source = try std.mem.concatWithSentinel(arena, u8, &.{ head, code, "}\n" }, 0) }});
    try std.testing.expectEqualStrings("escape", try kinds(arena, bare));
}

test "the build steps shown parse, and zigvet reports nothing in them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = try zigBlocks(arena, try section("## Add it to a build"));
    try std.testing.expectEqual(2, blocks.len);
    for (blocks) |block| {
        const source = try std.mem.concatWithSentinel(arena, u8, &.{ "pub fn build(b: *std.Build) void {\n", block, "}\n" }, 0);
        try std.testing.expectEqualStrings("", try kinds(arena, try vetFiles(arena, &.{.{ .path = "build.zig", .source = source }})));
    }
}

test "the skill names every format, and every field of a json report" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const output = try section("## Reading the output");
    inline for (comptime std.enums.values(report.Format)) |format| {
        try std.testing.expect(std.mem.find(u8, output, "`" ++ @tagName(format) ++ "`") != null);
    }

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var reports: report.Out = .init(gpa, &out.writer, .json);
    defer reports.deinit();
    try reports.begin();
    _ = try vet.vetSource(gpa, "a.zig", "fn f(a: u8) []const u8 {\n    return &.{a};\n}\n", &.{}, &reports);
    try reports.end();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const fields = parsed.array.items[0].object.keys();
    try std.testing.expectEqual(6, fields.len);
    for (fields) |field| {
        if (std.mem.find(u8, output, try arena.print("`{s}`", .{field})) == null) {
            std.debug.print("skill: a json report's `{s}` is not in \"Reading the output\"\n", .{field});
            return error.TestUnexpectedResult;
        }
    }
}

test "install writes SKILL.md under the directory named" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const dir = try std.fs.path.join(arena, &.{ base, "skills" });
    const path = try install(arena, io, dir);
    try std.testing.expect(std.mem.endsWith(u8, path, "zigvet" ++ std.fs.path.sep_str ++ "SKILL.md"));
    const written = try tmp.dir.readFileAlloc(io, "skills/zigvet/SKILL.md", arena, .limited(1 << 20));
    try std.testing.expectEqualStrings(text, written);
}
