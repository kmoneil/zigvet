//! Rule four, fit: a float printed in full decimal by `std.mem.print` or
//! `std.fmt.bufPrint` into a buffer too small for it, with the error
//! asserted away by `catch unreachable`.
//!
//! `{d}` (and `{}` or `{any}`) on a float never switches to scientific
//! notation, so an f64 can print as 327 bytes (310 for the largest, 327 for
//! the smallest subnormal), an f32 as 48 and an f16 as 11, and a precision
//! only adds to it. Into a buffer smaller than that, a large or tiny value
//! makes the call return error.NoSpaceLeft, which `catch unreachable` turns
//! into a panic in Debug and ReleaseSafe and into undefined behavior in
//! ReleaseFast and ReleaseSmall. The buffer size reads as a fair guess
//! because it is one for integers: a u64 is at most 20 digits.
//!
//! Everything is read from the syntax: the format string, the buffer's
//! length (`var buf: [48]u8`, a container-level constant, or
//! `std.fmt.float.min_buffer_size`), and the value's type as the file
//! writes it: a parameter, local, capture or container-level variable
//! declared `f16`, `f32` or `f64`, or such a field of a struct the file
//! declares. A float whose type is not written (`anytype`, an untyped
//! local) is not looked at, nor f80 and f128.
//!
//! A value bounded before it is printed is fine, and the bound can take
//! many shapes, so any will do: the call is not reported when, earlier in
//! the function, the value, or a local made from it, is compared with `<`,
//! `<=`, `>` or `>=`, or passed to `@min`, `@max` or `clamp`. Nor is a
//! value made from an integer with `@floatFromInt`, which is as short as
//! the integer, or a constant whose value is a literal.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");
const Types = types.Types;

