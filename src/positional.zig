//! Rule twenty-one, positional: a positional writer on stdout or stderr.
//!
//!     var buf: [1024]u8 = undefined;
//!     var out = std.Io.File.stdout().writer(io, &buf);
//!     try out.interface.print("{d} rows\n", .{n});
//!     try out.interface.flush();
//!
//! `File.writer` and `File.Writer.init` make a positional writer: it writes
//! with `pwrite` at a position of its own, from byte 0, and never moves the
//! file's offset. In a terminal or a pipe `pwrite` fails and the writer
//! falls back to writing where the stream is, so it works there. Redirected
//! to a regular file it does not: it writes over whatever else is written
//! to that file. Under `prog > log 2>&1`, the usual way to keep a CI log, a
//! `std.debug.print` goes to the file's offset, from byte 0, and stdout's
//! next write lands over it: on Zig 0.17.0, `result line 1`,
//! `warning: something` and `result line 2` came out as
//! `warning: sometresult line 2`. A shell's own output around the program
//! (`{ echo before; prog; echo after; } > log`) is written over the same
//! way, and on macOS, whose `pwrite` writes at the offset given even under
//! `O_APPEND`, `prog >> log` writes over the start of the log. zigvet 0.1.0
//! had it, and lost its own findings under `zig build` (#7). It compiles
//! clean in every build mode, and a program that is the only writer of a
//! fresh file gets correct output, which is how it passes its tests.
//! `writerStreaming` and `File.Writer.initStreaming` write at the file's
//! offset, after what else was written, and cost nothing (#8).
//!
//! What is reported: `f.writer(io, buffer)`, `File.Writer.init(f, io,
//! buffer)` and `File.Writer.initDetect(...)`, or `.init(f, ...)` and
//! `.initDetect(f, ...)` for a local whose type is written as a
//! `File.Writer`, where `f` is stdout or stderr: `std.Io.File.stdout()`,
//! `File.stderr()` and the like, `.stdout()` where a `File` is expected, or
//! a `const` the function declares as one. `initDetect` picks streaming
//! only for a terminal, so it is positional for a file too.
//!
//! Not reported: the streaming writers; a writer on any other file, which
//! the program opens and is the only writer of; a writer made with
//! `Io.failing` (`.failing`, `std.Io.failing`, or a `const` the function
//! declares as one), which fails every write, so nothing reaches the stream
//! to be written over (#164); a reader; and a file the function is handed,
//! which only its caller knows.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const expect = @import("expect.zig");
const freed = @import("freed.zig");
const report = @import("report.zig");
const Finding = report.Finding;

/// Appends a finding for every positional writer made on stdout or
/// stderr. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    // Most files name neither stream: look before reading a node.
    if (std.mem.find(u8, tree.source, "stdout()") == null and std.mem.find(u8, tree.source, "stderr()") == null) return;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        // `var w: Io.File.Writer = .init(.stdout(), io, &buf);`: the type is
        // on the local, so the local is read for it.
        if (tree.fullVarDecl(node)) |decl| {
            const init = typedInit(tree, decl) orelse continue;
            if (made(tree, init, true)) |m| try add(arena, tree, findings, init, m);
        } else if (made(tree, node, false)) |m| try add(arena, tree, findings, node, m);
    }
}

/// The initializer of `decl` when it is a decl literal call (`.init(...)`,
/// `try .initDetect(...)`) and the local is written as a `File.Writer`.
/// Any other call is read where it is, as a call.
fn typedInit(tree: *const Ast, decl: Ast.full.VarDecl) ?Node.Index {
    const type_node = decl.ast.type_node.unwrap() orelse return null;
    if (!std.mem.endsWith(u8, tree.getNodeSource(type_node), "File.Writer")) return null;
    var init = decl.ast.init_node.unwrap() orelse return null;
    if (tree.nodeTag(init) == .@"try") init = tree.nodeData(init).node;
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, init) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) != .enum_literal) return null;
    return init;
}

/// What a positional writer is made on, and the call that makes a
/// streaming one instead.
const Made = struct { stream: []const u8, fix: []const u8 };

