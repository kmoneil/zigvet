//! Rule sixteen, flush: a buffered file or stream writer written to and
//! never flushed.
//!
//!     var buf: [256]u8 = undefined;
//!     var fw = std.Io.File.stdout().writerStreaming(io, &buf);
//!     try fw.interface.print("hello from greet\n", .{});
//!
//! The writer collects what it is given in `buf`, and only `flush` (or
//! `end`, for a file) sends it on. Here the function returns, `fw` goes
//! with it, and the line is never written. It compiles clean in every
//! build mode, prints nothing and reports nothing. Code in the shape of the
//! old API, where `std.io.getStdOut().writer()` wrote straight through,
//! reads the same.
//!
//! What is a writer is a `var` local made by a call to a method named
//! `writer` or `writerStreaming`, or by `File.Writer.init` or
//! `.initStreaming`, whose last argument, the buffer, is not `&.{}`, and
//! written through its `interface` later: a call on `fw.interface`, or on
//! a local made with `&fw.interface`, other than `flush`. It is reported at
//! the declaration when nothing after it in its block flushes it
//! (`fw.interface.flush()`, `w.flush()` through such a local, or the
//! writer's own `fw.flush()` or `fw.end()`, in a `defer` or not) or hands
//! it on: `&fw`, `&fw.interface` or such a local passed to a call, stored,
//! or returned.
//!
//! Not reported: an unbuffered writer (`&.{}`), which writes straight
//! through; `Allocating` and `fixed` writers, whose buffer is the result; a
//! reader (`.init` of a type other than `File.Writer`); and a writer handed
//! to a call, which only the callee can judge.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;

/// Appends a finding for every buffered writer written to and never
/// flushed or handed on. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    for (0..tree.nodes.len) |i| {
        const block: Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        for (statements, 0..) |statement, at| {
            const decl = tree.fullVarDecl(statement) orelse continue;
            if (tree.tokenTag(decl.ast.mut_token) != .keyword_var) continue;
            const init = decl.ast.init_node.unwrap() orelse continue;
            const buffer_arg = bufferOf(tree, init, decl.ast.type_node) orelse continue;
            const name = tree.tokenSlice(decl.ast.mut_token + 1);
            var nodes: std.ArrayList(Node.Index) = .empty;
            for (statements[at + 1 ..]) |next| try within(arena, tree, next, &nodes);
            // `const w = &fw.interface;`: the writer by another name.
            var aliases: std.ArrayList([]const u8) = .empty;
            for (nodes.items) |node| {
                const alias = tree.fullVarDecl(node) orelse continue;
                const value = alias.ast.init_node.unwrap() orelse continue;
                if (isInterfacePointer(tree, value, name)) try aliases.append(arena, tree.tokenSlice(alias.ast.mut_token + 1));
            }
            var written = false;
            var settled = false;
            for (nodes.items) |node| {
                switch (use(tree, node, name, aliases.items)) {
                    .none => {},
                    .write => written = true,
                    .flush, .handed => settled = true,
                }
            }
            if (!written or settled) continue;
            try findings.append(arena, .{
                .offset = tree.tokenStart(decl.ast.mut_token + 1),
                .hint = try arena.print("flush it after the last write: `try {s}.interface.flush();`, or `{s}.end()` for a file", .{ name, name }),
                .detail = .{ .flush = .{
                    .writer = name,
                    .buffer = tree.getNodeSource(buffer_arg),
                } },
            });
        }
    }
}

