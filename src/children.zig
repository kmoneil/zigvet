//! The child nodes of any `std.zig.Ast` node, in source order. The switch
//! names every tag with no `else`, so a tag a later Zig release adds or
//! reshapes is a compile error here rather than a subtree the rules skip.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

/// Appends `node`'s children to `out`.
pub fn append(gpa: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    const data = tree.nodeData(node);
    switch (tree.nodeTag(node)) {
        .root => try out.appendSlice(gpa, tree.rootDecls()),

        .test_decl => try out.append(gpa, data.opt_token_and_node[1]),

        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const decl = tree.fullVarDecl(node).?;
            try appendOptionals(gpa, out, &.{
                decl.ast.type_node,
                decl.ast.align_node,
                decl.ast.addrspace_node,
                decl.ast.section_node,
                decl.ast.init_node,
            });
        },

        .@"errdefer",
        .@"defer",
        .bool_not,
        .negation,
        .bit_not,
        .negation_wrap,
        .address_of,
        .@"try",
        .optional_type,
        .deref,
        .@"suspend",
        .@"resume",
        .@"comptime",
        .@"nosuspend",
        => try out.append(gpa, data.node),

        .@"catch",
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        .assign,
        .merge_error_sets,
        .mul,
        .div,
        .mod,
        .mul_wrap,
        .mul_sat,
        .add,
        .sub,
        .array_cat,
        .add_wrap,
        .sub_wrap,
        .add_sat,
        .sub_sat,
        .shl,
        .shl_sat,
        .shr,
        .bit_and,
        .bit_xor,
        .bit_or,
        .@"orelse",
        .bool_and,
        .bool_or,
        .array_type,
        .array_access,
        .switch_range,
        .error_union,
        => try out.appendSlice(gpa, &.{ data.node_and_node[0], data.node_and_node[1] }),

        .assign_destructure => {
            const destructure = tree.assignDestructure(node);
            try out.appendSlice(gpa, destructure.ast.variables);
            try out.append(gpa, destructure.ast.value_expr);
        },

        .field_access, .unwrap_optional, .grouped_expression, .asm_input => try out.append(gpa, data.node_and_token[0]),

        .asm_output => if (data.opt_node_and_token[0].unwrap()) |child| try out.append(gpa, child),

        .anyframe_type => try out.append(gpa, data.token_and_node[1]),

        .array_type_sentinel => {
            const array_type = tree.fullArrayType(node).?;
            try out.append(gpa, array_type.ast.elem_count);
            try appendOptionals(gpa, out, &.{array_type.ast.sentinel});
            try out.append(gpa, array_type.ast.elem_type);
        },

        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        => {
            const ptr_type = tree.fullPtrType(node).?;
            try appendOptionals(gpa, out, &.{
                ptr_type.ast.sentinel,
                ptr_type.ast.align_node,
                ptr_type.ast.addrspace_node,
                ptr_type.ast.bit_range_start,
                ptr_type.ast.bit_range_end,
            });
            try out.append(gpa, ptr_type.ast.child_type);
        },

        .slice_open, .slice, .slice_sentinel => {
            const slice = tree.fullSlice(node).?;
            try out.appendSlice(gpa, &.{ slice.ast.sliced, slice.ast.start });
            try appendOptionals(gpa, out, &.{ slice.ast.end, slice.ast.sentinel });
        },

        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => {
            var buffer: [2]Node.Index = undefined;
            const init = tree.fullArrayInit(&buffer, node).?;
            try appendOptionals(gpa, out, &.{init.ast.type_expr});
            try out.appendSlice(gpa, init.ast.elements);
        },

        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => {
            var buffer: [2]Node.Index = undefined;
            const init = tree.fullStructInit(&buffer, node).?;
            try appendOptionals(gpa, out, &.{init.ast.type_expr});
            try out.appendSlice(gpa, init.ast.fields);
        },

        .call_one, .call_one_comma, .call, .call_comma => {
            var buffer: [1]Node.Index = undefined;
            const call = tree.fullCall(&buffer, node).?;
            try out.append(gpa, call.ast.fn_expr);
            try out.appendSlice(gpa, call.ast.params);
        },

        .@"switch", .switch_comma => {
            const switch_full = tree.fullSwitch(node).?;
            try out.append(gpa, switch_full.ast.condition);
            try out.appendSlice(gpa, switch_full.ast.cases);
        },

        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => {
            const case = tree.fullSwitchCase(node).?;
            try out.appendSlice(gpa, case.ast.values);
            try out.append(gpa, case.ast.target_expr);
        },

        .while_simple, .while_cont, .@"while" => {
            const while_full = tree.fullWhile(node).?;
            try out.append(gpa, while_full.ast.cond_expr);
            try appendOptionals(gpa, out, &.{while_full.ast.cont_expr});
            try out.append(gpa, while_full.ast.then_expr);
            try appendOptionals(gpa, out, &.{while_full.ast.else_expr});
        },

        .for_simple, .@"for" => {
            const for_full = tree.fullFor(node).?;
            try out.appendSlice(gpa, for_full.ast.inputs);
            try out.append(gpa, for_full.ast.then_expr);
            try appendOptionals(gpa, out, &.{for_full.ast.else_expr});
        },

        .for_range => {
            try out.append(gpa, data.node_and_opt_node[0]);
            try appendOptionals(gpa, out, &.{data.node_and_opt_node[1]});
        },

        .if_simple, .@"if" => {
            const if_full = tree.fullIf(node).?;
            try out.appendSlice(gpa, &.{ if_full.ast.cond_expr, if_full.ast.then_expr });
            try appendOptionals(gpa, out, &.{if_full.ast.else_expr});
        },

        .@"continue", .@"break" => try appendOptionals(gpa, out, &.{data.opt_token_and_opt_node[1]}),

        .@"return" => try appendOptionals(gpa, out, &.{data.opt_node}),

        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => {
            var buffer: [1]Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, node).?;
            try out.appendSlice(gpa, proto.ast.params);
            try appendOptionals(gpa, out, &.{
                proto.ast.align_expr,
                proto.ast.addrspace_expr,
                proto.ast.section_expr,
                proto.ast.callconv_expr,
                proto.ast.return_type,
            });
        },

        .fn_decl => try out.appendSlice(gpa, &.{ data.node_and_node[0], data.node_and_node[1] }),

        .anyframe_literal,
        .char_literal,
        .number_literal,
        .unreachable_literal,
        .identifier,
        .enum_literal,
        .string_literal,
        .multiline_string_literal,
        .error_set_decl,
        .error_value,
        => {},

        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => {
            var buffer: [2]Node.Index = undefined;
            try out.appendSlice(gpa, tree.builtinCallParams(&buffer, node).?);
        },

        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => {
            var buffer: [2]Node.Index = undefined;
            const decl = tree.fullContainerDecl(&buffer, node).?;
            try appendOptionals(gpa, out, &.{decl.ast.arg});
            try out.appendSlice(gpa, decl.ast.members);
        },

        .container_field_init,
        .container_field_align,
        .container_field,
        => {
            const field = tree.fullContainerField(node).?;
            try appendOptionals(gpa, out, &.{ field.ast.type_expr, field.ast.align_expr, field.ast.value_expr });
        },

        .block_two,
        .block_two_semicolon,
        .block,
        .block_semicolon,
        => {
            var buffer: [2]Node.Index = undefined;
            try out.appendSlice(gpa, tree.blockStatements(&buffer, node).?);
        },

        .asm_simple, .@"asm" => {
            const asm_full = tree.fullAsm(node).?;
            try out.append(gpa, asm_full.ast.template);
            try out.appendSlice(gpa, asm_full.ast.items);
            try appendOptionals(gpa, out, &.{asm_full.ast.clobbers});
        },
    }
}

