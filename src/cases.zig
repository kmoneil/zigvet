//! The case corpus under `test/cases/`, in the form of the Zig compiler's
//! own `test/cases/`, so a case that holds up here ports straight into an
//! upstream patch. A case ends with what zigvet must report, in order:
//!
//!     // error
//!     //
//!     // :14:12: error: anonymous array made here leaves dangling through return
//!
//! or with `// compile`, for code it must report nothing in. Either way the
//! Zig compiler must accept the case. That is the admission test, checked
//! rather than assumed: a case that stops compiling under a later Zig means
//! upstream now catches the shape, and the rule should drop it. It is
//! checked for the host and for each system CI tests on, so a case one of
//! them rejects fails a local run too, not first in CI (#210).
//!
//! Run by `zig build test`, which supplies the compiler's path and runs
//! from the repository root.

const std = @import("std");
const builtin = @import("builtin");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const test_options = @import("test_options");
const report = @import("report.zig");
const vet = @import("vet.zig");

const cases_dir = "test/cases";

/// The systems CI runs `zig build test` on (.github/workflows/ci.yml): what
/// the test binary is built for there, and the `-target` that names it.
const ci_systems = [_]struct { arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag, target: []const u8 }{
    .{ .arch = .x86_64, .os = .linux, .target = "x86_64-linux" },
    .{ .arch = .aarch64, .os = .macos, .target = "aarch64-macos" },
    .{ .arch = .x86_64, .os = .windows, .target = "x86_64-windows" },
};

test "every case under test/cases" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = try Io.Dir.cwd().openDir(io, cases_dir, .{ .iterate = true });
    defer dir.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    try std.testing.expect(paths.items.len > 0);

    var failed: usize = 0;
    for (paths.items) |path| {
        const source = try dir.readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0);
        if (!try reportsAsExpected(arena, path, source)) failed += 1;
    }
    failed += try compilerRejects(arena, io, paths.items);
    if (failed > 0) {
        std.debug.print("{d} check(s) failed over {d} cases\n", .{ failed, paths.items.len });
        return error.TestUnexpectedResult;
    }
}

fn reportsAsExpected(arena: Allocator, path: []const u8, source: [:0]const u8) !bool {
    const expected = expectations(arena, source) catch {
        std.debug.print("{s}: no `// error` or `// compile` line at the end\n", .{path});
        return false;
    };
    var tree = try Ast.parse(arena, source, .{});
    var out: Io.Writer.Allocating = .init(arena);
    if (tree.errors.len > 0) {
        // An empty path gives the case form, `:line:col: error: ...`.
        for (tree.errors) |parse_error| try report.writeParseError(&out.writer, "", tree, parse_error);
    } else for (try vet.findings(arena, &tree, .{})) |finding| {
        const loc = report.location(source, finding.offset);
        try out.writer.print(":{d}:{d}: error: ", .{ loc.line + 1, loc.column + 1 });
        try report.writeMessage(&out.writer, finding);
        try out.writer.writeByte('\n');
    }
    if (std.mem.eql(u8, expected, out.written())) return true;
    // `-Dupdate`, as for the rule tests (expect.zig): only a case whose
    // findings moved or changed their words, not one that gained or lost
    // them all.
    if (test_options.update and expected.len > 0 and out.written().len > 0) {
        const full_path = try std.fs.path.join(arena, &.{ cases_dir, path });
        try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = full_path, .data = try rewriteCase(arena, source, out.written()) });
        std.debug.print("{s}: -Dupdate rewrote the expected findings to:\n{s}\n", .{ full_path, out.written() });
        return true;
    }
    std.debug.print("{s}: expected\n{s}found\n{s}\n", .{ path, expected, out.written() });
    return false;
}

/// `source`, a case that ends with `// error` and its findings, ending with
/// `found`'s instead, one `// ` line each.
fn rewriteCase(arena: Allocator, source: []const u8, found: []const u8) Allocator.Error![]const u8 {
    var header: usize = 0;
    var start: usize = 0;
    while (start < source.len) {
        const end = std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, source[start..end], "\r"), "// error")) header = start;
        start = end + 1;
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, source[0..header]);
    try out.appendSlice(arena, "// error\n//\n");
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, found, "\n"), '\n');
    while (lines.next()) |line| try out.print(arena, "// {s}\n", .{line});
    return out.items;
}

test "rewriteCase: the findings after the last `// error`, replaced" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const rewritten = try rewriteCase(arena_state.allocator(),
        \\fn f() void {}
        \\
        \\// error
        \\//
        \\// :1:1: error: old
        \\
    , ":1:4: error: new\n:2:1: error: also\n");
    try std.testing.expectEqualStrings(
        \\fn f() void {}
        \\
        \\// error
        \\//
        \\// :1:4: error: new
        \\// :2:1: error: also
        \\
    , rewritten);
}

