//! The `zigvet` command: reports code the Zig compiler accepts in every
//! build mode that is almost certainly wrong.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const build_options = @import("build_options");
const test_options = @import("test_options");
const report = @import("report.zig");
const unrun = @import("unrun.zig");
const vet = @import("vet.zig");
const walk = @import("walk.zig");

const usage =
    \\Usage: zigvet [--exclude <path>]... [--format <format>] [--summary] <path>...
    \\       zigvet --version
    \\
    \\Checks each file named, and every .zig file under each directory named,
    \\for code the Zig compiler accepts that is almost certainly wrong.
    \\Hidden files and directories, zig-out and zig-pkg are skipped.
    \\
    \\  --exclude <path>  Skip this file or directory, named as zigvet prints
    \\                    paths: relative to the current directory. May be
    \\                    given more than once.
    \\  --format <format> How to write reports: text (the default), github
    \\                    (GitHub Actions annotations) or json.
    \\  --summary         Then say on stderr how many files were checked and
    \\                    what each rule reported.
    \\
    \\Exit status: 0 if nothing was reported, 1 if a finding or parse error
    \\was, 2 on a usage error or a path that could not be read or holds no
    \\.zig file to check.
    \\
;

/// `Ast` offsets are 32-bit.
const max_source_bytes = std.math.maxInt(u32);

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    // Streaming: a positional writer writes a file stdout is redirected to
    // from byte 0, over what it held and under what is written after (#7).
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = (try init.minimal.args.toSlice(arena))[1..];
    const run = switch (try parseArgs(arena, args)) {
        .run => |run| run,
        .help => {
            try out.writeAll(usage);
            try out.flush();
            return 0;
        },
        .version => {
            try out.print("zigvet {s}\n", .{build_options.version});
            try out.flush();
            return 0;
        },
        .usage_error => |message| {
            if (message.len > 0) std.debug.print("zigvet: {s}\n\n", .{message});
            std.debug.print("{s}", .{usage});
            return 2;
        },
    };

    const cwd = Io.Dir.cwd();
    var unreadable = false;
    var files: std.ArrayList([]const u8) = .empty;
    for (run.paths) |arg| {
        const before = files.items.len;
        walk.collect(arena, io, cwd, arg, run.excludes, &files) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                std.debug.print("zigvet: {s}: {t}\n", .{ arg, err });
                unreadable = true;
                continue;
            },
        };
        // Checking nothing would read exactly like a clean run (#13).
        if (files.items.len == before) {
            std.debug.print("zigvet: {s}: no .zig file to check (hidden files and directories, zig-out, zig-pkg and excluded paths are skipped)\n", .{arg});
            unreadable = true;
        }
    }
    walk.sortUnique(&files);

    // unrun asks which files the tests reach, so it reads them all before
    // any is reported. One it cannot read or parse here may import
    // anything, and is taken to be reached.
    const summaries = try arena.alloc(unrun.Summary, files.items.len);
    for (files.items, summaries) |path, *summary| {
        summary.* = .{ .path = path, .unparsed = true };
        const source = cwd.readFileAllocOptions(io, path, gpa, .limited(max_source_bytes), .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => continue,
        };
        defer gpa.free(source);
        var tree = try std.zig.Ast.parse(gpa, source, .{});
        defer tree.deinit(gpa);
        summary.* = try unrun.summarize(gpa, arena, path, &tree);
    }
    const unrun_found = try unrun.check(arena, summaries);

    var reports: report.Out = .init(gpa, out, run.format);
    defer reports.deinit();
    try reports.begin();
    var reported: usize = 0;
    var checked: usize = 0;
    for (files.items, unrun_found) |path, *found| {
        const source = cwd.readFileAllocOptions(io, path, gpa, .limited(max_source_bytes), .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                std.debug.print("zigvet: {s}: {t}\n", .{ path, err });
                unreadable = true;
                continue;
            },
        };
        defer gpa.free(source);
        const extra: []const report.Finding = if (found.*) |*f| f[0..1] else &.{};
        reported += try vet.vetSource(gpa, path, source, extra, &reports);
        checked += 1;
    }
    try reports.end();
    try out.flush();
    // A clean run is silent, as `zig fmt --check` is, so a lint step in a
    // build prints nothing; asked, say what was looked at (#46).
    if (run.summary) std.debug.print("zigvet: checked {d} file{s}, {f}\n", .{ checked, if (checked == 1) "" else "s", reports.tally });

    if (unreadable) return 2;
    return @intFromBool(reported > 0);
}

/// What the command line asks for.
const Command = union(enum) {
    run: struct {
        paths: []const []const u8,
        /// Cleaned, as `walk.collect` cleans the paths it lists.
        excludes: []const []const u8,
        format: report.Format,
        summary: bool,
    },
    help,
    version,
    /// Why the command line cannot be run; empty when the usage alone says.
    usage_error: []const u8,
};

