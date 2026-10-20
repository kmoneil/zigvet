//! Rule one, escape: a pointer or slice into stack memory that leaves the
//! function that made it.
//!
//! Each function is checked in two passes. The first walks the body with a
//! scope chain, resolving every identifier to the parameter, local or
//! capture it names, and collecting the sinks: `return`, a store through a
//! parameter, and a store to a container-level variable. The second follows
//! each sink's value back through `if`, `switch`, `orelse`, `catch`, labeled
//! blocks, locals and the `std` calls that return a view of an argument
//! (`std.fmt.bufPrint`, `std.mem.sliceTo`, ...), and reports a value that is
//! the address or a slice of stack memory whose contents are not
//! comptime-known.
//!
//! Comptime-known memory is static, so `&.{"literal"}` is fine and
//! `&.{f()}` is not: a call is evaluated at run time unless it is under
//! `comptime`, or the callee is an `inline fn` (or returns a comptime-only
//! type) given comptime-known arguments. A function that itself returns a
//! comptime-only type runs only at compile time and is not checked. The one
//! accepted false positive is any other function only ever called at
//! compile time; it can say `comptime`, or carry an allow comment.
//!
//! Returned, any stack address is reported. Stored through a parameter or
//! to a container-level variable, only a temporary (`&.{...}`, `&f()`) is:
//! a named local stored outward is usually deliberate and bounded by the
//! call, and a store a `defer` undoes is not reported at all.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const Sink = report.Sink;

/// Appends a finding for every escape in `tree`. Everything, findings
/// included, is allocated with `arena`, which must outlive the findings.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings };
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]).?;
        const name = tree.tokenSlice(proto.name_token orelse continue);
        const gop = try rule.comptime_result_fns.getOrPut(arena, name);
        gop.value_ptr.* = hasComptimeResult(tree, proto) and (!gop.found_existing or gop.value_ptr.*);
    }
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) == .fn_decl) try rule.function(node);
    }
}

