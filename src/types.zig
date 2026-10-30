//! What one file's syntax shows about types: the structs and unions it
//! declares, found by name through the containers around where a type is
//! written (`Id`, `Self`, an alias, `@This()`), their fields and functions,
//! what a pointer, array or slice type holds, and the type a name or a field
//! reached from one is declared with. Never across files: a type from
//! another file, or one a function returns, is not known.

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

    /// The file's own function a call's `fn_expr` names, and 1 when it is
    /// called as a method, whose receiver is its first argument, else 0:
    /// by name (`keep(b)`), through its type (`Store.keep(s, b)`), or as a
    /// method of a binding whose type the file declares (`self.keep(b)`).
    pub fn callee(t: Types, fn_expr: Node.Index) ?struct { Node.Index, usize } {
        const tree = t.tree;
        switch (tree.nodeTag(fn_expr)) {
            .identifier => {
                const fn_decl = t.declaredFn(fn_expr, tree.tokenSlice(tree.nodeMainToken(fn_expr))) orelse return null;
                return .{ fn_decl, 0 };
            },
            .field_access => {
                const receiver, const name_token = tree.nodeData(fn_expr).node_and_token;
                const name = tree.tokenSlice(name_token);
                // `Store.keep(s, b)`, through the type.
                if (t.containerOf(receiver, 0)) |container| {
                    return .{ memberFn(tree, container, name) orelse return null, 0 };
                }
                const of = t.typeOf(receiver, 0) orelse return null;
                const container = t.containerOf(pointee(tree, of) orelse of, 0) orelse return null;
                return .{ memberFn(tree, container, name) orelse return null, 1 };
            },
            else => return null,
        }
    }

    /// The type of `node` as the file writes it: a binding's, or a field's
    /// reached from one through structs the file declares.
    pub fn typeOf(t: Types, node: Node.Index, depth: u8) ?Node.Index {
        const tree = t.tree;
        if (depth > 8) return null;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return t.typeOf(tree.nodeData(node).node_and_token[0], depth + 1),
            .identifier => return t.bindingType(node, depth),
            .field_access => {
                const lhs, const field = tree.nodeData(node).node_and_token;
                const outer = t.typeOf(lhs, depth + 1) orelse return null;
                const container = t.containerOf(pointee(tree, outer) orelse outer, 0) orelse return null;
                return fieldType(tree, container, tree.tokenSlice(field));
            },
            else => return null,
        }
    }

    /// The type the file writes for what `use`, an identifier, names: found
    /// by walking out from it, as Zig allows no shadowing. A local's
    /// annotation, or with none the type its initializer writes
    /// (`const img = Image{ ... };`), a parameter's type, a container-level
    /// variable's annotation, or what a capture is taken from: an element
    /// of a `for` loop's input, the payload of an `if` or `while` on an
    /// optional or error union, or a union's field for a `switch` prong on
    /// one tag.
    pub fn bindingType(t: Types, use: Node.Index, depth: u8) ?Node.Index {
        const tree = t.tree;
        const name = tree.tokenSlice(tree.nodeMainToken(use));
        var child = use;
        var up = t.parents[@backingInt(use)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = t.parents[@backingInt(parent)].unwrap();
        }) {
            switch (tree.nodeTag(parent)) {
                .block, .block_semicolon, .block_two, .block_two_semicolon => {
                    if (t.localBefore(parent, child, name)) |decl| return decl.ast.type_node.unwrap() orelse initType(tree, decl);
                },
                .for_simple, .@"for" => {
                    const full = tree.fullFor(parent).?;
                    if (child != full.ast.then_expr) continue;
                    const index = captureIndex(tree, full.payload_token, name) orelse continue;
                    if (index >= full.ast.inputs.len) return null;
                    return t.elementType(full.ast.inputs[index], depth);
                },
                .if_simple, .@"if" => {
                    const full = tree.fullIf(parent).?;
                    if (child != full.ast.then_expr) continue;
                    if (captureIndex(tree, full.payload_token orelse continue, name) != 0) continue;
                    return payload(tree, t.typeOf(full.ast.cond_expr, depth + 1) orelse return null);
                },
                .while_simple, .while_cont, .@"while" => {
                    const full = tree.fullWhile(parent).?;
                    if (child != full.ast.then_expr) continue;
                    if (captureIndex(tree, full.payload_token orelse continue, name) != 0) continue;
                    return payload(tree, t.typeOf(full.ast.cond_expr, depth + 1) orelse return null);
                },
                .switch_case_one, .switch_case => {
                    const case = tree.fullSwitchCase(parent).?;
                    if (captureIndex(tree, case.payload_token orelse continue, name) != 0) continue;
                    // One prong per tag: `.number => |v|`.
                    if (case.ast.values.len != 1 or tree.nodeTag(case.ast.values[0]) != .enum_literal) return null;
                    const switch_node = t.parents[@backingInt(parent)].unwrap() orelse return null;
                    const condition = tree.fullSwitch(switch_node).?.ast.condition;
                    const of = t.typeOf(condition, depth + 1) orelse return null;
                    const container = t.containerOf(pointee(tree, of) orelse of, 0) orelse return null;
                    return fieldType(tree, container, tree.tokenSlice(tree.nodeMainToken(case.ast.values[0])));
                },
                .fn_decl => {
                    var buffer: [1]Node.Index = undefined;
                    const proto = tree.fullFnProto(&buffer, tree.nodeData(parent).node_and_node[0]).?;
                    var params = proto.iterate(tree);
                    while (params.next()) |param| {
                        const name_token = param.name_token orelse continue;
                        if (std.mem.eql(u8, tree.tokenSlice(name_token), name)) return param.type_expr;
                    }
                    return t.containerVariable(parent, name);
                },
                .test_decl => return t.containerVariable(parent, name),
                else => {},
            }
        }
        return null;
    }

    /// The initializer of the local `use`, an identifier, names, when it
    /// has one: found by walking out from it, as `bindingType` does.
    pub fn localInit(t: Types, use: Node.Index) ?Node.Index {
        const tree = t.tree;
        const name = tree.tokenSlice(tree.nodeMainToken(use));
        var child = use;
        var up = t.parents[@backingInt(use)].unwrap();
        while (up) |parent| : ({
            child = parent;
            up = t.parents[@backingInt(parent)].unwrap();
        }) {
            switch (tree.nodeTag(parent)) {
                .block, .block_semicolon, .block_two, .block_two_semicolon => {
                    if (t.localBefore(parent, child, name)) |decl| return decl.ast.init_node.unwrap();
                },
                .fn_decl, .test_decl => return null,
                else => {},
            }
        }
        return null;
    }

    /// The declared type of the container-level variable `name` in a
    /// container around `node`.
    fn containerVariable(t: Types, node: Node.Index, name: []const u8) ?Node.Index {
        const tree = t.tree;
        var around = t.enclosingContainer(node);
        while (around) |container| : (around = t.enclosingContainer(container)) {
            const decl = memberDecl(tree, container, name) orelse continue;
            return tree.fullVarDecl(decl).?.ast.type_node.unwrap();
        }
        return null;
    }

    /// The local `name` declared in `block` before its statement `child`.
    fn localBefore(t: Types, block: Node.Index, child: Node.Index, name: []const u8) ?Ast.full.VarDecl {
        const tree = t.tree;
        var buffer: [2]Node.Index = undefined;
        for (tree.blockStatements(&buffer, block).?) |statement| {
            if (statement == child) return null;
            const decl = tree.fullVarDecl(statement) orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)) return decl;
        }
        return null;
    }

    /// The type of an element of a `for` loop's input: `xs`, `&xs` or
    /// `xs[a..b]`, with `xs` an array, a slice or a pointer to an array.
    fn elementType(t: Types, input: Node.Index, depth: u8) ?Node.Index {
        const tree = t.tree;
        return switch (tree.nodeTag(input)) {
            .grouped_expression => t.elementType(tree.nodeData(input).node_and_token[0], depth),
            .address_of => t.elementType(tree.nodeData(input).node, depth),
            .slice_open, .slice, .slice_sentinel => t.elementType(tree.fullSlice(input).?.ast.sliced, depth),
            else => elementOf(tree, t.typeOf(input, depth + 1) orelse return null),
        };
    }
};