/// The buffer a writer's initializer is given, when it is a buffered file
/// or stream writer: `&buf` of `file.writer(io, &buf)`. `type_node` is the
/// local's type, if written.
fn bufferOf(tree: *const Ast, init: Node.Index, type_node: Node.OptionalIndex) ?Node.Index {
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, init) orelse return null;
    const method = switch (tree.nodeTag(call.ast.fn_expr)) {
        .field_access => tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]),
        // `.init(file, io, &buf)` with the type written.
        .enum_literal => tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr)),
        else => return null,
    };
    const makes = for ([_][]const u8{ "writer", "writerStreaming", "init", "initStreaming" }) |m| {
        if (std.mem.eql(u8, method, m)) break true;
    } else false;
    if (!makes or call.ast.params.len == 0) return null;
    if (std.mem.startsWith(u8, method, "init")) {
        // `std.Io.File.Writer.init`, or `.init` for a local of that type.
        const of = if (tree.nodeTag(call.ast.fn_expr) == .field_access)
            tree.nodeData(call.ast.fn_expr).node_and_token[0]
        else
            type_node.unwrap() orelse return null;
        if (!std.mem.endsWith(u8, tree.getNodeSource(of), "File.Writer")) return null;
    }
    const last = call.ast.params[call.ast.params.len - 1];
    if (std.mem.eql(u8, tree.getNodeSource(last), "&.{}")) return null;
    return last;
}

/// Whether `node` is `&name.interface`.
fn isInterfacePointer(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    if (tree.nodeTag(node) != .address_of) return false;
    const operand = tree.nodeData(node).node;
    if (tree.nodeTag(operand) != .field_access) return false;
    const of, const field = tree.nodeData(operand).node_and_token;
    return std.mem.eql(u8, tree.tokenSlice(field), "interface") and isNamed(tree, of, name);
}

const Use = enum { none, write, flush, handed };

/// What `node` does with the writer `name`, or one of `aliases`, the
/// locals that point at its interface.
fn use(tree: *const Ast, node: Node.Index, name: []const u8, aliases: []const []const u8) Use {
    var buffer: [1]Node.Index = undefined;
    if (tree.fullCall(&buffer, node)) |call| {
        for (call.ast.params) |param| if (isHandle(tree, param, name, aliases)) return .handed;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) return .none;
        const receiver, const method_token = tree.nodeData(call.ast.fn_expr).node_and_token;
        const method = tree.tokenSlice(method_token);
        // `fw.flush()`, a `File.Writer`'s own, and `fw.end()`, which
        // flushes and sets the file's length.
        if (isNamed(tree, receiver, name)) {
            return if (std.mem.eql(u8, method, "flush") or std.mem.eql(u8, method, "end")) .flush else .none;
        }
        if (!isInterface(tree, receiver, name, aliases)) return .none;
        return if (std.mem.eql(u8, method, "flush")) .flush else .write;
    }
    switch (tree.nodeTag(node)) {
        .@"return" => {
            const value = tree.nodeData(node).opt_node.unwrap() orelse return .none;
            if (isHandle(tree, value, name, aliases) or isNamed(tree, value, name)) return .handed;
        },
        .assign => if (isHandle(tree, tree.nodeData(node).node_and_node[1], name, aliases)) return .handed,
        else => {},
    }
    var init_buffer: [2]Node.Index = undefined;
    if (tree.fullStructInit(&init_buffer, node)) |init| {
        for (init.ast.fields) |field| if (isHandle(tree, field, name, aliases)) return .handed;
    }
    return .none;
}

/// Whether `node` reaches the writer's interface: `name.interface`, or one
/// of `aliases`.
fn isInterface(tree: *const Ast, node: Node.Index, name: []const u8, aliases: []const []const u8) bool {
    if (tree.nodeTag(node) == .field_access) {
        const of, const field = tree.nodeData(node).node_and_token;
        return std.mem.eql(u8, tree.tokenSlice(field), "interface") and isNamed(tree, of, name);
    }
    for (aliases) |alias| if (isNamed(tree, node, alias)) return true;
    return false;
}

/// Whether `node` hands the writer on: `&name`, `&name.interface`, or one
/// of `aliases`.
fn isHandle(tree: *const Ast, node: Node.Index, name: []const u8, aliases: []const []const u8) bool {
    if (tree.nodeTag(node) == .address_of) {
        const operand = tree.nodeData(node).node;
        return isNamed(tree, operand, name) or isInterface(tree, operand, name, &.{});
    }
    for (aliases) |alias| if (isNamed(tree, node, alias)) return true;
    return false;
}

