//! What one file's syntax shows of an integer expression's type, for the
//! rules about arithmetic: the type a name or a place is declared with (a
//! parameter, a local's annotation, a capture of a slice whose type the
//! function writes, a field of a struct the file declares, through a
//! pointer), what `@as(T, x)` and `std.mem.readInt(T, ...)` make, a local's
//! initializer when it writes no type, and whether that is signed. Never
//! across files, nor through a call's result otherwise.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;

const types = @import("types.zig");
const Types = types.Types;

/// What the syntax shows of a number's sign.
pub const Sign = enum {
    unknown,
    unsigned,
    /// A signed integer or a float.
    signed,

    /// What two operands of one arithmetic show together: one signed
    /// makes it signed, else one unsigned makes it unsigned.
    pub fn with(a: Sign, b: Sign) Sign {
        if (a == .signed or b == .signed) return .signed;
        if (a == .unsigned or b == .unsigned) return .unsigned;
        return .unknown;
    }
};

/// The type `node` is declared or made with, as written, when the syntax
/// shows it: a name's (`Types.bindingType`, else what a local is
/// initialized with), a field's of a struct the file declares, what a
/// pointer it is read through points at (`off.*` of `off: *usize`), `T` of
/// `@as(T, x)` and of `std.mem.readInt(T, ...)`.
pub fn declaredType(t: Types, node: Node.Index, depth: u8) ?Node.Index {
    const tree = t.tree;
    if (depth > 6) return null;
    const n = unparen(tree, node);
    switch (tree.nodeTag(n)) {
        .identifier => {
            if (t.bindingType(n, 0)) |declared| return declared;
            return declaredType(t, t.localInit(n) orelse return null, depth + 1);
        },
        .field_access => return t.typeOf(n, 0),
        .deref => return types.pointee(tree, declaredType(t, tree.nodeData(n).node, depth + 1) orelse return null),
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(n)), "@as")) return null;
            var buffer: [2]Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, n).?;
            return if (params.len == 2) params[0] else null;
        },
        .call_one, .call_one_comma, .call, .call_comma => return readType(tree, n),
        else => return null,
    }
}

/// `T` of `std.mem.readInt(T, ...)` or `readVarInt(T, ...)`, called
/// through any namespace.
fn readType(tree: *const Ast, node: Node.Index) ?Node.Index {
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, node).?;
    const callee = call.ast.fn_expr;
    const name = switch (tree.nodeTag(callee)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(callee)),
        .field_access => tree.tokenSlice(tree.nodeData(callee).node_and_token[1]),
        else => return null,
    };
    if (!std.mem.eql(u8, name, "readInt") and !std.mem.eql(u8, name, "readVarInt")) return null;
    if (call.ast.params.len < 2) return null;
    return call.ast.params[0];
}

/// What the syntax shows of `node`'s sign: its declared type's
/// (`declaredType`), `.len`'s and `@intFromPtr`'s (`usize`), or its
/// operands' together for arithmetic. A literal shows nothing, as it takes
/// the other operand's type.
pub fn signOf(t: Types, node: Node.Index, depth: u8) Sign {
    const tree = t.tree;
    if (depth > 6) return .unknown;
    const n = unparen(tree, node);
    switch (tree.nodeTag(n)) {
        .number_literal, .char_literal => return .unknown,
        .field_access => if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(n).node_and_token[1]), "len")) return .unsigned,
        .builtin_call_two, .builtin_call_two_comma => if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(n)), "@intFromPtr")) return .unsigned,
        .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat => {
            const lhs, const rhs = tree.nodeData(n).node_and_node;
            return signOf(t, lhs, depth + 1).with(signOf(t, rhs, depth + 1));
        },
        .shl, .shr, .shl_sat => return signOf(t, tree.nodeData(n).node_and_node[0], depth + 1),
        .identifier => if (t.bindingType(n, 0) == null) {
            return signOf(t, t.localInit(n) orelse return .unknown, depth + 1);
        },
        else => {},
    }
    return signOfType(tree, declaredType(t, n, depth) orelse return .unknown);
}