/// Appends a finding for every float that can overflow the buffer a
/// `print ... catch unreachable` prints it into. Everything is allocated
/// with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings, .types = undefined };
    var any = false;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) == .@"catch" and rule.assertsAway(node)) any = true;
    }
    if (!any) return;
    rule.types = try .init(arena, tree);
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) == .@"catch" and rule.assertsAway(node)) try rule.call(node);
    }
}

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),
    types: Types,

    /// Whether `node`, a `catch`, is `catch unreachable` on a call.
    fn assertsAway(r: *const Rule, node: Node.Index) bool {
        const tree = r.tree;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        if (tree.nodeTag(rhs) != .unreachable_literal) return false;
        return switch (tree.nodeTag(lhs)) {
            .call_one, .call_one_comma, .call, .call_comma => true,
            else => false,
        };
    }

    /// Checks `call(...) catch unreachable` when the call prints into a
    /// buffer.
    fn call(r: *Rule, catch_node: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        const call_node = tree.nodeData(catch_node).node_and_node[0];
        var buffer: [1]Node.Index = undefined;
        const full = tree.fullCall(&buffer, call_node).?;
        const sentinel = r.printCallee(full.ast.fn_expr) orelse return;
        const params = full.ast.params;
        if (params.len < 3) return;
        const length = r.bufferLength(params[0]) orelse return;
        const capacity = if (sentinel) length -| 1 else length;
        if (tree.nodeTag(params[1]) != .string_literal) return;
        const format = std.zig.string_literal.parseAlloc(r.arena, tree.tokenSlice(tree.nodeMainToken(params[1]))) catch return;
        var init_buffer: [2]Node.Index = undefined;
        const args = (tree.fullArrayInit(&init_buffer, params[2]) orelse return).ast.elements;

        var it: Placeholders = .{ .format = format };
        while (it.next()) |placeholder| {
            const index = placeholder.argument orelse return;
            if (index >= args.len or !placeholder.decimal) continue;
            const arg = args[index];
            const float = r.floatOf(arg, placeholder.optional) orelse continue;
            const need = float.worst(placeholder.precision, placeholder.width);
            if (need <= capacity) continue;
            if (try r.bounded(arg, call_node)) continue;
            return r.findings.append(r.arena, .{
                .offset = tree.tokenStart(tree.firstToken(arg)),
                .hint = try r.arena.print("print it with {{e}}, which needs at most {d} bytes, make the buffer {d}, or handle error.NoSpaceLeft (return it, or `catch \"?\"`)", .{ float.scientific(), need }),
                .detail = .{ .fit = .{
                    .callee = tree.getNodeSource(full.ast.fn_expr),
                    .placeholder = placeholder.text,
                    .float = @tagName(float),
                    .value = tree.getNodeSource(arg),
                    .need = need,
                    .buffer = tree.getNodeSource(params[0]),
                    .capacity = capacity,
                } },
            });
        }
    }

    /// Whether `callee` prints into a buffer: `std.mem`'s print and
    /// printSentinel, named through their namespace (`std.mem.print`,
    /// `mem.print`), or `std.fmt`'s bufPrint and bufPrintSentinel, which
    /// 0.17.0 keeps for them, named the same way or alone in a file that
    /// declares no function of that name. True for the sentinel forms,
    /// whose sentinel takes a byte; null for anything else.
    fn printCallee(r: *const Rule, callee: Node.Index) ?bool {
        const tree = r.tree;
        switch (tree.nodeTag(callee)) {
            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(callee));
                if (r.types.declaredFn(callee, name) != null) return null;
                return sentinelOf(name, "bufPrint");
            },
            .field_access => {
                const receiver, const field = tree.nodeData(callee).node_and_token;
                const namespace = switch (tree.nodeTag(receiver)) {
                    .identifier => tree.tokenSlice(tree.nodeMainToken(receiver)),
                    .field_access => tree.tokenSlice(tree.nodeData(receiver).node_and_token[1]),
                    else => return null,
                };
                const name = tree.tokenSlice(field);
                if (std.mem.eql(u8, namespace, "mem")) return sentinelOf(name, "print");
                if (std.mem.eql(u8, namespace, "fmt")) return sentinelOf(name, "bufPrint");
                return null;
            },
            else => return null,
        }
    }

    /// How many bytes `node`, bufPrint's buffer, holds, when the file
    /// writes it: `&buf` or `buf[0..]` with `buf: [N]u8`, or `buf` with
    /// `buf: *[N]u8`.
    fn bufferLength(r: *Rule, node: Node.Index) ?u64 {
        const tree = r.tree;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return r.bufferLength(tree.nodeData(node).node_and_token[0]),
            .address_of => return r.arrayLength(r.types.typeOf(tree.nodeData(node).node, 0) orelse return null),
            .slice_open => {
                const slice = tree.fullSlice(node).?;
                if (!std.mem.eql(u8, tree.getNodeSource(slice.ast.start), "0")) return null;
                const sliced = r.types.typeOf(slice.ast.sliced, 0) orelse return null;
                return r.arrayLength(types.pointee(tree, sliced) orelse sliced);
            },
            else => return r.arrayLength(types.pointee(tree, r.types.typeOf(node, 0) orelse return null) orelse return null),
        }
    }

    /// N of `[N]u8` or `[N:0]u8`, when N is an integer literal, a
    /// container-level constant the file sets to one, or
    /// `std.fmt.float.min_buffer_size`.
    fn arrayLength(r: *Rule, type_expr: Node.Index) ?u64 {
        const tree = r.tree;
        const array = tree.fullArrayType(type_expr) orelse return null;
        if (!std.mem.eql(u8, tree.getNodeSource(array.ast.elem_type), "u8")) return null;
        return r.integer(array.ast.elem_count, 0);
    }

    fn integer(r: *Rule, node: Node.Index, depth: u8) ?u64 {
        const tree = r.tree;
        if (depth > 4) return null;
        switch (tree.nodeTag(node)) {
            .number_literal => return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
                .int => |n| n,
                else => null,
            },
            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                var around = r.types.enclosingContainer(node);
                while (around) |container| : (around = r.types.enclosingContainer(container)) {
                    const decl = types.memberDecl(tree, container, name) orelse continue;
                    const var_decl = tree.fullVarDecl(decl).?;
                    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return null;
                    return r.integer(var_decl.ast.init_node.unwrap() orelse return null, depth + 1);
                }
                return null;
            },
            // The one std constant a float's buffer is often sized by, and
            // too small for an f64 printed in full.
            .field_access => return if (std.mem.eql(u8, tree.getNodeSource(node), "std.fmt.float.min_buffer_size")) 53 else null,
            else => return null,
        }
    }

    /// The float type of `node` as the file writes it, unwrapped from an
    /// optional for `{?d}`.
    fn floatOf(r: *Rule, node: Node.Index, optional: bool) ?Float {
        const tree = r.tree;
        var type_expr = r.types.typeOf(node, 0) orelse return null;
        if (optional) {
            if (tree.nodeTag(type_expr) != .optional_type) return null;
            type_expr = tree.nodeData(type_expr).node;
        }
        if (tree.nodeTag(type_expr) != .identifier) return null;
        return std.meta.stringToEnum(Float, tree.tokenSlice(tree.nodeMainToken(type_expr)));
    }

    /// Whether `arg` is bounded before `call_node` prints it, in the
    /// function around it: a constant whose value is a literal, made from
    /// an integer or clamped, or compared or clamped itself, directly or
    /// through a local made from it.
    fn bounded(r: *Rule, arg: Node.Index, call_node: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        const text = tree.getNodeSource(arg);
        var scope = call_node;
        while (r.types.parents[@backingInt(scope)].unwrap()) |parent| {
            scope = parent;
            if (tree.nodeTag(scope) == .fn_decl or tree.nodeTag(scope) == .test_decl) break;
        }
        const before = tree.firstToken(call_node);

        // The names the value goes by: its own, and the locals made from it.
        var names: std.ArrayList([]const u8) = .empty;
        try names.append(r.arena, text);
        var nodes: std.ArrayList(Node.Index) = .empty;
        try descendants(r.arena, tree, scope, &nodes);
        for (nodes.items) |node| {
            if (tree.firstToken(node) >= before) continue;
            const decl = tree.fullVarDecl(node) orelse continue;
            const init = decl.ast.init_node.unwrap() orelse continue;
            const name = tree.tokenSlice(decl.ast.mut_token + 1);
            if (std.mem.eql(u8, name, text)) {
                if (isLiteral(tree, init) or try holdsCall(r.arena, tree, init, &.{ "@floatFromInt", "@min", "@max", "clamp" })) return true;
            } else if (try mentions(r.arena, tree, init, text)) {
                try names.append(r.arena, name);
            }
        }
        for (nodes.items) |node| {
            if (tree.firstToken(node) >= before) continue;
            const bound = switch (tree.nodeTag(node)) {
                .less_than, .greater_than, .less_or_equal, .greater_or_equal => true,
                else => callsOneOf(tree, node, &.{ "@min", "@max", "clamp" }),
            };
            if (!bound) continue;
            for (names.items) |name| if (try mentions(r.arena, tree, node, name)) return true;
        }
        return false;
    }
};