/// The type a local's initializer writes, for a declaration that writes
/// none: `Image` of `const img = Image{ .pixels = pixels };`.
fn initType(tree: *const Ast, decl: Ast.full.VarDecl) ?Node.Index {
    const init = decl.ast.init_node.unwrap() orelse return null;
    var buffer: [2]Node.Index = undefined;
    const struct_init = tree.fullStructInit(&buffer, init) orelse return null;
    return struct_init.ast.type_expr.unwrap();
}

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

/// Which of `|a, *b|`, starting at `first`, is `name` and held by value.
pub fn captureIndex(tree: *const Ast, first: Ast.TokenIndex, name: []const u8) ?usize {
    var token = first;
    var index: usize = 0;
    while (true) : (index += 1) {
        const by_pointer = tree.tokenTag(token) == .asterisk;
        if (by_pointer) token += 1;
        if (tree.tokenTag(token) != .identifier) return null;
        if (std.mem.eql(u8, tree.tokenSlice(token), name)) return if (by_pointer) null else index;
        token += 1;
        if (tree.tokenTag(token) != .comma) return null;
        token += 1;
    }
}

/// `T` of `?T` or `E!T`: what an `if` or `while` captures.
fn payload(tree: *const Ast, type_expr: Node.Index) ?Node.Index {
    return switch (tree.nodeTag(type_expr)) {
        .optional_type => tree.nodeData(type_expr).node,
        .error_union => tree.nodeData(type_expr).node_and_node[1],
        else => null,
    };
}