/// What the type `type_expr` is, by its name: `usize`, `u32` and C's
/// unsigned types are unsigned; `isize`, `i32`, the floats and C's signed
/// types signed.
pub fn signOfType(tree: *const Ast, type_expr: Node.Index) Sign {
    const n = unparen(tree, type_expr);
    if (tree.nodeTag(n) != .identifier) return .unknown;
    const name = tree.tokenSlice(tree.nodeMainToken(n));
    if (std.mem.eql(u8, name, "usize")) return .unsigned;
    if (std.mem.eql(u8, name, "isize") or std.mem.eql(u8, name, "comptime_float")) return .signed;
    if (name.len > 1 and (name[0] == 'u' or name[0] == 'i' or name[0] == 'f') and allDigits(name[1..])) {
        return if (name[0] == 'u') .unsigned else .signed;
    }
    if (std.mem.startsWith(u8, name, "c_u")) return .unsigned;
    const c_signed = [_][]const u8{ "c_char", "c_short", "c_int", "c_long", "c_longlong", "c_longdouble" };
    for (c_signed) |c| if (std.mem.eql(u8, name, c)) return .signed;
    return .unknown;
}

/// Whether `type_expr` names a signed integer type: `isize`, `i64`, or one
/// of C's. Not a float, which `signOfType` calls signed too.
pub fn isSignedInt(tree: *const Ast, type_expr: Node.Index) bool {
    const n = unparen(tree, type_expr);
    if (tree.nodeTag(n) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(n));
    if (std.mem.eql(u8, name, "isize")) return true;
    if (name.len > 1 and name[0] == 'i' and allDigits(name[1..])) return true;
    const c_signed = [_][]const u8{ "c_short", "c_int", "c_long", "c_longlong" };
    for (c_signed) |c| if (std.mem.eql(u8, name, c)) return true;
    return false;
}

/// The bits of the unsigned integer type `type_expr` names (`u16`), when
/// it names one; not `usize`, whose width is the target's.
pub fn unsignedBits(tree: *const Ast, type_expr: Node.Index) ?u16 {
    const n = unparen(tree, type_expr);
    if (tree.nodeTag(n) != .identifier) return null;
    const name = tree.tokenSlice(tree.nodeMainToken(n));
    if (name.len < 2 or name[0] != 'u' or !allDigits(name[1..])) return null;
    return std.fmt.parseInt(u16, name[1..], 10) catch null;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

pub fn unparen(tree: *const Ast, node: Node.Index) Node.Index {
    var n = node;
    while (tree.nodeTag(n) == .grouped_expression) n = tree.nodeData(n).node_and_token[0];
    return n;
}

test signOfType {
    const source = "const a: usize = 0; const b: u32 = 0; const c: i64 = 0; const d: f32 = 0; const e: c_uint = 0; const f: Foo = 0; const g: u = 0; const h: u8x = 0;";
    var tree = try Ast.parse(std.testing.allocator, source, .{});
    defer tree.deinit(std.testing.allocator);
    const want = [_]Sign{ .unsigned, .unsigned, .signed, .signed, .unsigned, .unknown, .unknown, .unknown };
    for (tree.rootDecls(), want) |decl, sign| {
        try std.testing.expectEqual(sign, signOfType(&tree, tree.fullVarDecl(decl).?.ast.type_node.unwrap().?));
    }
}

test signOf {
    const source =
        \\fn f(off: *usize, n: u32, d: isize, s: []const u8, p: Point) void {
        \\    const a = off.* + n;
        \\    const b = s.len - 1;
        \\    const c = std.mem.readInt(u16, s[0..2], .big);
        \\    const e = @as(u64, c) * 2;
        \\    const g = 1 + 2;
        \\    const h = d + 1;
        \\    const i = p.x;
        \\    _ = .{ a, b, c, e, g, h, i };
        \\}
        \\const Point = struct { x: i32 };
    ;
    var tree = try Ast.parse(std.testing.allocator, source, .{});
    defer tree.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t: Types = try .init(arena.allocator(), &tree);
    const want = [_]struct { []const u8, Sign }{
        .{ "a", .unsigned }, .{ "b", .unsigned }, .{ "c", .unsigned }, .{ "e", .unsigned },
        .{ "g", .unknown },  .{ "h", .signed },   .{ "i", .signed },
    };
    // Each name's last use is in the tuple.
    for (want) |w| {
        var last: ?Node.Index = null;
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @fromBackingInt(@intCast(i));
            if (tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), w[0])) last = node;
        }
        errdefer std.debug.print("{s}\n", .{w[0]});
        try std.testing.expectEqual(w[1], signOf(t, last.?, 0));
    }
}