const hint_literal = "make it comptime-known (`comptime` on the runtime elements) or a container-level const";
const hint_storage = "return the value itself, have the caller pass in the memory, or allocate it";
const hint_storage_comptime = hint_storage ++ "; if it only runs at compile time, say so with `return comptime blk: { ... }`";

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),

    /// Every binding in the file; `scope` indexes the ones in scope.
    bindings: std.ArrayList(Binding) = .empty,
    scope: std.ArrayList(u32) = .empty,
    /// Identifier node to the binding it names. Absent means a
    /// container-level declaration or a primitive, both comptime-known.
    resolved: std.AutoHashMapUnmanaged(Node.Index, u32) = .empty,
    /// Later `x = value` stores to a local, for following aliases.
    stores: std.ArrayList(Store) = .empty,
    /// Function name to whether every function of that name in the file
    /// gives a comptime-known result for comptime-known arguments.
    comptime_result_fns: std.StringHashMapUnmanaged(bool) = .empty,

    /// The function being checked.
    function_name: []const u8 = "",
    sinks: std.ArrayList(SinkSite) = .empty,
    /// What a `defer` in the function assigns to, as source text: a store
    /// to one of these is undone before the function returns.
    deferred_resets: std.StringHashMapUnmanaged(void) = .empty,
    reported: std.AutoHashMapUnmanaged(struct { Ast.TokenIndex, Sink }, void) = .empty,
    comptime_depth: u32 = 0,
    /// Whether the function has a comptime parameter, as one only ever run
    /// at compile time always does: its storage hint names that fix too.
    comptime_params: bool = false,

    fn function(r: *Rule, fn_decl: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        const proto_node, const body = tree.nodeData(fn_decl).node_and_node;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, proto_node).?;

        // Its calls are all evaluated at compile time, so nothing it makes
        // is on a run-time stack.
        if (proto.ast.return_type.unwrap()) |t| if (isComptimeType(tree, t)) return;

        r.function_name = if (proto.name_token) |t| tree.tokenSlice(t) else "function";
        r.scope.clearRetainingCapacity();
        r.sinks.clearRetainingCapacity();
        r.deferred_resets.clearRetainingCapacity();
        r.reported.clearRetainingCapacity();
        r.comptime_depth = 0;
        r.comptime_params = false;

        var params = proto.iterate(tree);
        while (params.next()) |param| {
            const name_token = param.name_token orelse continue;
            const declared_comptime = if (param.comptime_noalias) |t| tree.tokenTag(t) == .keyword_comptime else false;
            const is_comptime = declared_comptime or (if (param.type_expr) |t| isComptimeType(tree, t) else false);
            r.comptime_params = r.comptime_params or is_comptime;
            try r.declare(.{
                .name = tree.tokenSlice(name_token),
                .kind = .parameter,
                .mutable = false,
                .is_comptime = is_comptime,
                .storage = if (param.type_expr) |t| storageOfType(tree, t) else .unknown,
                .init = .none,
            });
        }
        try r.walk(body);

        for (r.sinks.items) |site| {
            if (site.target) |target| {
                if (r.deferred_resets.contains(tree.getNodeSource(target))) continue;
            }
            var values: std.ArrayList(Node.Index) = .empty;
            try r.leaves(site.value, &values);
            for (values.items) |value| {
                const source = try r.stackSource(value, 0) orelse continue;
                // A named local stored outward is often deliberate: a
                // context pointer for the length of a call, a thread's
                // `current`, `argv` just before `execve`. A temporary
                // stored outward never is. Returned, both are wrong.
                if (site.sink != .@"return" and !source.temporary) continue;
                const gop = try r.reported.getOrPut(r.arena, .{ source.token, site.sink });
                if (gop.found_existing) continue;
                try r.findings.append(r.arena, .{
                    .offset = tree.tokenStart(source.token),
                    .hint = source.hint,
                    .detail = .{ .escape = .{ .what = source.what, .function = r.function_name, .sink = site.sink } },
                });
            }
        }
    }

    // Pass one: scopes, bindings and sinks.

    fn walk(r: *Rule, node: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        switch (tree.nodeTag(node)) {
            // Nested functions are checked on their own, and a type's
            // declarations are container-level.
            .fn_decl,
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
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
            => {},

            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                var i = r.scope.items.len;
                while (i > 0) {
                    i -= 1;
                    const index = r.scope.items[i];
                    if (std.mem.eql(u8, r.bindings.items[index].name, name)) {
                        try r.resolved.put(r.arena, node, index);
                        return;
                    }
                }
            },

            .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                // The initializer is walked first: it cannot name the local.
                try r.walkChildren(node);
                const decl = tree.fullVarDecl(node).?;
                try r.declare(.{
                    .name = tree.tokenSlice(decl.ast.mut_token + 1),
                    .kind = .local,
                    .mutable = tree.tokenTag(decl.ast.mut_token) == .keyword_var,
                    .is_comptime = decl.comptime_token != null or (if (decl.ast.type_node.unwrap()) |t| isComptimeType(tree, t) else false),
                    .storage = storageOfLocal(tree, decl.ast.type_node, decl.ast.init_node),
                    .init = decl.ast.init_node,
                });
            },

            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                const outer = r.scope.items.len;
                try r.walkChildren(node);
                r.scope.shrinkRetainingCapacity(outer);
            },

            .if_simple, .@"if" => {
                const full = tree.fullIf(node).?;
                try r.walk(full.ast.cond_expr);
                const outer = r.scope.items.len;
                if (full.payload_token) |t| try r.declareCaptures(t, false);
                try r.walk(full.ast.then_expr);
                r.scope.shrinkRetainingCapacity(outer);
                if (full.ast.else_expr.unwrap()) |else_expr| {
                    if (full.error_token) |t| try r.declareCaptures(t, false);
                    try r.walk(else_expr);
                    r.scope.shrinkRetainingCapacity(outer);
                }
            },

            .while_simple, .while_cont, .@"while" => {
                const full = tree.fullWhile(node).?;
                try r.walk(full.ast.cond_expr);
                const outer = r.scope.items.len;
                if (full.payload_token) |t| try r.declareCaptures(t, full.inline_token != null);
                if (full.ast.cont_expr.unwrap()) |cont| try r.walk(cont);
                try r.walk(full.ast.then_expr);
                r.scope.shrinkRetainingCapacity(outer);
                if (full.ast.else_expr.unwrap()) |else_expr| {
                    if (full.error_token) |t| try r.declareCaptures(t, false);
                    try r.walk(else_expr);
                    r.scope.shrinkRetainingCapacity(outer);
                }
            },

            .for_simple, .@"for" => {
                const full = tree.fullFor(node).?;
                for (full.ast.inputs) |input| try r.walk(input);
                const outer = r.scope.items.len;
                try r.declareCaptures(full.payload_token, full.inline_token != null);
                try r.walk(full.ast.then_expr);
                r.scope.shrinkRetainingCapacity(outer);
                if (full.ast.else_expr.unwrap()) |else_expr| try r.walk(else_expr);
            },

            .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {
                const full = tree.fullSwitchCase(node).?;
                for (full.ast.values) |value| try r.walk(value);
                const outer = r.scope.items.len;
                if (full.payload_token) |t| try r.declareCaptures(t, full.inline_token != null);
                try r.walk(full.ast.target_expr);
                r.scope.shrinkRetainingCapacity(outer);
            },

            .@"catch" => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                try r.walk(lhs);
                const outer = r.scope.items.len;
                const catch_token = tree.nodeMainToken(node);
                if (tree.tokenTag(catch_token + 1) == .pipe) try r.declareCaptures(catch_token + 2, false);
                try r.walk(rhs);
                r.scope.shrinkRetainingCapacity(outer);
            },

            .@"comptime" => {
                r.comptime_depth += 1;
                defer r.comptime_depth -= 1;
                try r.walkChildren(node);
            },

            .@"defer" => {
                try r.deferredResets(tree.nodeData(node).node);
                try r.walkChildren(node);
            },

            .@"return" => {
                try r.walkChildren(node);
                if (r.comptime_depth > 0) return;
                if (tree.nodeData(node).opt_node.unwrap()) |value| {
                    try r.sinks.append(r.arena, .{ .value = value, .sink = .@"return", .target = null });
                }
            },

            .assign => {
                try r.walkChildren(node);
                if (r.comptime_depth > 0) return;
                try r.assignment(node);
            },

            else => try r.walkChildren(node),
        }
    }

    /// Records the target of every assignment in a deferred expression,
    /// `defer x = prev;` or a `defer { ... }` block.
    fn deferredResets(r: *Rule, node: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        if (tree.nodeTag(node) == .assign) {
            const target = tree.nodeData(node).node_and_node[0];
            try r.deferred_resets.put(r.arena, tree.getNodeSource(target), {});
        }
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, tree, node, &nodes);
        for (nodes.items) |child| try r.deferredResets(child);
    }

    fn walkChildren(r: *Rule, node: Node.Index) Allocator.Error!void {
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, r.tree, node, &nodes);
        for (nodes.items) |child| try r.walk(child);
    }

    fn declare(r: *Rule, binding: Binding) Allocator.Error!void {
        var b = binding;
        b.is_comptime = b.is_comptime or r.comptime_depth > 0;
        try r.scope.append(r.arena, @intCast(r.bindings.items.len));
        try r.bindings.append(r.arena, b);
    }

    /// Declares `|a, *b|` starting at the token after the opening `|`.
    fn declareCaptures(r: *Rule, first: Ast.TokenIndex, is_comptime: bool) Allocator.Error!void {
        const tree = r.tree;
        var token = first;
        while (true) {
            const by_pointer = tree.tokenTag(token) == .asterisk;
            if (by_pointer) token += 1;
            if (tree.tokenTag(token) != .identifier) return;
            const name = tree.tokenSlice(token);
            if (!std.mem.eql(u8, name, "_")) try r.declare(.{
                .name = name,
                .kind = .capture,
                .mutable = false,
                .is_comptime = is_comptime,
                .storage = if (by_pointer) .pointer else .unknown,
                .init = .none,
            });
            token += 1;
            if (tree.tokenTag(token) != .comma) return;
            token += 1;
        }
    }

    /// Records `lhs = rhs` as a sink when `lhs` is memory outside the
    /// function, or as a store to a local for following aliases.
    fn assignment(r: *Rule, node: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        var through_field = false;
        var root = lhs;
        while (true) switch (tree.nodeTag(root)) {
            .field_access => {
                through_field = true;
                root = tree.nodeData(root).node_and_token[0];
            },
            .array_access => root = tree.nodeData(root).node_and_node[0],
            .deref => root = tree.nodeData(root).node,
            .unwrap_optional, .grouped_expression => root = tree.nodeData(root).node_and_token[0],
            else => break,
        };
        if (tree.nodeTag(root) != .identifier) return;

        const index = r.resolved.get(root) orelse {
            // `_ = x` discards; any other name not in scope is a
            // container-level variable.
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(root)), "_")) return;
            return r.sinks.append(r.arena, .{ .value = rhs, .sink = .global, .target = lhs });
        };
        switch (r.bindings.items[index].kind) {
            // Parameters are immutable, so a store through one goes through
            // a pointer the caller passed in.
            .parameter => if (root != lhs) try r.sinks.append(r.arena, .{
                .value = rhs,
                .sink = if (through_field) .field else .out_param,
                .target = lhs,
            }),
            .local => if (root == lhs) try r.stores.append(r.arena, .{ .binding = index, .value = rhs }),
            .capture => {},
        }
    }

    // Pass two: where a sink's value comes from.

    /// Appends the expressions `node` can evaluate to.
    fn leaves(r: *Rule, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
        const tree = r.tree;
        switch (tree.nodeTag(node)) {
            .grouped_expression => try r.leaves(tree.nodeData(node).node_and_token[0], out),
            .@"try" => try r.leaves(tree.nodeData(node).node, out),
            .@"orelse", .@"catch" => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                try r.leaves(lhs, out);
                try r.leaves(rhs, out);
            },
            .if_simple, .@"if" => {
                const full = tree.fullIf(node).?;
                try r.leaves(full.ast.then_expr, out);
                if (full.ast.else_expr.unwrap()) |else_expr| try r.leaves(else_expr, out);
            },
            .@"switch", .switch_comma => for (tree.fullSwitch(node).?.ast.cases) |case| {
                try r.leaves(tree.fullSwitchCase(case).?.ast.target_expr, out);
            },
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                const label = blockLabel(tree, node) orelse return;
                var breaks: std.ArrayList(Node.Index) = .empty;
                try r.breaksTo(node, label, &breaks);
                for (breaks.items) |value| try r.leaves(value, out);
            },
            // A struct or array returned or stored by value carries its
            // fields out with it.
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init,
            .array_init_comma,
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
                for (initValues(tree, &buffer, node)) |value| try r.leaves(value, out);
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                if (pointerPreservingOperand(tree, node)) |operand| try r.leaves(operand, out) else try out.append(r.arena, node);
            },
            .@"comptime" => {},
            else => try out.append(r.arena, node),
        }
    }

    /// Appends the operand of each `break :label value` inside `node`.
    fn breaksTo(r: *Rule, node: Node.Index, label: []const u8, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
        const tree = r.tree;
        var nodes: std.ArrayList(Node.Index) = .empty;
        try children.append(r.arena, tree, node, &nodes);
        for (nodes.items) |child| switch (tree.nodeTag(child)) {
            .fn_decl, .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing => {},
            .@"break" => {
                const label_token, const value = tree.nodeData(child).opt_token_and_opt_node;
                const target = label_token.unwrap() orelse continue;
                if (!std.mem.eql(u8, tree.tokenSlice(target), label)) continue;
                if (value.unwrap()) |v| try out.append(r.arena, v);
            },
            else => try r.breaksTo(child, label, out),
        };
    }

    const Source = struct {
        token: Ast.TokenIndex,
        what: []const u8,
        hint: []const u8,
        /// A temporary, `&.{...}` or `&f()`, which nothing else can name.
        /// Otherwise a named local, parameter or capture.
        temporary: bool,
    };

    /// Whether `node` evaluates to the address of, or a slice of, stack
    /// memory: what it is and where it is made. `depth` bounds alias chains.
    fn stackSource(r: *Rule, node: Node.Index, depth: u8) Allocator.Error!?Source {
        const tree = r.tree;
        if (depth > 4) return null;
        return switch (tree.nodeTag(node)) {
            .grouped_expression => r.stackSource(tree.nodeData(node).node_and_token[0], depth),
            .address_of => r.addressSource(tree.nodeData(node).node, tree.nodeMainToken(node)),
            .slice_open, .slice, .slice_sentinel => r.sliceSource(tree.fullSlice(node).?.ast.sliced, depth),
            // `slice.ptr` points where the slice does.
            .field_access => {
                const lhs, const field = tree.nodeData(node).node_and_token;
                if (!std.mem.eql(u8, tree.tokenSlice(field), "ptr")) return null;
                return r.stackSource(lhs, depth);
            },
            // A local holding one: `const x = &.{f()}; return x;`, or
            // `const s = try std.fmt.bufPrint(&buf, ...); return s;`.
            .identifier => {
                const index = r.resolved.get(node) orelse return null;
                const binding = r.bindings.items[index];
                if (binding.kind != .local or binding.is_comptime) return null;
                if (binding.init.unwrap()) |init| {
                    if (try r.leafSource(init, depth + 1)) |source| return source;
                }
                for (r.stores.items) |store| {
                    if (store.binding != index) continue;
                    if (try r.leafSource(store.value, depth + 1)) |source| return source;
                }
                return null;
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const operand = pointerPreservingOperand(tree, node) orelse return null;
                return r.stackSource(operand, depth);
            },
            .call_one, .call_one_comma, .call, .call_comma => {
                const argument = r.viewedArgument(node) orelse return null;
                return r.stackSource(argument, depth);
            },
            else => null,
        };
    }

    /// The argument a call's result points into, when the callee is one of
    /// `std_view_fns`: named through its namespace (`std.fmt.bufPrint`,
    /// `fmt.bufPrint`), or alone (`bufPrint`) in a file that declares no
    /// function of that name.
    fn viewedArgument(r: *Rule, node: Node.Index) ?Node.Index {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node).?;
        const callee = call.ast.fn_expr;
        const view = switch (tree.nodeTag(callee)) {
            .identifier => view: {
                const name = tree.tokenSlice(tree.nodeMainToken(callee));
                // Every function the file declares is a key.
                if (r.comptime_result_fns.contains(name)) return null;
                break :view std_view_fns.get(name) orelse return null;
            },
            .field_access => view: {
                const receiver, const field = tree.nodeData(callee).node_and_token;
                const view = std_view_fns.get(tree.tokenSlice(field)) orelse return null;
                const namespace = switch (tree.nodeTag(receiver)) {
                    .identifier => tree.tokenSlice(tree.nodeMainToken(receiver)),
                    .field_access => tree.tokenSlice(tree.nodeData(receiver).node_and_token[1]),
                    else => return null,
                };
                if (!std.mem.eql(u8, namespace, view.namespace)) return null;
                break :view view;
            },
            else => return null,
        };
        if (view.argument >= call.ast.params.len) return null;
        return call.ast.params[view.argument];
    }

    /// The first stack source among the expressions `node` can evaluate to,
    /// as `leaves` finds them.
    fn leafSource(r: *Rule, node: Node.Index, depth: u8) Allocator.Error!?Source {
        var values: std.ArrayList(Node.Index) = .empty;
        try r.leaves(node, &values);
        for (values.items) |value| if (try r.stackSource(value, depth)) |source| return source;
        return null;
    }

    /// `&operand`, with `amp` the `&` token.
    fn addressSource(r: *Rule, operand: Node.Index, amp: Ast.TokenIndex) Allocator.Error!?Source {
        const tree = r.tree;
        switch (tree.nodeTag(operand)) {
            .grouped_expression => return r.addressSource(tree.nodeData(operand).node_and_token[0], amp),
            .call_one, .call_one_comma, .call, .call_comma => {
                if (r.isComptime(operand)) return null;
                return .{ .token = amp, .what = "result of a call", .hint = r.storageHint(), .temporary = true };
            },
            .identifier => {
                const index = r.resolved.get(operand) orelse return null;
                if (r.isComptimeBinding(index)) return null;
                return try r.storageSource(amp, "address of", index);
            },
            // `&s.field` of a struct held by value, `&arr[i]` of an array.
            // One level only: in `&s.a.b`, `a` may be a pointer, and `.b`
            // would then reach through it to memory that is not `s`'s.
            .field_access, .array_access => {
                const by_field = tree.nodeTag(operand) == .field_access;
                const root = if (by_field) tree.nodeData(operand).node_and_token[0] else tree.nodeData(operand).node_and_node[0];
                if (tree.nodeTag(root) != .identifier) return null;
                const index = r.resolved.get(root) orelse return null;
                if (r.isComptimeBinding(index)) return null;
                if (r.bindings.items[index].storage != if (by_field) Storage.value else Storage.array) return null;
                return try r.storageSource(amp, if (by_field) "address of a field of" else "address of an element of", index);
            },
            else => {
                if (!isInit(tree.nodeTag(operand)) or r.isComptime(operand)) return null;
                return .{ .token = amp, .what = initWhat(tree, operand), .hint = hint_literal, .temporary = true };
            },
        }
    }

    /// `sliced[a..b]`.
    fn sliceSource(r: *Rule, sliced: Node.Index, depth: u8) Allocator.Error!?Source {
        const tree = r.tree;
        switch (tree.nodeTag(sliced)) {
            .grouped_expression => return r.sliceSource(tree.nodeData(sliced).node_and_token[0], depth),
            .identifier => if (r.resolved.get(sliced)) |index| {
                const binding = r.bindings.items[index];
                if (binding.storage == .array and !r.isComptimeBinding(index)) {
                    return try r.storageSource(tree.nodeMainToken(sliced), "slice of", index);
                }
            },
            else => if (isInit(tree.nodeTag(sliced)) and !r.isComptime(sliced)) return .{
                .token = tree.firstToken(sliced),
                .what = initWhat(tree, sliced),
                .hint = hint_literal,
                .temporary = true,
            },
        }
        // Slicing a pointer that is itself to the stack.
        return r.stackSource(sliced, depth);
    }

    fn storageSource(r: *Rule, token: Ast.TokenIndex, access: []const u8, index: u32) Allocator.Error!Source {
        const binding = r.bindings.items[index];
        const kind = switch (binding.kind) {
            .local => "local",
            .parameter => "parameter",
            .capture => "capture",
        };
        return .{
            .token = token,
            .what = try r.arena.print("{s} {s} '{s}'", .{ access, kind, binding.name }),
            .hint = r.storageHint(),
            .temporary = false,
        };
    }

    fn storageHint(r: *const Rule) []const u8 {
        return if (r.comptime_params) hint_storage_comptime else hint_storage;
    }

    fn isComptimeBinding(r: *Rule, index: u32) bool {
        const binding = r.bindings.items[index];
        if (binding.is_comptime) return true;
        if (binding.kind != .local or binding.mutable) return false;
        const init = binding.init.unwrap() orelse return false;
        return r.isComptime(init);
    }

    /// Whether `node`'s value is known at compile time, from the syntax
    /// alone. Anything not shown comptime-known here counts as runtime.
    fn isComptime(r: *Rule, node: Node.Index) bool {
        const tree = r.tree;
        const data = tree.nodeData(node);
        return switch (tree.nodeTag(node)) {
            .number_literal,
            .char_literal,
            .string_literal,
            .multiline_string_literal,
            .enum_literal,
            .error_value,
            .error_set_decl,
            .unreachable_literal,
            .anyframe_literal,
            .@"comptime",
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
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            .ptr_type_aligned,
            .ptr_type_sentinel,
            .ptr_type,
            .ptr_type_bit_range,
            .array_type,
            .array_type_sentinel,
            .optional_type,
            .error_union,
            .anyframe_type,
            .merge_error_sets,
            // `++` only accepts comptime-known operands.
            .array_cat,
            => true,

            .identifier => if (r.resolved.get(node)) |index| r.isComptimeBinding(index) else true,

            .field_access, .unwrap_optional, .grouped_expression => r.isComptime(data.node_and_token[0]),

            .bool_not, .negation, .bit_not, .negation_wrap, .address_of, .@"try", .deref => r.isComptime(data.node),

            .@"catch",
            .equal_equal,
            .bang_equal,
            .less_than,
            .greater_than,
            .less_or_equal,
            .greater_or_equal,
            .mul,
            .div,
            .mod,
            .mul_wrap,
            .mul_sat,
            .add,
            .sub,
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
            .array_access,
            => r.isComptime(data.node_and_node[0]) and r.isComptime(data.node_and_node[1]),

            .array_init_one,
            .array_init_one_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init,
            .array_init_comma,
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
                for (initValues(tree, &buffer, node)) |value| if (!r.isComptime(value)) return false;
                return true;
            },

            .slice_open, .slice, .slice_sentinel => {
                const slice = tree.fullSlice(node).?;
                if (!r.isComptime(slice.ast.sliced) or !r.isComptime(slice.ast.start)) return false;
                if (slice.ast.end.unwrap()) |end| if (!r.isComptime(end)) return false;
                if (slice.ast.sentinel.unwrap()) |sentinel| if (!r.isComptime(sentinel)) return false;
                return true;
            },

            .if_simple, .@"if" => {
                const full = tree.fullIf(node).?;
                if (full.payload_token != null or full.error_token != null) return false;
                if (!r.isComptime(full.ast.cond_expr) or !r.isComptime(full.ast.then_expr)) return false;
                return if (full.ast.else_expr.unwrap()) |e| r.isComptime(e) else true;
            },

            .@"switch", .switch_comma => {
                const full = tree.fullSwitch(node).?;
                if (!r.isComptime(full.ast.condition)) return false;
                for (full.ast.cases) |case_node| {
                    const case = tree.fullSwitchCase(case_node).?;
                    if (case.payload_token != null) return false;
                    for (case.ast.values) |value| if (!r.isComptime(value)) return false;
                    if (!r.isComptime(case.ast.target_expr)) return false;
                }
                return true;
            },

            .switch_range => r.isComptime(data.node_and_node[0]) and r.isComptime(data.node_and_node[1]),

            .call_one, .call_one_comma, .call, .call_comma => r.isComptimeCall(node),

            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                if (comptime_builtins.has(name)) return true;
                if (runtime_builtins.has(name)) return false;
                var buffer: [2]Node.Index = undefined;
                for (tree.builtinCallParams(&buffer, node).?) |param| if (!r.isComptime(param)) return false;
                return true;
            },

            else => false,
        };
    }

    /// A call is evaluated at run time, so its result is runtime, unless
    /// the callee is known to give a comptime-known result for
    /// comptime-known arguments (an `inline fn`, or one returning a
    /// comptime-only type) and every argument, receiver included, is
    /// comptime-known. Callees are known by name: the file's own functions,
    /// and a few from `std`.
    fn isComptimeCall(r: *Rule, node: Node.Index) bool {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node).?;
        const callee = call.ast.fn_expr;
        const name = switch (tree.nodeTag(callee)) {
            .identifier => tree.tokenSlice(tree.nodeMainToken(callee)),
            .field_access => name: {
                const receiver, const field = tree.nodeData(callee).node_and_token;
                if (!r.isComptime(receiver)) return false;
                break :name tree.tokenSlice(field);
            },
            else => return false,
        };
        const known = std_comptime_result_fns.has(name) or (r.comptime_result_fns.get(name) orelse false);
        if (!known) return false;
        for (call.ast.params) |param| if (!r.isComptime(param)) return false;
        return true;
    }
};