/// The stream `node` makes a positional writer on, when it is a call that
/// makes one on stdout or stderr. `typed` says the local it is stored in is
/// written as a `File.Writer`, which is what a decl literal `.init(...)`
/// needs to be one.
fn made(tree: *const Ast, node: Node.Index, typed: bool) ?Made {
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    const fn_expr = call.ast.fn_expr;
    switch (tree.nodeTag(fn_expr)) {
        // `.init(.stdout(), io, &buf)`, read only with its type.
        .enum_literal => {
            if (!typed or !positionalInit(tree.tokenSlice(tree.nodeMainToken(fn_expr)))) return null;
            return onStream(tree, node, call.ast.params);
        },
        .field_access => {
            const receiver, const method = tree.nodeData(fn_expr).node_and_token;
            const name = tree.tokenSlice(method);
            // `std.Io.File.stdout().writer(io, &buf)`.
            if (std.mem.eql(u8, name, "writer") and call.ast.params.len == 2) {
                if (failing(tree, node, call.ast.params[0])) return null;
                const stream = streamOf(tree, node, receiver) orelse return null;
                return .{ .stream = stream, .fix = "writerStreaming" };
            }
            // `std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf)`.
            if (!positionalInit(name) or !std.mem.endsWith(u8, tree.getNodeSource(receiver), "File.Writer")) return null;
            return onStream(tree, node, call.ast.params);
        },
        else => return null,
    }
}

/// Whether `name` is a `File.Writer` initializer that can make it
/// positional: `init`, or `initDetect`, which is positional for a file.
fn positionalInit(name: []const u8) bool {
    return std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "initDetect");
}

/// The `Made` for `File.Writer.init(file, io, buffer)` and the like, the
/// call `node` with `params`.
fn onStream(tree: *const Ast, node: Node.Index, params: []const Node.Index) ?Made {
    if (params.len != 3 or failing(tree, node, params[1])) return null;
    const stream = streamOf(tree, node, params[0]) orelse return null;
    return .{ .stream = stream, .fix = "initStreaming" };
}

/// Whether `io`, the io a writer is made with in the call `node`, is
/// `Io.failing`, which fails every write: `.failing`, `Io.failing`,
/// `std.Io.failing`, or a `const` the function declares as one.
fn failing(tree: *const Ast, node: Node.Index, io: Node.Index) bool {
    switch (tree.nodeTag(io)) {
        .enum_literal => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(io)), "failing"),
        .field_access => {
            const receiver, const field = tree.nodeData(io).node_and_token;
            return std.mem.eql(u8, tree.tokenSlice(field), "failing") and std.mem.endsWith(u8, tree.getNodeSource(receiver), "Io");
        },
        .identifier => {
            const init = freed.constInFn(tree, node, tree.tokenSlice(tree.nodeMainToken(io))) orelse return false;
            if (tree.nodeTag(init) == .identifier) return false;
            return failing(tree, node, init);
        },
        else => return false,
    }
}

/// `stdout` or `stderr`, when `file`, written in the call `node`, is one:
/// `std.Io.File.stdout()` and the like, `.stdout()`, or a `const` the
/// function declares as one.
fn streamOf(tree: *const Ast, node: Node.Index, file: Node.Index) ?[]const u8 {
    switch (tree.nodeTag(file)) {
        .grouped_expression => return streamOf(tree, node, tree.nodeData(file).node_and_token[0]),
        .identifier => {
            const init = freed.constInFn(tree, node, tree.tokenSlice(tree.nodeMainToken(file))) orelse return null;
            if (tree.nodeTag(init) == .identifier) return null;
            return streamOf(tree, node, init);
        },
        else => {},
    }
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, file) orelse return null;
    if (call.ast.params.len != 0) return null;
    const name = switch (tree.nodeTag(call.ast.fn_expr)) {
        .enum_literal => tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr)),
        .field_access => name: {
            const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
            if (!std.mem.endsWith(u8, tree.getNodeSource(receiver), "File")) return null;
            break :name tree.tokenSlice(method);
        },
        else => return null,
    };
    for ([_][]const u8{ "stdout", "stderr" }) |stream| {
        if (std.mem.eql(u8, name, stream)) return stream;
    }
    return null;
}