/// `-h` and `--help`, `--version`, and an unknown option take effect where
/// they stand; anything after them is not read.
fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!Command {
    var paths: std.ArrayList([]const u8) = .empty;
    var excludes: std.ArrayList([]const u8) = .empty;
    var format: report.Format = .text;
    var summary = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
            continue;
        }
        if (optionValue(args, &i, "--exclude")) |path| {
            if (path.len == 0) return .{ .usage_error = "--exclude needs a path" };
            try excludes.append(arena, try std.fs.path.resolveAlloc(arena, &.{path}));
        } else if (optionValue(args, &i, "--format")) |name| {
            format = std.meta.stringToEnum(report.Format, name) orelse
                return .{ .usage_error = try arena.print("--format takes text, github or json, not '{s}'", .{name}) };
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .usage_error = try arena.print("unknown option '{s}'", .{arg}) };
        } else try paths.append(arena, arg);
    }
    if (paths.items.len == 0) return .{ .usage_error = "" };
    return .{ .run = .{ .paths = paths.items, .excludes = excludes.items, .format = format, .summary = summary } };
}

/// The value of option `name` if `args[i.*]` is it, given as `name value`
/// or `name=value`; "" when the value is missing. Moves `i` past a value
/// given on its own.
fn optionValue(args: []const []const u8, i: *usize, name: []const u8) ?[]const u8 {
    const arg = args[i.*];
    if (std.mem.eql(u8, arg, name)) {
        i.* += 1;
        return if (i.* < args.len) args[i.*] else "";
    }
    return std.mem.cutPrefix(u8, std.mem.cutPrefix(u8, arg, name) orelse return null, "=");
}

test "a named path that yields no file to check is an error, not a clean run" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "empty");
    for ([_][]const u8{ "only-hidden/.cache/a.zig", "only-hidden/._a.zig", "gen/a.zig", "notes.txt" }) |sub_path| {
        try tmp.dir.createDirPath(io, std.fs.path.dirname(sub_path) orelse ".");
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "" });
    }
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.zigvet_exe, gpa);
    defer gpa.free(exe);

    // A file named outright is checked whatever its extension, and a hidden
    // directory named outright is walked.
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ exe, "empty", "only-hidden", "only-hidden/.cache", "notes.txt", "gen", "--exclude", "gen/a.zig" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings(
        \\zigvet: empty: no .zig file to check (hidden files and directories, zig-out, zig-pkg and excluded paths are skipped)
        \\zigvet: only-hidden: no .zig file to check (hidden files and directories, zig-out, zig-pkg and excluded paths are skipped)
        \\zigvet: gen: no .zig file to check (hidden files and directories, zig-out, zig-pkg and excluded paths are skipped)
        \\
    , result.stderr);
}

test "--summary says on stderr what was checked and reported, in every format" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn f() []const u8 {\n    return &.{g()};\n}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "fn g() u8 {\n    return 1;\n}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "" });
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.zigvet_exe, gpa);
    defer gpa.free(exe);

    const cases = [_]struct { argv: []const []const u8, exit: u8, stdout: []const u8, stderr: []const u8 }{
        .{ .argv = &.{ exe, "--summary", "--format", "json", "b.zig" }, .exit = 0, .stdout = "[]\n", .stderr = "zigvet: checked 1 file, no findings\n" },
        .{
            .argv = &.{ exe, ".", "--summary", "--format", "github" },
            .exit = 1,
            .stdout = "::error file=a.zig,line=2,col=12,title=zigvet escape::anonymous array made here leaves f through return. hint: make it comptime-known (`comptime` on the runtime elements) or a container-level const\n",
            .stderr = "zigvet: checked 2 files, 1 finding (escape 1)\n",
        },
        // Without it, a clean run says nothing at all.
        .{ .argv = &.{ exe, "b.zig" }, .exit = 0, .stdout = "", .stderr = "" },
    };
    for (cases) |case| {
        const result = try std.process.run(gpa, io, .{ .argv = case.argv, .cwd = .{ .dir = tmp.dir } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = case.exit }, result.term);
        try std.testing.expectEqualStrings(case.stdout, result.stdout);
        try std.testing.expectEqualStrings(case.stderr, result.stderr);
    }
}

test "unrun reads every file checked before it reports one, and an allow comment covers it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "storage");
    const files = [_][2][]const u8{
        .{ "root.zig", "pub const storage = @import(\"storage.zig\");\ntest { _ = storage; }\n" },
        .{ "storage.zig", "pub const s3 = @import(\"storage/s3.zig\");\npub const disk = @import(\"storage/disk.zig\");\ntest \"storage\" {}\n" },
        .{ "storage/s3.zig", "test \"s3\" {}\n" },
        .{ "storage/disk.zig", "// zigvet: allow unrun its own build step runs it\ntest \"disk\" {}\n" },
    };
    for (files) |file| try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.zigvet_exe, gpa);
    defer gpa.free(exe);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ exe, "." }, .cwd = .{ .dir = tmp.dir } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    // The path as zigvet prints it, with Windows's separator there.
    try std.testing.expectEqualStrings("storage" ++ std.fs.path.sep_str ++
        \\s3.zig:1:1: unrun: nothing the tests reach refers to this file, so its test never runs
        \\    hint: add `_ = s3;` to a test block in storage.zig
        \\
    , result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "parseArgs: paths and excludes, in any order" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const run = (try parseArgs(arena, &.{ "src", "--exclude", "./_tmp/", "--exclude=src/vendor", "build.zig" })).run;
    try std.testing.expectEqual(2, run.paths.len);
    try std.testing.expectEqualStrings("src", run.paths[0]);
    try std.testing.expectEqualStrings("build.zig", run.paths[1]);
    try std.testing.expectEqual(2, run.excludes.len);
    try std.testing.expectEqualStrings("_tmp", run.excludes[0]);
    try std.testing.expectEqualStrings(try std.fs.path.resolveAlloc(arena, &.{"src/vendor"}), run.excludes[1]);
    try std.testing.expectEqual(.text, run.format);
}

