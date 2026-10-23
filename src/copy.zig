//! Rule fifteen, copy: a `std.Io.Writer` or `Reader` interface copied out
//! of the struct its methods find with `@fieldParentPtr`.
//!
//!     var aw: std.Io.Writer.Allocating = .init(gpa);
//!     defer aw.deinit();
//!     var w = aw.writer;       // a copy
//!     try w.writeAll("hello"); // the drain looks for `aw` around `w`
//!
//! The implementations get back to themselves from the interface's
//! address: `Allocating` with `@fieldParentPtr("writer", w)`, `File.Writer`
//! with `@fieldParentPtr("interface", w)`. So the interface works only
//! where it is, through `&aw.writer`. A copy compiles clean in every build
//! mode and works until the first drain, a flush or a full buffer, which
//! reads whatever sits next to the copy as if it were the parent: a crash
//! at best. The old `std.io` writers were plain values that copied freely,
//! which is the code this looks like.
//!
//! What copies is `x.f` read as a value, `f` the interface field of `x`'s
//! type: the initializer of a local, the value of an assignment or of a
//! named field of an initializer, a `return` value, or an argument to one
//! of the file's own functions whose parameter takes a `Writer` or
//! `Reader` by value. `x`'s type is one the file shows, as escape finds
//! types, written or made by `x`'s initializer: `File.Writer`,
//! `File.Reader`, `Stream.Writer`, `Stream.Reader` and `Reader.Limited`,
//! whose field is `interface`; `Writer.Allocating`, `Writer.Discarding`,
//! `Writer.Hashing`, `Writer.Hashed` and `flate.Compress`, whose field is
//! `writer`; `Reader.Hashed` and the `Decompress` types, whose field is
//! `reader`; and `tls.Client`, which has both. A local made by a call to a
//! method named `writer`, `writerStreaming`, `reader` or `readerStreaming`
//! (`file.writer(io, &buf)`) counts as a `File.Writer` or `File.Reader`.
//!
//! Not reported: `&x.f`; a method called on it (`x.f.print(...)`), which
//! takes its address; a field read out of it; a field that is itself a
//! pointer, as `Io.Terminal`'s `writer` is, which copies fine; and a type
//! the file does not show.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every interface field copied out of the struct
/// its methods find from its address. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var t: ?types.Types = null;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .field_access) continue;
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const parent, const field_token = tree.nodeData(node).node_and_token;
        const field = tree.tokenSlice(field_token);
        if (!isInterfaceName(field)) continue;
        if (t == null) t = try .init(arena, tree);
        if (!copied(t.?, node)) continue;
        if (!holdsByValue(t.?, parent, field)) continue;
        try findings.append(arena, .{
            .offset = tree.tokenStart(tree.firstToken(node)),
            .hint = try arena.print("take a pointer instead: `&{s}`", .{tree.getNodeSource(node)}),
            .detail = .{ .copy = .{
                .interface = tree.getNodeSource(node),
                .parent = tree.getNodeSource(parent),
            } },
        });
    }
}

fn isInterfaceName(name: []const u8) bool {
    for ([_][]const u8{ "interface", "writer", "reader" }) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Whether `node` is read as a value where it is: copied into a local, a
/// place, a named field, a return value, or a by-value parameter of one of
/// the file's own functions.
fn copied(t: types.Types, node: Node.Index) bool {
    const tree = t.tree;
    const parent = t.parents[@backingInt(node)].unwrap() orelse return false;
    if (tree.fullVarDecl(parent)) |decl| return decl.ast.init_node.unwrap() == node;
    switch (tree.nodeTag(parent)) {
        .assign => return tree.nodeData(parent).node_and_node[1] == node,
        .@"return" => return true,
        else => {},
    }
    var buffer: [2]Node.Index = undefined;
    if (tree.fullStructInit(&buffer, parent)) |init| {
        // `.out = fw.interface`, not a tuple's element, which `print`'s
        // arguments are.
        return std.mem.findScalar(Node.Index, init.ast.fields, node) != null;
    }
    var call_buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, parent) orelse return false;
    const at = std.mem.findScalar(Node.Index, call.ast.params, node) orelse return false;
    const fn_decl, const shift = t.callee(call.ast.fn_expr) orelse return false;
    var proto_buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
    var params = proto.iterate(tree);
    var index: usize = 0;
    while (params.next()) |param| : (index += 1) {
        if (index != at + shift) continue;
        const type_expr = param.type_expr orelse return false;
        if (tree.fullPtrType(type_expr) != null) return false;
        const text = tree.getNodeSource(type_expr);
        return std.mem.endsWith(u8, text, "Writer") or std.mem.endsWith(u8, text, "Reader");
    }
    return false;
}

/// The std types whose methods find themselves from their interface
/// field's address, by the end of their name, and that field.
const parents = [_]struct { []const u8, []const u8 }{
    .{ "File.Writer", "interface" },
    .{ "File.Reader", "interface" },
    .{ "Stream.Writer", "interface" },
    .{ "Stream.Reader", "interface" },
    .{ "Reader.Limited", "interface" },
    .{ "Writer.Allocating", "writer" },
    .{ "Writer.Discarding", "writer" },
    .{ "flate.Compress", "writer" },
    .{ "flate.Decompress", "reader" },
    .{ "zstd.Decompress", "reader" },
    .{ "xz.Decompress", "reader" },
    .{ "tls.Client", "reader" },
    .{ "tls.Client", "writer" },
};