/// `std` functions whose result is comptime-known when their arguments are.
const std_comptime_result_fns: std.StaticStringMap(void) = .initComptime(.{
    .{"comptimePrint"}, .{"maxInt"}, .{"minInt"},
});

/// `std` functions whose result points into one of their arguments: the
/// namespace they are called through, and which argument.
const std_view_fns: std.StaticStringMap(ViewFn) = .initComptime(.{
    .{ "bufPrint", ViewFn{ .namespace = "fmt", .argument = 0 } },
    .{ "bufPrintSentinel", ViewFn{ .namespace = "fmt", .argument = 0 } },
    .{ "sliceTo", ViewFn{ .namespace = "mem", .argument = 0 } },
    .{ "span", ViewFn{ .namespace = "mem", .argument = 0 } },
    .{ "trim", ViewFn{ .namespace = "mem", .argument = 1 } },
    .{ "trimStart", ViewFn{ .namespace = "mem", .argument = 1 } },
    .{ "trimEnd", ViewFn{ .namespace = "mem", .argument = 1 } },
    .{ "cutPrefix", ViewFn{ .namespace = "mem", .argument = 1 } },
    .{ "cutSuffix", ViewFn{ .namespace = "mem", .argument = 1 } },
    .{ "asBytes", ViewFn{ .namespace = "mem", .argument = 0 } },
    .{ "sliceAsBytes", ViewFn{ .namespace = "mem", .argument = 0 } },
    .{ "bytesAsSlice", ViewFn{ .namespace = "mem", .argument = 1 } },
    .{ "bytesAsValue", ViewFn{ .namespace = "mem", .argument = 1 } },
});