fn add(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding), node: Node.Index, m: Made) Allocator.Error!void {
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node).?;
    try findings.append(arena, .{
        .offset = tree.tokenStart(tree.firstToken(node)),
        .hint = try arena.print("make it `{s}`, which writes at the file's offset, after what else was written there", .{m.fix}),
        .detail = .{ .positional = .{
            .call = try arena.print("{s}(...)", .{tree.getNodeSource(call.ast.fn_expr)}),
            .stream = m.stream,
            .fix = m.fix,
        } },
    });
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col call on stream (fix)`, in source order.
fn expectPositional(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var findings: std.ArrayList(Finding) = .empty;
    try check(arena_state.allocator(), &tree, &findings);
    std.mem.sort(Finding, findings.items, {}, struct {
        fn before(_: void, a: Finding, b: Finding) bool {
            return a.offset < b.offset;
        }
    }.before);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (findings.items) |finding| {
        const loc = report.location(source, finding.offset);
        const p = finding.detail.positional;
        try out.writer.print("{d}:{d} {s} on {s} ({s})\n", .{ loc.line + 1, loc.column + 1, p.call, p.stream, p.fix });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a positional writer on stdout or stderr (#8)" {
    try expectPositional(
        \\fn method(io: Io) void { var buf: [64]u8 = undefined; var w = std.Io.File.stdout().writer(io, &buf); _ = &w; }
        \\fn template(io: Io) void { var buf: [64]u8 = undefined; var w: Io.File.Writer = .init(.stdout(), io, &buf); _ = &w; }
        \\fn named(io: Io) void { var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &.{}); _ = &w; }
        \\fn detect(io: Io) !void { var buf: [64]u8 = undefined; var w: File.Writer = try .initDetect(.stderr(), io, &buf); _ = &w; }
        \\fn local(io: Io) void { const out = Io.File.stdout(); var buf: [64]u8 = undefined; var w = out.writer(io, &buf); _ = &w; }
        \\fn caught(io: Io) void { var buf: [64]u8 = undefined; var w = File.Writer.initDetect(File.stdout(), io, &buf) catch return; _ = &w; }
        \\fn grouped(io: Io) void { var buf: [64]u8 = undefined; var w = (File.stderr()).writer(io, &buf); _ = &w; }
        \\fn once(io: Io) void { var buf: [64]u8 = undefined; var w: File.Writer = File.Writer.init(File.stdout(), io, &buf); _ = &w; }
        \\fn param(failing: Io) void { var buf: [64]u8 = undefined; var w = std.Io.File.stdout().writer(failing, &buf); _ = &w; }
    ,
        \\1:63 std.Io.File.stdout().writer(...) on stdout (writerStreaming)
        \\2:81 .init(...) on stdout (initStreaming)
        \\3:33 std.Io.File.Writer.init(...) on stderr (initStreaming)
        \\4:81 .initDetect(...) on stderr (initStreaming)
        \\5:92 out.writer(...) on stdout (writerStreaming)
        \\6:63 File.Writer.initDetect(...) on stdout (initStreaming)
        \\7:64 (File.stderr()).writer(...) on stderr (writerStreaming)
        \\8:74 File.Writer.init(...) on stdout (initStreaming)
        \\9:67 std.Io.File.stdout().writer(...) on stdout (writerStreaming)
        \\
    );
}

test "not reported: streaming, another file, a failing io, stdin, a reader, a file handed in" {
    try expectPositional(
        \\fn streaming(io: Io) void { var buf: [64]u8 = undefined; var w = std.Io.File.stdout().writerStreaming(io, &buf); _ = &w; }
        \\fn initStreaming(io: Io) void { var buf: [64]u8 = undefined; var w: Io.File.Writer = .initStreaming(.stdout(), io, &buf); _ = &w; }
        \\fn opened(io: Io, file: File) void { var buf: [64]u8 = undefined; var w = file.writer(io, &buf); _ = &w; }
        \\fn failingTest() void { var buf: [64]u8 = undefined; var w: File.Writer = .init(.stdout(), .failing, &buf); _ = &w; }
        \\fn failingNamed() void { var buf: [64]u8 = undefined; var w = std.Io.File.stdout().writer(std.Io.failing, &buf); _ = &w; }
        \\fn failingInit() void { var buf: [64]u8 = undefined; var w = File.Writer.init(File.stderr(), Io.failing, &buf); _ = &w; }
        \\fn failingConst() void { const io: Io = .failing; var buf: [64]u8 = undefined; var w = File.Writer.initDetect(File.stdout(), io, &buf) catch return; _ = &w; }
        \\fn input(io: Io) void { var buf: [64]u8 = undefined; var r = std.Io.File.stdin().reader(io, &buf); _ = &r; }
        \\fn reader(io: Io) void { var buf: [64]u8 = undefined; var r: Io.File.Reader = .init(.stdin(), io, &buf); _ = &r; }
        \\fn declares(io: Io) void { const out = Io.File.stdout(); _ = out; _ = io; }
        \\fn handed(io: Io, out: File) void { var buf: [64]u8 = undefined; var w = out.writer(io, &buf); _ = &w; }
        \\fn untyped(io: Io) void { var buf: [64]u8 = undefined; var t = .init(.stdout(), io, &buf); _ = &t; }
        \\fn terminal(io: Io) void { var t: Io.Terminal = .init(.stdout(), io); _ = &t; }
    , "");
}