/// The generic ones, by the start of their name.
const generic_parents = [_]struct { []const u8, []const u8 }{
    .{ "Writer.Hashing(", "writer" },
    .{ "Writer.Hashed(", "writer" },
    .{ "Reader.Hashed(", "reader" },
};

/// Whether `place`'s type, as the file shows it, holds the interface
/// `field` by value and finds itself from its address.
fn holdsByValue(t: types.Types, place: Node.Index, field: []const u8) bool {
    const tree = t.tree;
    if (t.typeOf(place, 0)) |of| return isParent(tree.getNodeSource(types.pointee(tree, of) orelse of), field);
    if (tree.nodeTag(place) != .identifier) return false;
    var init = t.localInit(place) orelse return false;
    if (tree.nodeTag(init) == .@"try") init = tree.nodeData(init).node;
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, init) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const receiver, const method_token = tree.nodeData(call.ast.fn_expr).node_and_token;
    const method = tree.tokenSlice(method_token);
    // `file.writer(io, &buf)`: a `File.Writer`.
    for ([_][]const u8{ "writer", "writerStreaming", "reader", "readerStreaming" }) |m| {
        if (std.mem.eql(u8, method, m)) return std.mem.eql(u8, field, "interface");
    }
    // `std.Io.Writer.Allocating.init(gpa)`.
    return isParent(tree.getNodeSource(receiver), field);
}

fn isParent(type_text: []const u8, field: []const u8) bool {
    for (parents) |p| {
        if (!std.mem.eql(u8, p[1], field)) continue;
        if (std.mem.eql(u8, type_text, p[0])) return true;
        if (std.mem.endsWith(u8, type_text, p[0]) and type_text[type_text.len - p[0].len - 1] == '.') return true;
    }
    for (generic_parents) |p| {
        if (!std.mem.eql(u8, p[1], field)) continue;
        const at = std.mem.find(u8, type_text, p[0]) orelse continue;
        if (at == 0 or type_text[at - 1] == '.') return true;
    }
    return false;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col interface`, in source order.
fn expectCopy(source: [:0]const u8, expected: []const u8) !void {
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
        try out.writer.print("{d}:{d} {s}\n", .{ loc.line + 1, loc.column + 1, finding.detail.copy.interface });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "an interface copied out of the struct that finds itself from it (#56)" {
    try expectCopy(
        \\fn allocating(gpa: Allocator) !void { var aw: std.Io.Writer.Allocating = .init(gpa); defer aw.deinit(); var w = aw.writer; try w.writeAll("x"); }
        \\fn made(gpa: Allocator) !void { var aw = std.Io.Writer.Allocating.init(gpa); var w = aw.writer; try w.writeAll("x"); }
        \\fn file(io: Io, f: File) !void { var buf: [64]u8 = undefined; var fw = f.writer(io, &buf); var w = fw.interface; try w.flush(); }
        \\fn stored(self: *Self, fw: *std.Io.File.Writer) void { self.out = fw.interface; }
        \\fn named(fr: std.Io.File.Reader) Holder { return .{ .in = fr.interface }; }
        \\fn returned(fw: *File.Writer) std.Io.Writer { return fw.interface; }
        \\fn passed(fw: *File.Writer) !void { try render(fw.interface); }
        \\fn render(w: std.Io.Writer) !void { _ = w; }
        \\fn hashing(h: *std.Io.Writer.Hashing(Sha256)) void { var w = h.writer; w.end = 0; }
    ,
        \\1:113 aw.writer
        \\2:86 aw.writer
        \\3:100 fw.interface
        \\4:67 fw.interface
        \\5:59 fr.interface
        \\6:54 fw.interface
        \\7:48 fw.interface
        \\9:62 h.writer
        \\
    );
}

test "not reported: a pointer, a method, a field read, a pointer field, a type not shown" {
    try expectCopy(
        \\fn pointer(gpa: Allocator) !void { var aw: std.Io.Writer.Allocating = .init(gpa); const w = &aw.writer; try w.writeAll("x"); }
        \\fn method(gpa: Allocator) !void { var aw: std.Io.Writer.Allocating = .init(gpa); try aw.writer.writeAll("x"); }
        \\fn read(fw: *File.Writer) usize { return fw.interface.end; }
        \\fn terminal(t: Io.Terminal) void { const w = t.writer; w.writeAll("x") catch {}; }
        \\fn unknown(x: Thing) void { var w = x.writer; w.flush() catch {}; }
        \\fn wrong(aw: *std.Io.Writer.Allocating) void { var r = aw.interface; _ = &r; }
        \\fn tuple(fw: *File.Writer) void { std.debug.print("{any}", .{fw.interface}); }
        \\fn byPointer(fw: *File.Writer) !void { try render(&fw.interface); }
        \\fn render(w: *std.Io.Writer) !void { _ = w; }
    , "");
}