/// False when `name` is `base`, true when it is `base` with `Sentinel`
/// after it, and null otherwise.
fn sentinelOf(name: []const u8, base: []const u8) ?bool {
    const rest = std.mem.cutPrefix(u8, name, base) orelse return null;
    if (rest.len == 0) return false;
    if (std.mem.eql(u8, rest, "Sentinel")) return true;
    return null;
}

/// The float types whose longest printed form is known.
const Float = enum {
    f16,
    f32,
    f64,

    /// The most bytes `{d}` can print a value of this type in: the sign
    /// and digits of the largest, then a point and `precision` digits, or
    /// with no precision the smallest subnormal's shortest form, the
    /// longest of all. At least `width`.
    fn worst(float: Float, precision: ?Precision, width: u64) u64 {
        const whole: u64, const full: u64 = switch (float) {
            .f16 => .{ 6, 11 },
            .f32 => .{ 40, 48 },
            .f64 => .{ 310, 327 },
        };
        const p = precision orelse return @max(full, width);
        const need = switch (p) {
            // A precision given at run time is at least 0.
            .unknown => whole,
            .digits => |n| if (n == 0) whole else whole + 1 + n,
        };
        return @max(need, width);
    }

    /// The most bytes `{e}` can print a value of this type in.
    fn scientific(float: Float) u64 {
        return switch (float) {
            .f16 => 9,
            .f32 => 14,
            .f64 => 24,
        };
    }
};

const Precision = union(enum) { digits: u64, unknown };