const ViewFn = struct { namespace: []const u8, argument: usize };

/// An `inline fn`, whose result is comptime-known when its arguments are
/// and its body allows, or one returning a type only comptime has.
fn hasComptimeResult(tree: *const Ast, proto: Ast.full.FnProto) bool {
    if (proto.extern_export_inline_token) |t| {
        if (tree.tokenTag(t) == .keyword_inline) return true;
    }
    const return_type = proto.ast.return_type.unwrap() orelse return false;
    return isComptimeType(tree, return_type);
}

const Binding = struct {
    name: []const u8,
    kind: Kind,
    /// A `var`; a `const` local is comptime-known when its initializer is.
    mutable: bool,
    /// Declared comptime: a `comptime` parameter or one whose type is only
    /// known at compile time, a `comptime var`, an `inline` capture, or
    /// anything declared under `comptime`.
    is_comptime: bool,
    storage: Storage,
    /// A local's initializer.
    init: Node.OptionalIndex,

    const Kind = enum { local, parameter, capture };
};

/// What a binding's own memory holds, as far as the syntax shows: whether
/// `&x.field` and `x[a..b]` point into the binding or through it.
const Storage = enum { pointer, array, value, unknown };

const Store = struct {
    binding: u32,
    value: Node.Index,
};

const SinkSite = struct {
    value: Node.Index,
    sink: Sink,
    /// What a store writes to; null for `return`.
    target: ?Node.Index,
};