/// The expected report lines, `// ` removed, one per line: everything
/// after the last `// error` line that starts `// :`. Nothing for
/// `// compile`.
fn expectations(arena: Allocator, source: []const u8) error{ OutOfMemory, NoHeader }![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| try lines.append(arena, std.mem.trimEnd(u8, line, "\r"));

    var i = lines.items.len;
    while (i > 0) {
        i -= 1;
        const line = lines.items[i];
        if (std.mem.eql(u8, line, "// compile")) return "";
        if (!std.mem.eql(u8, line, "// error")) continue;
        var expected: std.ArrayList(u8) = .empty;
        for (lines.items[i + 1 ..]) |after| {
            const body = std.mem.cutPrefix(u8, after, "// ") orelse continue;
            if (!std.mem.startsWith(u8, body, ":")) continue;
            try expected.appendSlice(arena, body);
            try expected.append(arena, '\n');
        }
        return expected.items;
    }
    return error.NoHeader;
}

/// Compiles each case for the host and for each system in `ci_systems` the
/// host is not, all at once (the test runner's Io caps it at the CPU
/// count), and prints each run that rejects its case. Returns how many did.
/// One at a time, the host's compiles alone took longer than all of them
/// take together.
fn compilerRejects(arena: Allocator, io: Io, paths: []const []const u8) !usize {
    var targets: std.ArrayList(?[]const u8) = .empty;
    try targets.append(arena, null);
    for (ci_systems) |system| {
        if (system.arch == builtin.cpu.arch and system.os == builtin.os.tag) continue;
        try targets.append(arena, system.target);
    }
    const compiles = try arena.alloc(Compile, paths.len * targets.items.len);
    for (paths, 0..) |path, i| {
        const full_path = try std.fs.path.join(arena, &.{ cases_dir, path });
        for (targets.items, 0..) |target, j| compiles[i * targets.items.len + j] = .{ .path = full_path, .target = target };
    }
    var group: Io.Group = .init;
    for (compiles) |*compile| group.async(io, Compile.run, .{ compile, io });
    try group.await(io);

    var rejected: usize = 0;
    var failure: ?Compile.Error = null;
    for (compiles) |compile| {
        if (compile.failure) |err| failure = failure orelse err;
        const stderr = compile.rejected orelse continue;
        defer std.testing.allocator.free(stderr);
        rejected += 1;
        if (compile.target) |target| {
            std.debug.print("{s}: the Zig compiler rejects it for {s}, a system CI tests on:\n{s}\n", .{ compile.path, target, stderr });
        } else {
            std.debug.print("{s}: the Zig compiler rejects it, so it is not a case zigvet needs:\n{s}\n", .{ compile.path, stderr });
        }
    }
    if (failure) |err| return err;
    return rejected;
}

/// One run of the compiler over one case, for the host or for a target.
/// Run on a thread of its own, so it allocates with std.testing.allocator,
/// which may be shared between threads, rather than the test's arena.
const Compile = struct {
    path: []const u8,
    /// A `-target`, or null for the host.
    target: ?[]const u8,
    /// What the compiler printed when it rejected the case, or null.
    rejected: ?[]u8 = null,
    /// Why the compiler could not be run, or null.
    failure: ?Error = null,

    const Error = std.process.RunError;

    fn run(compile: *Compile, io: Io) void {
        const gpa = std.testing.allocator;
        const argv: [6][]const u8 = .{ test_options.zig_exe, "build-obj", "-fno-emit-bin", compile.path, "-target", compile.target orelse "" };
        const result = std.process.run(gpa, io, .{ .argv = argv[0..if (compile.target == null) 4 else 6] }) catch |err| {
            compile.failure = err;
            return;
        };
        gpa.free(result.stdout);
        if (result.term.success()) gpa.free(result.stderr) else compile.rejected = result.stderr;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "expectations: error lines after the header, metadata and blank lines skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try expectations(arena_state.allocator(),
        \\fn f() void {}
        \\
        \\// error
        \\// backend=selfhosted
        \\//
        \\// :1:4: error: one
        \\// :2:1: error: two
        \\
    );
    try std.testing.expectEqualStrings(":1:4: error: one\n:2:1: error: two\n", got);
}

test "expectations: compile expects nothing, and a missing header is an error" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("", try expectations(arena_state.allocator(), "fn f() void {}\n\n// compile\n"));
    try std.testing.expectError(error.NoHeader, expectations(arena_state.allocator(), "fn f() void {}\n"));
}