/// The replacement fields of a format string, in order, with the argument
/// each prints: `{d}`, `{0d:>8.2}`, `{[name]d}` and so on.
const Placeholders = struct {
    format: []const u8,
    at: usize = 0,
    next_argument: usize = 0,

    const Placeholder = struct {
        /// As written, braces included.
        text: []const u8,
        /// Which argument it prints; null when it is named.
        argument: ?usize,
        /// Printed in decimal if a float: `{}`, `{d}` or `{any}`.
        decimal: bool,
        /// `{?d}`: the argument is optional.
        optional: bool,
        width: u64,
        precision: ?Precision,
    };

    fn next(it: *Placeholders) ?Placeholder {
        const format = it.format;
        while (it.at < format.len) {
            const c = format[it.at];
            if (c != '{') {
                it.at += 1;
                continue;
            }
            if (it.at + 1 < format.len and format[it.at + 1] == '{') {
                it.at += 2;
                continue;
            }
            const close = std.mem.findScalarPos(u8, format, it.at, '}') orelse return null;
            const text = format[it.at .. close + 1];
            it.at = close + 1;
            return it.parse(text);
        }
        return null;
    }

    fn parse(it: *Placeholders, text: []const u8) Placeholder {
        var inner = text[1 .. text.len - 1];
        var placeholder: Placeholder = .{ .text = text, .argument = null, .decimal = false, .optional = false, .width = 0, .precision = null };
        // The argument: `[name]`, a position, or the next one.
        if (inner.len > 0 and inner[0] == '[') {
            inner = inner[(std.mem.findScalar(u8, inner, ']') orelse inner.len - 1) + 1 ..];
        } else {
            var digits: usize = 0;
            while (digits < inner.len and std.ascii.isDigit(inner[digits])) digits += 1;
            if (digits > 0) {
                placeholder.argument = std.fmt.parseInt(usize, inner[0..digits], 10) catch null;
                inner = inner[digits..];
            } else {
                placeholder.argument = it.next_argument;
                it.next_argument += 1;
            }
        }
        const colon = std.mem.findScalar(u8, inner, ':') orelse inner.len;
        var specifier = inner[0..colon];
        if (std.mem.startsWith(u8, specifier, "?")) {
            placeholder.optional = true;
            specifier = specifier[1..];
        }
        placeholder.decimal = specifier.len == 0 or std.mem.eql(u8, specifier, "d") or std.mem.eql(u8, specifier, "any");
        if (colon == inner.len) return placeholder;

        // The options: fill and alignment, width, precision.
        var options = inner[colon + 1 ..];
        if (options.len >= 2 and std.mem.findScalar(u8, "<^>", options[1]) != null) {
            options = options[2..];
        } else if (options.len >= 1 and std.mem.findScalar(u8, "<^>", options[0]) != null) {
            options = options[1..];
        }
        var digits: usize = 0;
        while (digits < options.len and std.ascii.isDigit(options[digits])) digits += 1;
        placeholder.width = std.fmt.parseInt(u64, options[0..digits], 10) catch 0;
        options = options[digits..];
        if (std.mem.startsWith(u8, options, "[")) options = options[(std.mem.findScalar(u8, options, ']') orelse options.len - 1) + 1 ..];
        if (std.mem.startsWith(u8, options, ".")) {
            const precision = options[1..];
            placeholder.precision = if (std.fmt.parseInt(u64, precision, 10)) |n| .{ .digits = n } else |_| .unknown;
        }
        return placeholder;
    }
};

/// Appends every node under `node`, not counting `node` itself.
fn descendants(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    const start = out.items.len;
    try children.append(arena, tree, node, out);
    const end = out.items.len;
    for (start..end) |i| try descendants(arena, tree, out.items[i], out);
}

/// Whether `node` is a number literal, negated or not.
fn isLiteral(tree: *const Ast, node: Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .number_literal => true,
        .negation => isLiteral(tree, tree.nodeData(node).node),
        .grouped_expression => isLiteral(tree, tree.nodeData(node).node_and_token[0]),
        else => false,
    };
}

/// Whether `node` holds, anywhere in it, a call to one of `names`.
fn holdsCall(arena: Allocator, tree: *const Ast, node: Node.Index, names: []const []const u8) Allocator.Error!bool {
    if (callsOneOf(tree, node, names)) return true;
    var nodes: std.ArrayList(Node.Index) = .empty;
    try descendants(arena, tree, node, &nodes);
    for (nodes.items) |n| if (callsOneOf(tree, n, names)) return true;
    return false;
}

/// Whether `node` is a call to one of `names`: a builtin (`@min`) or a
/// function by its last name (`clamp`, `std.math.clamp`).
fn callsOneOf(tree: *const Ast, node: Node.Index, names: []const []const u8) bool {
    const name = switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => tree.tokenSlice(tree.nodeMainToken(node)),
        .call_one, .call_one_comma, .call, .call_comma => name: {
            var buffer: [1]Node.Index = undefined;
            const callee = tree.fullCall(&buffer, node).?.ast.fn_expr;
            break :name switch (tree.nodeTag(callee)) {
                .identifier => tree.tokenSlice(tree.nodeMainToken(callee)),
                .field_access => tree.tokenSlice(tree.nodeData(callee).node_and_token[1]),
                else => "",
            };
        },
        else => "",
    };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Whether `node` is, or holds, the expression written `text`: a name