/// Builtins whose result is always known at compile time.
const comptime_builtins: std.StaticStringMap(void) = .initComptime(.{
    .{"@alignOf"},  .{"@bitOffsetOf"}, .{"@bitSizeOf"},  .{"@compileError"}, .{"@embedFile"},
    .{"@Enum"},     .{"@EnumLiteral"}, .{"@FieldType"},  .{"@Fn"},           .{"@hasDecl"},
    .{"@hasField"}, .{"@import"},      .{"@inComptime"}, .{"@Int"},          .{"@offsetOf"},
    .{"@Pointer"},  .{"@sizeOf"},      .{"@src"},        .{"@Struct"},       .{"@This"},
    .{"@Tuple"},    .{"@TypeOf"},      .{"@typeInfo"},   .{"@typeName"},     .{"@Union"},
    .{"@Vector"},
});

/// Builtins whose result is never known at compile time.
const runtime_builtins: std.StaticStringMap(void) = .initComptime(.{
    .{"@atomicLoad"},    .{"@atomicRmw"},     .{"@call"},           .{"@cmpxchgStrong"},    .{"@cmpxchgWeak"},
    .{"@cVaArg"},        .{"@cVaCopy"},       .{"@cVaStart"},       .{"@errorReturnTrace"}, .{"@extern"},
    .{"@frameAddress"},  .{"@returnAddress"}, .{"@wasmMemoryGrow"}, .{"@wasmMemorySize"},   .{"@workGroupId"},
    .{"@workGroupSize"}, .{"@workItemId"},
});