test "parseArgs: --format" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(.github, (try parseArgs(arena, &.{ "--format", "github", "src" })).run.format);
    try std.testing.expectEqual(.json, (try parseArgs(arena, &.{ "src", "--format=json" })).run.format);
    try std.testing.expect(!(try parseArgs(arena, &.{"src"})).run.summary);
    try std.testing.expect((try parseArgs(arena, &.{ "src", "--summary" })).run.summary);
    try std.testing.expectEqualStrings("--format takes text, github or json, not 'xml'", (try parseArgs(arena, &.{ "--format", "xml", "src" })).usage_error);
    try std.testing.expectEqualStrings("--format takes text, github or json, not ''", (try parseArgs(arena, &.{ "src", "--format" })).usage_error);
    try std.testing.expectEqualStrings("unknown option '--formats'", (try parseArgs(arena, &.{ "--formats", "src" })).usage_error);
}

test "parseArgs: help, version and usage errors" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(try parseArgs(arena, &.{ "src", "--help" }) == .help);
    try std.testing.expect(try parseArgs(arena, &.{ "-h", "-x" }) == .help);
    try std.testing.expect(try parseArgs(arena, &.{ "--version", "src" }) == .version);
    try std.testing.expectEqualStrings("--exclude needs a path", (try parseArgs(arena, &.{ "src", "--exclude" })).usage_error);
    try std.testing.expectEqualStrings("--exclude needs a path", (try parseArgs(arena, &.{ "src", "--exclude=" })).usage_error);
    try std.testing.expectEqualStrings("unknown option '-x'", (try parseArgs(arena, &.{ "-x", "--help" })).usage_error);
    try std.testing.expectEqualStrings("", (try parseArgs(arena, &.{})).usage_error);
    try std.testing.expectEqualStrings("", (try parseArgs(arena, &.{ "--exclude", "src" })).usage_error);
}

test "findings land where stdout's file is, not over its start" {
    // On Windows, `std.process.spawn` opens the file again for the child
    // rather than passing on the handle, so the child's position starts at
    // 0 whatever the writer does, and the shared file cannot be set up.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn f(x: u32) []const u32 {\n    return &.{x + 1};\n}\n" });

    // As `{ echo before; zigvet a.zig; echo after; } > out.txt` leaves it:
    // stdout is a regular file, already written to, that the shell writes
    // again after zigvet exits.
    const out = try tmp.dir.createFile(io, "out.txt", .{});
    defer out.close(io);
    try out.writeStreamingAll(io, "before\n");
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.zigvet_exe, gpa);
    defer gpa.free(exe);
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "a.zig" },
        .cwd = .{ .dir = tmp.dir },
        .stdout = .{ .file = out },
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, try child.wait(io));
    try out.writeStreamingAll(io, "after\n");

    const got = try tmp.dir.readFileAlloc(io, "out.txt", gpa, .limited(4096));
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        \\before
        \\a.zig:2:12: escape: anonymous array made here leaves f through return
        \\    hint: make it comptime-known (`comptime` on the runtime elements) or a container-level const
        \\after
        \\
    , got);
}

test {
    _ = @import("alias.zig");
    _ = @import("allow.zig");
    _ = @import("cached.zig");
    _ = @import("cancel.zig");
    _ = @import("cases.zig");
    _ = @import("children.zig");
    _ = @import("clobber.zig");
    _ = @import("copy.zig");
    _ = @import("escape.zig");
    _ = @import("expect.zig");
    _ = @import("fit.zig");
    _ = @import("flush.zig");
    _ = @import("freed.zig");
    _ = @import("grow.zig");
    _ = @import("hoard.zig");
    _ = @import("kept.zig");
    _ = @import("leak.zig");
    _ = @import("owner.zig");
    _ = @import("refill.zig");
    _ = @import("report.zig");
    _ = @import("sweep.zig");
    _ = @import("torn.zig");
    _ = @import("twice.zig");
    _ = @import("types.zig");
    _ = @import("unlock.zig");
    _ = @import("unrun.zig");
    _ = @import("vet.zig");
    _ = @import("walk.zig");
    _ = @import("wipe.zig");
}