/// (`v`) or a field reached from one (`params.percent`).
fn mentions(arena: Allocator, tree: *const Ast, node: Node.Index, text: []const u8) Allocator.Error!bool {
    switch (tree.nodeTag(node)) {
        .identifier, .field_access => if (std.mem.eql(u8, tree.getNodeSource(node), text)) return true,
        else => {},
    }
    var nodes: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, node, &nodes);
    for (nodes.items) |child| if (try mentions(arena, tree, child, text)) return true;
    return false;
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col placeholder of float value: need > capacity`, in source order.
fn expectFits(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var findings: std.ArrayList(Finding) = .empty;
    try check(arena_state.allocator(), &tree, &findings);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (findings.items) |finding| {
        const loc = report.location(tree.source, finding.offset);
        const f = finding.detail.fit;
        try out.writer.print("{d}:{d} {s} of {s} {s}: {d} > {d}\n", .{ loc.line + 1, loc.column + 1, f.placeholder, f.float, f.value, f.need, f.capacity });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a float printed in full into a buffer too small for it (#35)" {
    try expectFits(
        \\const std = @import("std");
        \\const len = 32;
        \\const Params = struct { percent: f64 };
        \\const Cell = union(enum) { number: f64, text: []const u8 };
        \\const Gauge = struct { value: f32, buf: [16]u8 };
        \\fn param(v: f64) usize { var buf: [48]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\fn precision(p: Params) usize { var buf: [48]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d:.2}", .{p.percent}) catch unreachable).len; }
        \\fn prong(c: Cell) usize { switch (c) { .number => |v| { var buf: [32]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }, .text => |t| return t.len } }
        \\fn loop(vs: []const f64) usize { var n: usize = 0; for (vs) |v| { var buf: [len]u8 = undefined; n += (std.fmt.bufPrint(&buf, "{}", .{v}) catch unreachable).len; } return n; }
        \\fn floor(v: f64) usize { var buf: [std.fmt.float.min_buffer_size]u8 = undefined; return (std.fmt.bufPrint(&buf, "{any}", .{v}) catch unreachable).len; }
        \\fn field(g: *Gauge) usize { return (std.fmt.bufPrint(&g.buf, "{d}", .{g.value}) catch unreachable).len; }
        \\fn second(s: []const u8, v: f32) usize { var buf: [40]u8 = undefined; return (std.fmt.bufPrint(&buf, "{s}={d}", .{ s, v }) catch unreachable).len; }
        \\fn optional(v: ?f64) usize { var buf: [64]u8 = undefined; return (std.fmt.bufPrint(&buf, "{?d}", .{v}) catch unreachable).len; }
        \\fn sentinel(v: f16) usize { var buf: [11]u8 = undefined; return (std.fmt.bufPrintSentinel(&buf, "{d}", .{v}, 0) catch unreachable).len; }
        \\fn width(buf: *[20]u8, v: f16) usize { return (std.fmt.bufPrint(buf, "{d:>30}", .{v}) catch unreachable).len; }
        \\fn mem(v: f64) usize { var buf: [32]u8 = undefined; return (std.mem.print(&buf, "{d}", .{v}) catch unreachable).len; }
        \\fn memSentinel(v: f32) usize { var buf: [48]u8 = undefined; return (std.mem.printSentinel(&buf, "{d}", .{v}, 0) catch unreachable).len; }
    ,
        \\6:95 {d} of f64 v: 327 > 48
        \\7:105 {d:.2} of f64 p.percent: 313 > 48
        \\8:126 {d} of f64 v: 327 > 32
        \\9:134 {} of f64 v: 327 > 32
        \\10:124 {any} of f64 v: 327 > 53
        \\11:71 {d} of f32 g.value: 48 > 16
        \\12:119 {d} of f32 v: 48 > 40
        \\13:100 {?d} of f64 v: 327 > 64
        \\14:106 {d} of f16 v: 11 > 10
        \\15:83 {d:>30} of f16 v: 30 > 20
        \\16:90 {d} of f64 v: 327 > 32
        \\17:106 {d} of f32 v: 48 > 47
        \\
    );
}

test "bounded, big enough, handled, or not a float the file types: not reported" {
    try expectFits(
        \\const std = @import("std");
        \\fn big(v: f64) usize { var buf: [327]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\fn sci(v: f64) usize { var buf: [24]u8 = undefined; return (std.fmt.bufPrint(&buf, "{e}", .{v}) catch unreachable).len; }
        \\fn handled(v: f64) usize { var buf: [48]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?").len; }
        \\fn returned(v: f64) !usize { var buf: [48]u8 = undefined; return (try std.fmt.bufPrint(&buf, "{d}", .{v})).len; }
        \\fn integer(n: u64) usize { var buf: [20]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable).len; }
        \\fn compared(x: f64) usize { var buf: [64]u8 = undefined; const size = @abs(x); if (size >= 1e21) return 0; return (std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable).len; }
        \\fn clamped(v: f64) usize { const c: f64 = std.math.clamp(v, -1e9, 1e9); var buf: [32]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d:.2}", .{c}) catch unreachable).len; }
        \\fn fromInt(n: u32) usize { const v: f64 = @floatFromInt(n); var buf: [32]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\fn literal() usize { const v: f64 = 1.5; var buf: [8]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\fn untyped(v: anytype) usize { var buf: [32]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\fn slice(buf: []u8, v: f64) usize { return (std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable).len; }
        \\fn named(v: f64) usize { var buf: [32]u8 = undefined; return (std.fmt.bufPrint(&buf, "{[v]d}", .{ .v = v }) catch unreachable).len; }
        \\fn wide(v: f80) usize { var buf: [32]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\fn bufPrint(buf: []u8, comptime f: []const u8, args: anytype) ![]u8 { _ = f; _ = args; return buf; }
        \\fn own(v: f64) usize { var buf: [8]u8 = undefined; return (bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\fn writer(w: *std.Io.Writer, v: f64) void { w.print("{d}", .{v}) catch unreachable; }
        \\fn debug(v: f64) void { std.debug.print("{d}", .{v}); }
    , "");
}

test "placeholders: arguments, specifiers and options" {
    var it: Placeholders = .{ .format = "a {{b}} {d} {s:>8} {1d:.3} {[n]d} {?d:0<12.[p]}" };
    const want = [_]Placeholders.Placeholder{
        .{ .text = "{d}", .argument = 0, .decimal = true, .optional = false, .width = 0, .precision = null },
        .{ .text = "{s:>8}", .argument = 1, .decimal = false, .optional = false, .width = 8, .precision = null },
        .{ .text = "{1d:.3}", .argument = 1, .decimal = true, .optional = false, .width = 0, .precision = .{ .digits = 3 } },
        .{ .text = "{[n]d}", .argument = null, .decimal = true, .optional = false, .width = 0, .precision = null },
        .{ .text = "{?d:0<12.[p]}", .argument = 2, .decimal = true, .optional = true, .width = 12, .precision = .unknown },
    };
    for (want) |w| try std.testing.expectEqualDeep(w, it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "Float.worst and Float.scientific are the most std.fmt prints" {
    const m = std.math;
    inline for (.{ f16, f32, f64 }, .{ Float.f16, Float.f32, Float.f64 }) |T, float| {
        var buf: [400]u8 = undefined;
        var full: usize = 0;
        var whole: usize = 0;
        var two: usize = 0;
        var scientific: usize = 0;
        for ([_]T{ m.floatMax(T), -m.floatMax(T), -m.floatMax(T) / 3, m.floatTrueMin(T), -m.floatTrueMin(T), -m.floatTrueMin(T) * 3, -m.floatMin(T) }) |v| {
            full = @max(full, (try std.fmt.bufPrint(&buf, "{d}", .{v})).len);
            whole = @max(whole, (try std.fmt.bufPrint(&buf, "{d:.0}", .{v})).len);
            two = @max(two, (try std.fmt.bufPrint(&buf, "{d:.2}", .{v})).len);
            scientific = @max(scientific, (try std.fmt.bufPrint(&buf, "{e}", .{v})).len);
        }
        try std.testing.expectEqual(full, float.worst(null, 0));
        try std.testing.expectEqual(whole, float.worst(.{ .digits = 0 }, 0));
        try std.testing.expectEqual(two, float.worst(.{ .digits = 2 }, 0));
        try std.testing.expectEqual(scientific, float.scientific());
    }
}