fn appendOptionals(gpa: Allocator, out: *std.ArrayList(Node.Index), nodes: []const Node.OptionalIndex) Allocator.Error!void {
    for (nodes) |optional| if (optional.unwrap()) |child| try out.append(gpa, child);
}

test "every node is reached from the root exactly once" {
    // Syntax chosen to use as many tags as possible, with the less common
    // forms (asm, destructuring, sentinels, bit ranges, labeled switch) on
    // purpose.
    const source =
        \\const std = @import("std");
        \\pub const E = error{ A, B } || error{C};
        \\const U = union(enum(u8)) { a: u8 align(4), b: void = {}, c };
        \\const T = union(enum) { a, b };
        \\const S = extern struct { x: u32 = 0, y: *align(1:0:4) u8 };
        \\const P = packed struct(u8) { a: u4, b: u4 };
        \\const O = opaque {};
        \\threadlocal var tl: [4:0]u8 linksection(".data") = undefined;
        \\test "t" {}
        \\test {}
        \\fn f(comptime n: u8, a: anytype, s: [:0]const u8, p: [*c]u8) callconv(.c) !?*const u8 {
        \\    var x: u8 align(2) = n +% 1 -| 2 *| 3 << 1 >> 1 <<| 1;
        \\    x += 1; x -= 1; x *= 1; x /= 1; x %= 1; x <<= 1; x >>= 1; x <<|= 1;
        \\    x &= 1; x |= 1; x ^= 1; x +%= 1; x -%= 1; x *%= 1; x +|= 1; x -|= 1; x *|= 1;
        \\    const y, var z = .{ x, -%x };
        \\    z = ~y & ~x | (x ^ y) % 2 / 1 * 1;
        \\    defer _ = s[0..1 :0];
        \\    errdefer _ = p[0..];
        \\    const w = blk: {
        \\        if (x == 1 and y != 2 or !(z < 3) or x > 4 or x <= 5 or x >= 6) break :blk -x;
        \\        break :blk @as(u8, 0);
        \\    };
        \\    for (0..10, s) |i, c| {
        \\        if (i == c) continue;
        \\    } else {}
        \\    var i: usize = 0;
        \\    while (i < 3) : (i += 1) {} else {}
        \\    outer: switch (w) {
        \\        0...3 => |v| continue :outer v + 4,
        \\        inline 4, 5 => {},
        \\        else => {},
        \\    }
        \\    const arr = [_]u8{ 1, 2, 3 } ++ [2]u8{ 4, 5 };
        \\    const pt: S = .{ .x = 1, .y = &x };
        \\    _ = .{ arr[1], pt.y.*, T.a, .{ .q = 1 } };
        \\    const opt: ?u8 = null;
        \\    _ = opt.? + (opt orelse 0);
        \\    const eu: E!u8 = error.A;
        \\    _ = eu catch |e| @intFromError(e);
        \\    _ = try eu;
        \\    _ = comptime n;
        \\    _ = a;
        \\    asm volatile ("nop" : [ret] "={x0}" (-> usize) : [n] "{x1}" (x) : .{ .memory = true });
        \\    const fp: *const fn () void = undefined;
        \\    _ = fp;
        \\    _ = 'c' + 0x10 + 1.5 + "s".len + \\multi
        \\    ;
        \\    unreachable;
        \\}
    ;
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    try expectReachesAll(gpa, &tree);
}

/// Walks `tree` from the root and asserts each node is visited once.
pub fn expectReachesAll(gpa: Allocator, tree: *const Ast) !void {
    const seen = try gpa.alloc(bool, tree.nodes.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(Node.Index) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .root);
    while (stack.pop()) |node| {
        try std.testing.expect(!seen[@backingInt(node)]);
        seen[@backingInt(node)] = true;
        try append(gpa, tree, node, &stack);
    }
    for (seen, 0..) |reached, i| {
        if (!reached) {
            std.debug.print("node {d} ({t}) not reached\n", .{ i, tree.nodeTag(@fromBackingInt(@intCast(i))) });
            return error.TestUnexpectedResult;
        }
    }
}
