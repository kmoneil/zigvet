//! Rule four, fit: a number printed in decimal by `std.mem.print` or
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
//! because it is one for the integers most code prints: a u64 is at most
//! 20 digits. But a u128 is 39 and an i128 40, and generic code that takes
//! its integer from the caller does not know which it gets.
//!
//! Everything is read from the syntax: the format string, the buffer's
//! length (`var buf: [48]u8`, a container-level constant, or
//! `std.fmt.float.min_buffer_size`), and the value's type as the file
//! writes it: a parameter, local, capture or container-level variable
//! declared `f16`, `f32`, `f64` or an integer type (`u128`, `i32`,
//! `usize`, taken as 64 bits), or such a field of a struct the file
//! declares. f80 and f128 are not looked at.
//!
//! A value whose type the caller picks is taken to be as long as an i128,
//! the widest integer in common use: an anytype parameter, or a field of
//! one, what an `if`, `while`, `for` or `switch` captures from one, or a
//! local made from one with no type written. Its callers pick its type
//! when the function is pub, is named other than to call it, or is passed
//! there, by a call in the file, a value whose type that call's own caller
//! picks; a private function whose every call passes a type the file
//! decides is not looked at. A value of any other type the
//! file does not write (an untyped local, a type from another file, a
//! `comptime T: type` parameter's) is not looked at either.
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
const expect = @import("expect.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");
const Types = types.Types;

