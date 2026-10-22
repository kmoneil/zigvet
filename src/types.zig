//! What one file's syntax shows about types: the structs and unions it
//! declares, found by name through the containers around where a type is
//! written (`Id`, `Self`, an alias, `@This()`), their fields and functions,
//! and what a pointer, array or slice type holds. Never across files: a type
//! from another file, or one a function returns, is not known.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");

pub const Types = struct {
    tree: *const Ast,
    /// Every node's parent, for the containers around a type's name.
    parents: []const Node.OptionalIndex,

    pub fn init(arena: Allocator, tree: *const Ast) Allocator.Error!Types {
        const parents = try arena.alloc(Node.OptionalIndex, tree.nodes.len);
        @memset(parents, .none);
        var nodes: std.ArrayList(Node.Index) = .empty;
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @fromBackingInt(@intCast(i));
            nodes.clearRetainingCapacity();
            try children.append(arena, tree, node, &nodes);
            for (nodes.items) |child| parents[@backingInt(child)] = node.toOptional();
        }
        return .{ .tree = tree, .parents = parents };
    }

    /// The struct or union that `type_expr` names, when the file declares
    /// it: a name declared in a container around where it is written
    /// (`Id`, `Self`), possibly through another name, or `@This()`. Null for
    /// anything else, such as a type from another file.
    pub fn containerOf(t: Types, type_expr: Node.Index, depth: u8) ?Node.Index {
        const tree = t.tree;
        if (depth > 4) return null;
        switch (tree.nodeTag(type_expr)) {
            .grouped_expression => return t.containerOf(tree.nodeData(type_expr).node_and_token[0], depth),
            .builtin_call_two, .builtin_call_two_comma => {
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_expr)), "@This")) return null;
                return t.enclosingContainer(type_expr);
            },
            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(type_expr));
                var around = t.enclosingContainer(type_expr);
                while (around) |container| : (around = t.enclosingContainer(container)) {
                    const decl = memberDecl(tree, container, name) orelse continue;
                    const value = tree.fullVarDecl(decl).?.ast.init_node.unwrap() orelse return null;
                    var buffer: [2]Node.Index = undefined;
                    if (tree.fullContainerDecl(&buffer, value) != null) return value;
                    return t.containerOf(value, depth + 1);
                }
                return null;
            },
            else => return null,
        }
    }

    /// The innermost container around `node`: a struct, union, enum or
    /// opaque, or the file.
    pub fn enclosingContainer(t: Types, node: Node.Index) ?Node.Index {
        var up = t.parents[@backingInt(node)].unwrap();
        while (up) |parent| : (up = t.parents[@backingInt(parent)].unwrap()) {
            var buffer: [2]Node.Index = undefined;
            if (t.tree.fullContainerDecl(&buffer, parent) != null) return parent;
        }
        return null;
    }

    /// The function `name` declared in a container around `node`.
    pub fn declaredFn(t: Types, node: Node.Index, name: []const u8) ?Node.Index {
        var around = t.enclosingContainer(node);
        while (around) |container| : (around = t.enclosingContainer(container)) {
            if (memberFn(t.tree, container, name)) |fn_decl| return fn_decl;
        }
        return null;
    }
};

/// What a pointer to one value, `*T` or `*const T`, points at.
pub fn pointee(tree: *const Ast, type_expr: Node.Index) ?Node.Index {
    const ptr = tree.fullPtrType(type_expr) orelse return null;
    if (ptr.size != .one) return null;
    return ptr.ast.child_type;
}

/// The declaration `name` among `container`'s members.
pub fn memberDecl(tree: *const Ast, container: Node.Index, name: []const u8) ?Node.Index {
    var buffer: [2]Node.Index = undefined;
    for (tree.fullContainerDecl(&buffer, container).?.ast.members) |member| {
        const decl = tree.fullVarDecl(member) orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)) return member;
    }
    return null;
}

/// The function `name` among `container`'s members.
pub fn memberFn(tree: *const Ast, container: Node.Index, name: []const u8) ?Node.Index {
    var buffer: [2]Node.Index = undefined;
    for (tree.fullContainerDecl(&buffer, container).?.ast.members) |member| {
        if (tree.nodeTag(member) != .fn_decl) continue;
        var proto_buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&proto_buffer, tree.nodeData(member).node_and_node[0]).?;
        const name_token = proto.name_token orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(name_token), name)) return member;
    }
    return null;
}

/// The type `container`'s field `name` is declared with.
pub fn fieldType(tree: *const Ast, container: Node.Index, name: []const u8) ?Node.Index {
    var buffer: [2]Node.Index = undefined;
    for (tree.fullContainerDecl(&buffer, container).?.ast.members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        if (field.ast.tuple_like or !std.mem.eql(u8, tree.tokenSlice(field.ast.main_token), name)) continue;
        return field.ast.type_expr.unwrap();
    }
    return null;
}

/// What an array, a slice or a pointer to an array holds: `T` of `[N]T`,
/// `[]const T`, `[*]T` or `*const [N]T`.
pub fn elementOf(tree: *const Ast, type_expr: Node.Index) ?Node.Index {
    switch (tree.nodeTag(type_expr)) {
        .grouped_expression => return elementOf(tree, tree.nodeData(type_expr).node_and_token[0]),
        .array_type, .array_type_sentinel => return tree.fullArrayType(type_expr).?.ast.elem_type,
        else => {
            const ptr = tree.fullPtrType(type_expr) orelse return null;
            if (ptr.size != .one) return ptr.ast.child_type;
            return switch (tree.nodeTag(ptr.ast.child_type)) {
                .array_type, .array_type_sentinel => tree.fullArrayType(ptr.ast.child_type).?.ast.elem_type,
                else => null,
            };
        },
    }
}