/// The operand of a cast that keeps the pointer it is given.
fn pointerPreservingOperand(tree: *const Ast, node: Node.Index) ?Node.Index {
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    const casts = [_][]const u8{ "@as", "@ptrCast", "@constCast", "@alignCast", "@volatileCast", "@addrSpaceCast" };
    for (casts) |cast| if (std.mem.eql(u8, name, cast)) {
        var buffer: [2]Node.Index = undefined;
        const params = tree.builtinCallParams(&buffer, node).?;
        return if (params.len == 0) null else params[params.len - 1];
    };
    return null;
}

fn isInit(tag: Node.Tag) bool {
    return switch (tag) {
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => true,
        else => false,
    };
}

/// The element or field values of an array or struct initializer. The
/// two-element forms are copied into `buffer`, so the result lives as long
/// as the caller's buffer does.
fn initValues(tree: *const Ast, buffer: *[2]Node.Index, node: Node.Index) []const Node.Index {
    if (tree.fullArrayInit(buffer, node)) |init| return init.ast.elements;
    if (tree.fullStructInit(buffer, node)) |init| return init.ast.fields;
    return &.{};
}

fn initWhat(tree: *const Ast, node: Node.Index) []const u8 {
    return switch (tree.nodeTag(node)) {
        .array_init_dot_two, .array_init_dot_two_comma, .array_init_dot, .array_init_dot_comma => "anonymous array",
        .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma => "anonymous struct",
        .array_init_one, .array_init_one_comma, .array_init, .array_init_comma => "array literal",
        else => "struct literal",
    };
}

fn blockLabel(tree: *const Ast, block: Node.Index) ?[]const u8 {
    const lbrace = tree.nodeMainToken(block);
    if (lbrace < 2 or tree.tokenTag(lbrace - 1) != .colon or tree.tokenTag(lbrace - 2) != .identifier) return null;
    return tree.tokenSlice(lbrace - 2);
}

/// A type only comptime has: `type`, `comptime_int`, `comptime_float`, or
/// a pointer, slice, array, optional or error union of one. A parameter or
/// local of one is comptime whether or not it says so, and a function
/// returning one runs only at compile time.
fn isComptimeType(tree: *const Ast, type_expr: Node.Index) bool {
    return switch (tree.nodeTag(type_expr)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(type_expr));
            return std.mem.eql(u8, name, "type") or std.mem.eql(u8, name, "comptime_int") or std.mem.eql(u8, name, "comptime_float");
        },
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => isComptimeType(tree, tree.fullPtrType(type_expr).?.ast.child_type),
        .array_type, .array_type_sentinel => isComptimeType(tree, tree.fullArrayType(type_expr).?.ast.elem_type),
        .optional_type => isComptimeType(tree, tree.nodeData(type_expr).node),
        .error_union => isComptimeType(tree, tree.nodeData(type_expr).node_and_node[1]),
        .grouped_expression => isComptimeType(tree, tree.nodeData(type_expr).node_and_token[0]),
        else => false,
    };
}

fn storageOfType(tree: *const Ast, type_expr: Node.Index) Storage {
    return switch (tree.nodeTag(type_expr)) {
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => .pointer,
        .optional_type => switch (tree.nodeTag(tree.nodeData(type_expr).node)) {
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => .pointer,
            else => .value,
        },
        .array_type, .array_type_sentinel => .array,
        .identifier, .field_access, .call_one, .call_one_comma, .call, .call_comma => .value,
        .builtin_call_two, .builtin_call_two_comma => .value,
        else => .unknown,
    };
}