/// Appends a finding for every number that can overflow the buffer a
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
            const number = r.numberOf(arg, placeholder.optional) orelse continue;
            const need = number.worst(placeholder);
            if (need <= capacity) continue;
            if (try r.bounded(arg, call_node)) continue;
            const handle = "handle error.NoSpaceLeft (return it, or `catch \"?\"`)";
            return r.findings.append(r.arena, .{
                .offset = tree.tokenStart(tree.firstToken(arg)),
                .hint = switch (number) {
                    .float => |float| try r.arena.print("print it with {{e}}, which needs at most {d} bytes, make the buffer {d}, or " ++ handle, .{ float.scientific(), need }),
                    .int => try r.arena.print("make the buffer {d}, or " ++ handle, .{need}),
                    .chosen => try r.arena.print("make the buffer {d} and check at comptime that its type is an integer of at most 128 bits, or " ++ handle, .{need}),
                },
                .detail = .{ .fit = .{
                    .callee = tree.getNodeSource(full.ast.fn_expr),
                    .placeholder = placeholder.text,
                    .number = switch (number) {
                        .float => |float| @tagName(float),
                        .int => |int| int.name,
                        .chosen => null,
                    },
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

    /// What `node` prints as: a float or integer type as the file writes
    /// it, unwrapped from an optional for `{?d}`, or with no type written,
    /// the caller's choice when `chosen` says it is.
    fn numberOf(r: *Rule, node: Node.Index, optional: bool) ?Number {
        const tree = r.tree;
        var type_expr = r.types.typeOf(node, 0) orelse return if (r.chosen(node, 0)) .chosen else null;
        if (optional) {
            if (tree.nodeTag(type_expr) != .optional_type) return null;
            type_expr = tree.nodeData(type_expr).node;
        }
        if (tree.nodeTag(type_expr) != .identifier) return null;
        const name = tree.tokenSlice(tree.nodeMainToken(type_expr));
        if (std.meta.stringToEnum(Float, name)) |float| return .{ .float = float };
        return .{ .int = Int.parse(name) orelse return null };
    }

    /// Whether the type of `node` is the caller's choice: an anytype
    /// parameter whose callers pick its type, or what is reached from one,
    /// by a field (`user.id`, `args.@"0"`), by what an `if`, `while`, `for`
    /// or `switch` captures from it (`if (ctx.user) |u|`), or by a local
    /// made from it with no type written (`const id = user.id;`). Found by
    /// walking out from it, as Zig allows no shadowing.
    fn chosen(r: *const Rule, node: Node.Index, depth: u8) bool {
        const tree = r.tree;
        if (depth > 8) return false;
        var root = node;
        while (tree.nodeTag(root) != .identifier) switch (tree.nodeTag(root)) {
            .field_access, .grouped_expression, .unwrap_optional => root = tree.nodeData(root).node_and_token[0],
            .deref, .address_of => root = tree.nodeData(root).node,
            else => return false,
        };
        const name = tree.tokenSlice(tree.nodeMainToken(root));
        var child = root;
        var up = r.types.parents[@backingInt(root)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = r.types.parents[@backingInt(parent)].unwrap();
        }) {
            switch (tree.nodeTag(parent)) {
                .fn_decl => {
                    var buffer: [1]Node.Index = undefined;
                    var params = tree.fullFnProto(&buffer, tree.nodeData(parent).node_and_node[0]).?.iterate(tree);
                    var index: usize = 0;
                    while (params.next()) |param| : (index += 1) {
                        const name_token = param.name_token orelse continue;
                        if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;
                        // `anytype`: `...` has no name.
                        if (param.anytype_ellipsis3 == null) return false;
                        return r.callerPicks(parent, index, depth + 1);
                    }
                    return false;
                },
                .test_decl => return false,
                .if_simple, .@"if" => {
                    const full = tree.fullIf(parent).?;
                    if (child != full.ast.then_expr) continue;
                    if (types.captureIndex(tree, full.payload_token orelse continue, name) != 0) continue;
                    return r.chosen(full.ast.cond_expr, depth + 1);
                },
                .while_simple, .while_cont, .@"while" => {
                    const full = tree.fullWhile(parent).?;
                    if (child != full.ast.then_expr) continue;
                    if (types.captureIndex(tree, full.payload_token orelse continue, name) != 0) continue;
                    return r.chosen(full.ast.cond_expr, depth + 1);
                },
                .for_simple, .@"for" => {
                    const full = tree.fullFor(parent).?;
                    if (child != full.ast.then_expr) continue;
                    const index = types.captureIndex(tree, full.payload_token, name) orelse continue;
                    if (index >= full.ast.inputs.len) return false;
                    return r.chosen(full.ast.inputs[index], depth + 1);
                },
                .switch_case_one, .switch_case => {
                    const case = tree.fullSwitchCase(parent).?;
                    if (types.captureIndex(tree, case.payload_token orelse continue, name) != 0) continue;
                    const switch_node = r.types.parents[@backingInt(parent)].unwrap() orelse return false;
                    return r.chosen(tree.fullSwitch(switch_node).?.ast.condition, depth + 1);
                },
                else => {},
            }
            // A local declared before it, in a block around it.
            var buffer: [2]Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, parent) orelse continue;
            for (statements) |statement| {
                if (statement == child) break;
                const decl = tree.fullVarDecl(statement) orelse continue;
                if (!std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)) continue;
                if (decl.ast.type_node != .none) return false;
                return r.chosen(decl.ast.init_node.unwrap() orelse return false, depth + 1);
            }
        }
        return false;
    }

    /// Whether the callers of `fn_decl` pick the type of its parameter
    /// `index`: it is pub, or used other than by a call, or a call to it
    /// in the file passes there a value whose type is that caller's
    /// choice. A private function every call to which passes a type the
    /// file decides prints only what the file decides.
    fn callerPicks(r: *const Rule, fn_decl: Node.Index, index: usize, depth: u8) bool {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
        if (proto.visib_token != null) return true;
        const name = tree.tokenSlice(proto.name_token orelse return true);
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @fromBackingInt(@intCast(i));
            const named = switch (tree.nodeTag(node)) {
                .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
                .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
                else => continue,
            };
            if (!std.mem.eql(u8, named, name)) continue;
            var call_buffer: [1]Node.Index = undefined;
            const parent = r.types.parents[@backingInt(node)].unwrap() orelse continue;
            const full = tree.fullCall(&call_buffer, parent);
            if (full == null or full.?.ast.fn_expr != node) {
                // Named other than to call it: as a value, by name, which
                // no local can shadow. `x.name` can be anything of that
                // name.
                if (tree.nodeTag(node) == .identifier and r.types.declaredFn(node, name) == fn_decl) return true;
                continue;
            }
            const called, const offset = r.types.callee(node) orelse continue;
            if (called != fn_decl or index < offset) continue;
            const args = full.?.ast.params;
            if (index - offset < args.len and r.chosen(args[index - offset], depth)) return true;
        }
        return false;
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

/// What a decimal placeholder prints, as far as how long it can be.
const Number = union(enum) {
    float: Float,
    int: Int,
    /// A value whose type the caller picks, through an anytype parameter.
    /// Taken as the longest i128, 40 bytes: the widest integer in common
    /// use, which a buffer sized for an i64 cannot hold.
    chosen,

    /// The most bytes `placeholder` can print it in.
    fn worst(number: Number, placeholder: Placeholders.Placeholder) u64 {
        return switch (number) {
            .float => |float| float.worst(placeholder.precision, placeholder.width),
            // An optional's null prints as `null`.
            .int => |int| @max(int.longest(), placeholder.width, @as(u64, if (placeholder.optional) 4 else 0)),
            .chosen => @max(40, placeholder.width),
        };
    }
};

/// An integer type as the file writes it: `u128`, `i32`, `usize`.
const Int = struct {
    name: []const u8,
    bits: u16,
    signed: bool,

    fn parse(name: []const u8) ?Int {
        // The widest a usize or isize is on any target Zig builds for.
        if (std.mem.eql(u8, name, "usize")) return .{ .name = name, .bits = 64, .signed = false };
        if (std.mem.eql(u8, name, "isize")) return .{ .name = name, .bits = 64, .signed = true };
        if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return null;
        // `u08` is not a type: Zig refuses the leading zero.
        if (name[1] == '0' and name.len > 2) return null;
        for (name[1..]) |c| if (!std.ascii.isDigit(c)) return null;
        const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
        const signed = name[0] == 'i';
        if (signed and bits == 0) return null;
        return .{ .name = name, .bits = bits, .signed = signed };
    }

    /// The most bytes `{d}` prints a value of it in: the digits of its
    /// largest magnitude, 2^k - 1 unsigned or 2^k signed, and a sign for a
    /// signed one. 2^k - 1 has as many digits as 2^k, since no power of two
    /// above 1 is a power of ten.
    fn longest(int: Int) u64 {
        if (int.bits == 0) return 1;
        const k: f64 = @floatFromInt(if (int.signed) int.bits - 1 else int.bits);
        const digits: u64 = @intFromFloat(@floor(k * @log10(2.0)) + 1);
        return digits + @intFromBool(int.signed);
    }
};

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
/// `line:col placeholder of type value: need > capacity`, in source order,
/// with `anytype` for a type the caller picks.
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
        try out.writer.print("{d}:{d} {s} of {s} {s}: {d} > {d}\n", .{ loc.line + 1, loc.column + 1, f.placeholder, f.number orelse "anytype", f.value, f.need, f.capacity });
    }
    try expect.findings(@src(), expected, out.written());
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
        \\fn slice(buf: []u8, v: f64) usize { return (std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable).len; }
        \\fn named(v: f64) usize { var buf: [32]u8 = undefined; return (std.fmt.bufPrint(&buf, "{[v]d}", .{ .v = v }) catch unreachable).len; }
        \\fn wide(v: f80) usize { var buf: [32]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\fn bufPrint(buf: []u8, comptime f: []const u8, args: anytype) ![]u8 { _ = f; _ = args; return buf; }
        \\fn own(v: f64) usize { var buf: [8]u8 = undefined; return (bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\fn writer(w: *std.Io.Writer, v: f64) void { w.print("{d}", .{v}) catch unreachable; }
        \\fn debug(v: f64) void { std.debug.print("{d}", .{v}); }
    , "");
}

test "an integer wider than the buffer, or of a type the caller picks (#128)" {
    try expectFits(
        \\const std = @import("std");
        \\const User = struct { id: u128 };
        \\pub fn key(user: anytype, buf: *[24]u8) []const u8 { return std.fmt.bufPrint(buf, "u{d}", .{user.id}) catch unreachable; }
        \\pub fn whole(v: anytype) usize { var buf: [32]u8 = undefined; return (std.fmt.bufPrint(&buf, "{}", .{v}) catch unreachable).len; }
        \\pub fn tuple(args: anytype) usize { var buf: [16]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{args.@"0"}) catch unreachable).len; }
        \\pub fn chosenWidth(v: anytype) usize { var buf: [48]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d:>50}", .{v}) catch unreachable).len; }
        \\pub fn current(ctx: anytype) usize { if (ctx.user) |u| { var buf: [24]u8 = undefined; return (std.fmt.bufPrint(&buf, "u{d}", .{u.id}) catch unreachable).len; } return 0; }
        \\pub fn each(ids: anytype) void { for (ids) |id| { var buf: [24]u8 = undefined; _ = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable; } }
        \\pub fn untypedLocal(user: anytype) usize { const id = user.id; var buf: [8]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable).len; }
        \\pub fn call(ctx: anytype) usize { var buf: [24]u8 = undefined; return keyOf(ctx.*, &buf).len; }
        \\fn keyOf(ctx: anytype, buf: *[24]u8) []const u8 { return std.fmt.bufPrint(buf, "u{d}", .{ctx.id}) catch unreachable; }
        \\pub const show = shown;
        \\fn shown(v: anytype) usize { var buf: [24]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\const Box = struct { fn put(b: *Box, v: anytype) usize { _ = b; var buf: [24]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; } pub fn putAll(b: *Box, x: anytype) usize { return b.put(x); } };
        \\fn wide(id: u128) usize { var buf: [24]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable).len; }
        \\fn signed(n: i64) usize { var buf: [19]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable).len; }
        \\fn size(n: usize) usize { var buf: [16]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable).len; }
        \\fn field(u: User) usize { var buf: [32]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{u.id}) catch unreachable).len; }
        \\fn optional(n: ?u8) usize { var buf: [3]u8 = undefined; return (std.fmt.bufPrint(&buf, "{?d}", .{n}) catch unreachable).len; }
        \\fn padded(n: u8) usize { var buf: [4]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d:>8}", .{n}) catch unreachable).len; }
        \\fn huge(n: u256) usize { var buf: [64]u8 = undefined; return (std.mem.print(&buf, "{d}", .{n}) catch unreachable).len; }
    ,
        \\3:93 {d} of anytype user.id: 40 > 24
        \\4:102 {} of anytype v: 40 > 32
        \\5:106 {d} of anytype args.@"0": 40 > 16
        \\6:113 {d:>50} of anytype v: 50 > 48
        \\7:128 {d} of anytype u.id: 40 > 24
        \\8:116 {d} of anytype id: 40 > 24
        \\9:132 {d} of anytype id: 40 > 8
        \\11:90 {d} of anytype ctx.id: 40 > 24
        \\13:99 {d} of anytype v: 40 > 24
        \\14:134 {d} of anytype v: 40 > 24
        \\15:96 {d} of u128 id: 39 > 24
        \\16:96 {d} of i64 n: 20 > 19
        \\17:96 {d} of usize n: 20 > 16
        \\18:96 {d} of u128 u.id: 39 > 32
        \\19:98 {?d} of u8 n: 4 > 3
        \\20:97 {d:>8} of u8 n: 8 > 4
        \\21:92 {d} of u256 n: 78 > 64
        \\
    );
}