fn isNamed(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

/// Appends `node` and every node under it, `defer`s included, but not what
/// nested functions and types hold.
fn within(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    if (kept.isNested(tree.nodeTag(node))) return;
    try out.append(arena, node);
    var nodes: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, node, &nodes);
    for (nodes.items) |child| try within(arena, tree, child, out);
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col writer buffer`, in source order.
fn expectFlush(source: [:0]const u8, expected: []const u8) !void {
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
        const f = finding.detail.flush;
        try out.writer.print("{d}:{d} {s} {s}\n", .{ loc.line + 1, loc.column + 1, f.writer, f.buffer });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a buffered file or stream writer written to and never flushed (#58)" {
    try expectFlush(
        \\fn greet(io: Io) !void { var buf: [256]u8 = undefined; var fw = std.Io.File.stdout().writerStreaming(io, &buf); try fw.interface.print("hi\n", .{}); }
        \\fn aliased(io: Io, file: File) !void { var buf: [64]u8 = undefined; var file_writer = file.writer(io, &buf); const w = &file_writer.interface; try w.writeAll("HELLO!"); }
        \\fn typed(io: Io, file: File) !void { var buf: [64]u8 = undefined; var fw: File.Writer = .init(file, io, &buf); try fw.interface.writeByte('x'); }
        \\fn stream(io: Io, s: Stream) !void { var buf: [64]u8 = undefined; var sw = s.writer(io, &buf); try sw.interface.writeAll("GET / HTTP/1.1\r\n"); }
    ,
        \\1:60 fw &buf
        \\2:73 file_writer &buf
        \\3:71 fw &buf
        \\4:71 sw &buf
        \\
    );
}

test "not reported: flushed, ended, handed on, unbuffered, never written, an Allocating writer" {
    try expectFlush(
        \\fn flushed(io: Io) !void { var buf: [256]u8 = undefined; var fw = std.Io.File.stdout().writer(io, &buf); try fw.interface.print("hi\n", .{}); try fw.interface.flush(); }
        \\fn aliased(io: Io) !void { var buf: [256]u8 = undefined; var fw = std.Io.File.stdout().writer(io, &buf); const out = &fw.interface; try out.print("hi\n", .{}); try out.flush(); }
        \\fn deferred(io: Io) !void { var buf: [256]u8 = undefined; var fw = std.Io.File.stdout().writer(io, &buf); defer fw.interface.flush() catch {}; try fw.interface.print("hi\n", .{}); }
        \\fn ended(io: Io, file: File) !void { var buf: [256]u8 = undefined; var fw = file.writer(io, &buf); try fw.interface.writeAll("x"); try fw.end(); }
        \\fn own(io: Io, file: File) !void { var buf: [256]u8 = undefined; var fw = file.writer(io, &buf); try fw.interface.writeAll("x"); try fw.flush(); }
        \\fn handed(io: Io) !void { var buf: [256]u8 = undefined; var fw = std.Io.File.stdout().writer(io, &buf); try fw.interface.writeAll("x"); try render(&fw.interface); }
        \\fn handedAlias(io: Io) !void { var buf: [256]u8 = undefined; var fw = std.Io.File.stdout().writer(io, &buf); const w = &fw.interface; try w.writeAll("x"); try finish(w); }
        \\fn stored(self: *Self, io: Io) !void { var buf: [256]u8 = undefined; var fw = std.Io.File.stdout().writer(io, &buf); try fw.interface.writeAll("x"); self.out = &fw.interface; }
        \\fn unbuffered(io: Io) !void { var fw = std.Io.File.stdout().writer(io, &.{}); try fw.interface.print("hi\n", .{}); }
        \\fn unused(io: Io) !void { var buf: [256]u8 = undefined; var fw = std.Io.File.stdout().writer(io, &buf); _ = &fw; }
        \\fn allocating(gpa: Allocator) !void { var aw = std.Io.Writer.Allocating.init(gpa); try aw.writer.print("hi", .{}); }
        \\fn reader(io: Io, file: File) !u8 { var buf: [64]u8 = undefined; var fr: File.Reader = .init(file, io, &buf); return fr.interface.takeByte(); }
        \\fn limited(r: *Reader) !u8 { var buf: [8]u8 = undefined; var l: std.Io.Reader.Limited = .init(r, .limited(4), &buf); return l.interface.takeByte(); }
    , "");
}