fn storageOfLocal(tree: *const Ast, type_node: Node.OptionalIndex, init_node: Node.OptionalIndex) Storage {
    if (type_node.unwrap()) |t| return storageOfType(tree, t);
    const init = init_node.unwrap() orelse return .unknown;
    return switch (tree.nodeTag(init)) {
        .array_init_one, .array_init_one_comma, .array_init, .array_init_comma => .array,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => .value,
        .address_of, .slice_open, .slice, .slice_sentinel, .string_literal, .multiline_string_literal => .pointer,
        else => .unknown,
    };
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col what -> function through sink`, in source order.
fn expectEscapes(source: [:0]const u8, expected: []const u8) !void {
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
        const loc = report.location(tree.source, finding.offset);
        const e = finding.detail.escape;
        try out.writer.print("{d}:{d} {s} -> {s} through {s}\n", .{ loc.line + 1, loc.column + 1, e.what, e.function, e.sink.text() });
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "the measured shapes Zig 0.17.0 compiles without a diagnostic" {
    try expectEscapes(
        \\const Scope = enum { monitoring, fn url(s: Scope) []const u8 { _ = s; return "u"; } };
        \\fn a(scope: Scope) []const []const u8 { return &.{scope.url()}; }
        \\fn b() []const []const u8 { return &.{Scope.monitoring.url()}; }
        \\fn c(n: u8) []const u8 { var buf: [4]u8 = .{ 1, 2, 3, n }; return buf[0..2]; }
        \\fn d(n: u8) []const u8 { var x: u8 = n; return (&x)[0..1]; }
        \\fn e(n: u8) []const u8 { const arr = [_]u8{ n, n }; return &arr; }
        \\fn f(n: u8) []const u8 { return &[_]u8{ n, n }; }
        \\fn g(n: u8) []const u8 { return &.{ n, n }; }
        \\fn h(n: u8) []const u8 { return (&n)[0..1]; }
        \\fn i(n: u8) []const u8 { var buf: [4]u8 = .{ 1, 2, 3, n }; return &buf; }
    ,
        \\2:48 anonymous array -> a through return
        \\3:36 anonymous array -> b through return
        \\4:67 slice of local 'buf' -> c through return
        \\5:49 address of local 'x' -> d through return
        \\6:60 address of local 'arr' -> e through return
        \\7:33 array literal -> f through return
        \\8:33 anonymous array -> g through return
        \\9:34 address of parameter 'n' -> h through return
        \\10:67 address of local 'buf' -> i through return
        \\
    );
}

test "comptime-known memory is static and not reported" {
    try expectEscapes(
        \\const Scope = enum { monitoring, fn url(s: Scope) []const u8 { _ = s; return "u"; } };
        \\const kept = [_][]const u8{Scope.monitoring.url()};
        \\fn literal() []const []const u8 { return &.{"u"}; }
        \\fn constant() []const []const u8 { return &kept; }
        \\fn forced() []const []const u8 { return &.{comptime Scope.monitoring.url()}; }
        \\fn empty() []const u8 { return &.{}; }
        \\fn enums() []const Scope { return &.{ .monitoring, .monitoring }; }
        \\fn bytes() []const u8 { return &.{ 0x30, 'a', 1 + 2 }; }
        \\fn param(comptime n: u8) []const u8 { return &.{n}; }
        \\fn types(T: type) []const usize { return &.{ @sizeOf(T), @alignOf(T) }; }
        \\fn local() []const u8 { const n = 4; return &.{ n, n }; }
        \\fn sliced(comptime s: []const u8) []const u8 { const copy = s[0..s.len].*; return &copy; }
        \\fn chosen() []const u8 { return &.{switch (@import("builtin").os.tag) { .linux => 1, else => 2 }}; }
        \\inline fn twice(comptime n: u8) [2]u8 { return .{ n, n }; }
        \\fn inlined() []const u8 { return &twice(3); }
        \\fn printed(comptime n: u8) []const []const u8 { return &.{@import("std").fmt.comptimePrint("{d}", .{n})}; }
        \\fn max() []const u8 { return &.{@import("std").math.maxInt(u8)}; }
    , "");
}

test "the real bug, and the same escape through every expression that yields a value" {
    try expectEscapes(
        \\const Scope = enum { monitoring, logging, fn url(s: Scope) []const u8 { _ = s; return "u"; } };
        \\fn scopesFor(scope: Scope, asked: []const []const u8) []const []const u8 {
        \\    return if (scope == .monitoring) &.{Scope.monitoring.url()} else asked;
        \\}
        \\fn viaSwitch(s: Scope, asked: []const []const u8) []const []const u8 {
        \\    return switch (s) { .monitoring => &.{s.url()}, .logging => asked };
        \\}
        \\fn viaOrelse(o: ?[]const []const u8, s: Scope) []const []const u8 { return o orelse &.{s.url()}; }
        \\fn viaCatch(e: anyerror![]const []const u8, s: Scope) []const []const u8 { return e catch &.{s.url()}; }
        \\fn viaTry(e: anyerror![]const []const u8, s: Scope) ![]const []const u8 { _ = try e; return &.{s.url()}; }
        \\fn viaBlock(s: Scope) []const []const u8 { return blk: { if (s == .logging) break :blk &.{}; break :blk &.{s.url()}; }; }
        \\fn viaAlias(s: Scope) []const []const u8 { const x = &.{s.url()}; return x; }
        \\fn viaVar(s: Scope, asked: []const []const u8) []const []const u8 {
        \\    var result = asked;
        \\    if (s == .logging) result = &.{s.url()};
        \\    return result;
        \\}
        \\fn viaCast(s: Scope) []const []const u8 { return @as([]const []const u8, &.{s.url()}); }
        \\fn viaStruct(s: Scope) struct { items: []const []const u8 } { return .{ .items = &.{s.url()} }; }
    ,
        \\3:38 anonymous array -> scopesFor through return
        \\6:40 anonymous array -> viaSwitch through return
        \\8:85 anonymous array -> viaOrelse through return
        \\9:91 anonymous array -> viaCatch through return
        \\10:93 anonymous array -> viaTry through return
        \\11:105 anonymous array -> viaBlock through return
        \\12:54 anonymous array -> viaAlias through return
        \\15:33 anonymous array -> viaVar through return
        \\18:74 anonymous array -> viaCast through return
        \\19:82 anonymous array -> viaStruct through return
        \\
    );
}

test "stores: a temporary is reported, a named local or a store a defer undoes is not" {
    try expectEscapes(
        \\var global: []const u8 = &.{};
        \\const Holder = struct {
        \\    items: []const u8,
        \\    current: ?*const u8 = null,
        \\    fn set(self: *Holder, n: u8) void { self.items = &.{n}; }
        \\    fn out(dest: *[]const u8, n: u8) void { dest.* = &.{n}; }
        \\    fn named(self: *Holder, n: u8) void { self.current = &n; }
        \\    fn scoped(self: *Holder, n: u8) void { self.items = &.{n}; defer self.items = &.{}; }
        \\    fn scopedBlock(self: *Holder, n: u8) void { self.items = &.{n}; defer { self.items = &.{}; } }
        \\};
        \\fn toGlobal(n: u8) void { global = &.{n}; }
        \\fn discard(n: u8) void { _ = &.{n}; }
    ,
        \\5:54 anonymous array -> set through field
        \\6:54 anonymous array -> out through out param
        \\11:36 anonymous array -> toGlobal through global
        \\
    );
}

test "parameters, captures and fields" {
    try expectEscapes(
        \\const S = struct {
        \\    buf: [4]u8,
        \\    inner: *S,
        \\    fn byValue(self: S) []const u8 { return &self.buf; }
        \\    fn byPointer(self: *const S) []const u8 { return &self.buf; }
        \\    fn throughPointerField(self: S) []const u8 { return &self.inner.buf; }
        \\};
        \\fn capture(o: ?u8) []const u8 { if (o) |v| return (&v)[0..1]; return &.{}; }
        \\fn pointerCapture(o: *?[4]u8) []const u8 { if (o.*) |*v| return v; return &.{}; }
        \\fn inlined() []const u8 { inline for (.{ 1, 2 }) |v| return &.{v}; }
        \\fn element(n: u8) *const u8 { const arr = [_]u8{ n, n }; return &arr[0]; }
    ,
        \\4:45 address of a field of parameter 'self' -> byValue through return
        \\8:52 address of capture 'v' -> capture through return
        \\11:65 address of an element of local 'arr' -> element through return
        \\
    );
}

test "calls: a temporary result is reported, reading a slice in the same function is not" {
    try expectEscapes(
        \\const Key = struct { b: [4]u8, fn toBytes(k: Key) [4]u8 { return k.b; } };
        \\fn rawOf(k: *const Key) []const u8 { return &k.toBytes(); }
        \\fn readTopics(n: u8) bool { const s: []const u8 = &.{n}; return eql(s, "a"); }
        \\fn passed(n: u8) bool { return eql(&.{n}, "a"); }
        \\fn eql(a: []const u8, b: []const u8) bool { return a.len == b.len; }
    ,
        \\2:45 result of a call -> rawOf through return
        \\
    );
}

test "a function returning a type only comptime has runs only at compile time" {
    try expectEscapes(
        \\fn reversed(comptime ts: []const type) []const type { var a: [ts.len]type = ts[0..ts.len].*; const f = a; return &f; }
        \\fn widths(ts: []const type) []const comptime_int { var a: [ts.len]comptime_int = undefined; const f = a; return &f; }
        \\fn first(comptime n: usize) ?*const [n]type { var a: [n]type = undefined; return &a; }
        \\fn named(comptime n: usize) anyerror![n]type { var a: [n]type = undefined; return a; }
        \\fn sizes(comptime ts: []const type) []const usize { var a: [ts.len]usize = undefined; const f = a; return &f; }
    ,
        \\5:107 address of local 'f' -> sizes through return
        \\
    );
}

test "a parameter or local of a type only comptime has is comptime" {
    try expectEscapes(
        \\const other = @import("other.zig");
        \\fn fromParam(ts: []const type) []const usize { return &.{ts.len}; }
        \\fn fromLocal() []const usize { const ts: [2]type = other.pair(); return &.{ts.len}; }
        \\fn fromRuntime() []const usize { const n: usize = other.count(); return &.{n}; }
    ,
        \\4:73 anonymous array -> fromRuntime through return
        \\
    );
}

test "the storage hint names the comptime fix in a function with a comptime parameter" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\fn table(comptime T: type) []const usize { var a: [1]usize = undefined; a[0] = @sizeOf(T); const f = a; return &f; }
        \\fn typed(T: type, n: u8) []const u8 { _ = T; var a: [1]u8 = undefined; a[0] = n; const f = a; return &f; }
        \\fn runtime(n: usize) []const usize { var a: [1]usize = undefined; a[0] = n; const f = a; return &f; }
        \\fn literal(comptime n: u8, m: u8) []const u8 { return &.{ n, m }; }
    , .{});
    defer tree.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var findings: std.ArrayList(Finding) = .empty;
    try check(arena_state.allocator(), &tree, &findings);
    std.mem.sort(Finding, findings.items, {}, struct {
        fn before(_: void, a: Finding, b: Finding) bool {
            return a.offset < b.offset;
        }
    }.before);
    const expected = [_][]const u8{ hint_storage_comptime, hint_storage_comptime, hint_storage, hint_literal };
    try std.testing.expectEqual(expected.len, findings.items.len);
    for (expected, findings.items) |hint, finding| try std.testing.expectEqualStrings(hint, finding.hint);
}

test "through a std call that returns a view of an argument" {
    try expectEscapes(
        \\const std = @import("std");
        \\const fmt = std.fmt;
        \\fn label(id: u32) []const u8 { var buf: [32]u8 = undefined; return std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable; }
        \\fn aliased(id: u32) ![]const u8 { var buf: [32]u8 = undefined; return try fmt.bufPrint(&buf, "{d}", .{id}); }
        \\fn viaLocal(id: u32) []const u8 { var buf: [32]u8 = undefined; const s = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable; return s; }
        \\fn stored(h: *H, id: u32) void { var buf: [32]u8 = undefined; h.s = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable; }
        \\fn method(t: Text, n: u8) []const u8 { var buf: [4]u8 = .{ n, n, n, n }; return t.trim(u8, &buf, " "); }
        \\fn ofParameter(s: []const u8) []const u8 { return std.mem.trim(u8, s, " "); }
    ,
        \\3:85 address of local 'buf' -> label through return
        \\4:88 address of local 'buf' -> aliased through return
        \\5:91 address of local 'buf' -> viaLocal through return
        \\
    );
}

test "a file's own function is not taken for the std one of the same name" {
    try expectEscapes(
        \\fn sliceTo(a: *const [4]u8, end: u8) []const u8 { _ = a; _ = end; return "fixed"; }
        \\fn own(n: u8) []const u8 { var buf: [4]u8 = .{ n, n, n, n }; return sliceTo(&buf, 0); }
    , "");
}

test "comptime contexts and nested declarations" {
    try expectEscapes(
        \\fn f(n: u8) []const u8 {
        \\    const S = struct {
        \\        fn inner(m: u8) []const u8 { return &.{m}; }
        \\        const table = &.{ 1, 2 };
        \\    };
        \\    _ = S;
        \\    const c = comptime blk: { var x: u8 = 1; x += 1; break :blk &.{x}; };
        \\    _ = c;
        \\    return &.{n};
        \\}
    ,
        \\3:45 anonymous array -> inner through return
        \\9:12 anonymous array -> f through return
        \\
    );
}