test "an integer that fits, bounded, or of a type neither the file nor the caller picks: not reported" {
    try expectFits(
        \\const std = @import("std");
        \\fn fits(id: u128) usize { var buf: [39]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable).len; }
        \\fn small(n: u32) usize { var buf: [10]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable).len; }
        \\pub fn roomy(user: anytype) usize { var buf: [40]u8 = undefined; return (std.fmt.bufPrint(&buf, "u{d}", .{user.id}) catch unreachable).len - 1; }
        \\fn compared(n: u64) usize { if (n > 9999) return 0; var buf: [4]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable).len; }
        \\pub fn hex(user: anytype) usize { var buf: [24]u8 = undefined; return (std.fmt.bufPrint(&buf, "{x}", .{user.id}) catch unreachable).len; }
        \\pub fn handled(user: anytype) usize { var buf: [24]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{user.id}) catch "?").len; }
        \\pub fn generic(comptime T: type, v: T) usize { var buf: [8]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\const other = @import("other.zig");
        \\pub fn typedLocal(ctx: anytype) usize { const u: other.User = ctx.user; var buf: [8]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{u.id}) catch unreachable).len; }
        \\pub fn imported(u: other.User) usize { var buf: [8]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{u.id}) catch unreachable).len; }
        \\fn notAnInt(v: u8x) usize { var buf: [1]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
        \\const u8x = u16;
        \\fn writeInt(n: anytype) usize { var buf: [24]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable).len; }
        \\pub fn writeCount(count: u64) usize { return writeInt(count); }
        \\pub fn writeEach(v: ?i64, ns: []const u32) usize { var total: usize = 0; for (ns) |n| total += writeInt(n); if (v) |n| total += writeInt(n); return total; }
        \\pub fn writeSelf(ctx: anytype) usize { return ctx.writeInt(ctx.big); }
        \\const Other = struct { fn writeInt(n: anytype) usize { return n; } };
        \\pub fn other(x: anytype) usize { return Other.writeInt(x); }
        \\fn unused(v: anytype) usize { var buf: [8]u8 = undefined; return (std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable).len; }
    , "");
}

test "Int.longest is the most std.fmt prints" {
    inline for (.{ 1, 2, 7, 8, 10, 16, 31, 32, 33, 63, 64, 65, 100, 127, 128, 129, 200, 255, 256, 1000 }) |bits| {
        var buf: [400]u8 = undefined;
        const U = @Int(.unsigned, bits);
        const I = @Int(.signed, bits);
        const unsigned = (try std.fmt.bufPrint(&buf, "{d}", .{std.math.maxInt(U)})).len;
        const signed = (try std.fmt.bufPrint(&buf, "{d}", .{@as(I, std.math.minInt(I))})).len;
        try std.testing.expectEqual(unsigned, Int.parse(@typeName(U)).?.longest());
        try std.testing.expectEqual(signed, Int.parse(@typeName(I)).?.longest());
    }
    try std.testing.expectEqual(1, Int.parse("u0").?.longest());
    try std.testing.expectEqual(20, Int.parse("usize").?.longest());
    try std.testing.expectEqual(20, Int.parse("isize").?.longest());
    for ([_][]const u8{ "u", "i", "i0", "u08", "u1_0", "f64", "uint", "u65536" }) |name| try std.testing.expectEqual(null, Int.parse(name));
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
