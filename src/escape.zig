//! Rule one, escape: a pointer or slice into stack memory that leaves the
//! function that made it.
//!
//! Each function is checked in two passes. The first walks the body with a
//! scope chain, resolving every identifier to the parameter, local or
//! capture it names, and collecting the sinks: `return`, a store through a
//! parameter, and a store to a container-level variable. The second follows
//! each sink's value back through `if`, `switch`, `orelse`, `catch`, labeled
//! blocks, locals, the elements and fields of a local made with an
//! initializer, the `std` calls that return a view of an argument
//! (`std.fmt.bufPrint`, `std.mem.sliceTo`, ...) and the file's own functions
//! that return part of what a pointer parameter points at, and reports a
//! value that is the address or a slice of stack memory whose contents are
//! not comptime-known.
//!
//! A struct's field is known to be an array when the file declares the
//! struct: a type is resolved by name through the containers around where it
//! is written (`Id`, `Self`, `@This()`), never across files. So
//! `id.bytes[0..n]` of an `id: Id` held by value is reported when `bytes` is
//! `[8]u8`, and not when it is a slice, which points elsewhere. Fields held
//! by value are followed as deep as the file's types show them
//! (`t.name.bytes`), and a `for` loop's capture held by value has the type
//! of an element of its input, when the file writes that input's type.
//!
//! Comptime-known memory is static, so `&.{"literal"}` is fine and
//! `&.{f()}` is not: a call is evaluated at run time unless it is under
//! `comptime`, or the callee is an `inline fn` (or returns a comptime-only
//! type) given comptime-known arguments. A function that only ever runs at
//! compile time is not checked: one returning a comptime-only type, one
//! with a `var` only comptime allows (`var count = 0;`), and one the file
//! uses at least once and only ever calls at compile time, under
//! `comptime`, in container-level code or from another such function. The
//! one accepted false positive is any other function only ever called at
//! compile time, such as one called from another file; it can say
//! `comptime`, or carry an allow comment.
//!
//! Returned, any stack address is reported. Stored through a parameter or
//! to a container-level variable, only a temporary (`&.{...}`, `&f()`) is:
//! a named local stored outward is usually deliberate and bounded by the
//! call, and a store a `defer` undoes is not reported at all. A capture held
//! by value in a loop is the exception: it is a copy made for one turn, so
//! what points into it is reported stored outward, and stored to a local
//! declared outside the loop. A store through a pointer capture is a store
//! into what its loop or `if` walks.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const Sink = report.Sink;
const types = @import("types.zig");
const Types = types.Types;
const elementOf = types.elementOf;
const fieldType = types.fieldType;
const memberFn = types.memberFn;
const pointee = types.pointee;

/// Appends a finding for every escape in `tree`. Everything, findings
/// included, is allocated with `arena`, which must outlive the findings.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings, .types = try .init(arena, tree) };
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
        if (tree.nodeTag(node) != .fn_decl) continue;
        const before = findings.items.len;
        try rule.function(node);
        // Asked only of a function that made a finding, as most make none.
        if (findings.items.len > before and try rule.compileTime(node)) findings.shrinkRetainingCapacity(before);
    }
}

/// Whether `body` declares a `var` only comptime allows: an untyped number
/// (`var count = 0;`) is a comptime_int, which only comptime lets change.
fn countsAtComptime(arena: Allocator, tree: *const Ast, body: Node.Index) Allocator.Error!bool {
    var stack: std.ArrayList(Node.Index) = .empty;
    try stack.append(arena, body);
    while (stack.pop()) |node| {
        if (tree.nodeTag(node) == .fn_decl) continue;
        var buffer: [2]Node.Index = undefined;
        if (tree.fullContainerDecl(&buffer, node) != null) continue;
        if (tree.fullVarDecl(node)) |decl| {
            if (tree.tokenTag(decl.ast.mut_token) == .keyword_var and decl.comptime_token == null and decl.ast.type_node == .none) {
                if (decl.ast.init_node.unwrap()) |init| {
                    const literal = if (tree.nodeTag(init) == .negation) tree.nodeData(init).node else init;
                    if (tree.nodeTag(literal) == .number_literal) return true;
                }
            }
        }
        try children.append(arena, tree, node, &stack);
    }
    return false;
}

const hint_literal = "make it comptime-known (`comptime` on the runtime elements) or a container-level const";
const hint_storage = "return the value itself, have the caller pass in the memory, or allocate it";
const hint_storage_comptime = hint_storage ++ "; if it only runs at compile time, say so with `return comptime blk: { ... }`";
const hint_turn = "copy what it points at, or use it only within the turn";

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
    /// The structs and unions the file declares, by where a type is named.
    types: Types,
    /// Whether each of the file's functions asked about only ever runs at
    /// compile time; null while it is being decided.
    compile_time: std.AutoHashMapUnmanaged(Node.Index, ?bool) = .empty,
    /// The file's functions by name, and every node naming one, made at the
    /// first question.
    fns_by_name: std.StringHashMapUnmanaged(std.ArrayList(Node.Index)) = .empty,
    uses_by_name: std.StringHashMapUnmanaged(std.ArrayList(Node.Index)) = .empty,
    /// The file's functions looked at so far, to which parameter their
    /// result points into (`viewOf`).
    views: std.AutoHashMapUnmanaged(Node.Index, ?u32) = .empty,

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

    /// Whether `fn_decl` only ever runs at compile time, so what it returns
    /// is comptime memory: it returns a type only comptime has, has a `var`
    /// only comptime allows (`var count = 0;`), or is used in the file at
    /// least once and only ever as the callee of a call made at compile
    /// time: under `comptime`, in container-level code (`pub const entries
    /// = entriesArray();`), or in a function that only runs then. One the
    /// file never calls, names without calling (`&f`), or exports may be
    /// called at run time from elsewhere.
    fn compileTime(r: *Rule, fn_decl: Node.Index) Allocator.Error!bool {
        const gop = try r.compile_time.getOrPut(r.arena, fn_decl);
        // Still being decided: calls that go round in a cycle show nothing.
        if (gop.found_existing) return gop.value_ptr.* orelse false;
        gop.value_ptr.* = null;
        const yes = try r.decideCompileTime(fn_decl);
        try r.compile_time.put(r.arena, fn_decl, yes);
        return yes;
    }

    fn decideCompileTime(r: *Rule, fn_decl: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        const proto_node, const body = tree.nodeData(fn_decl).node_and_node;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, proto_node).?;
        if (proto.ast.return_type.unwrap()) |t| if (isComptimeType(tree, t)) return true;
        if (proto.extern_export_inline_token) |t| if (tree.tokenTag(t) == .keyword_export) return false;
        if (try countsAtComptime(r.arena, tree, body)) return true;
        const name = tree.tokenSlice(proto.name_token orelse return false);
        if (r.fns_by_name.count() == 0) try r.indexFunctions();
        const fns = r.fns_by_name.get(name).?.items;
        const uses = r.uses_by_name.get(name) orelse return false;
        for (uses.items) |use| {
            if (!try r.calledAtCompileTime(use, fns)) return false;
        }
        return true;
    }

    /// The file's functions by name, and every node that names one of them,
    /// called or not.
    fn indexFunctions(r: *Rule) Allocator.Error!void {
        const tree = r.tree;
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @fromBackingInt(@intCast(i));
            if (tree.nodeTag(node) != .fn_decl) continue;
            var buffer: [1]Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]).?;
            const gop = try r.fns_by_name.getOrPut(r.arena, tree.tokenSlice(proto.name_token orelse continue));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(r.arena, node);
        }
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @fromBackingInt(@intCast(i));
            const name = switch (tree.nodeTag(node)) {
                .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
                .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
                else => continue,
            };
            if (!r.fns_by_name.contains(name)) continue;
            const gop = try r.uses_by_name.getOrPut(r.arena, name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(r.arena, node);
        }
    }

    /// Whether `use`, naming one of `fns`, is the callee of a call made at
    /// compile time. A call from within one of `fns` runs when they do.
    fn calledAtCompileTime(r: *Rule, use: Node.Index, fns: []const Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        const parents = r.types.parents;
        const call_node = parents[@backingInt(use)].unwrap() orelse return false;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, call_node) orelse return false;
        if (call.ast.fn_expr != use) return false;
        var up = parents[@backingInt(call_node)].unwrap();
        while (up) |node| : (up = parents[@backingInt(node)].unwrap()) {
            switch (tree.nodeTag(node)) {
                .@"comptime" => return true,
                .fn_decl => return std.mem.findScalar(Node.Index, fns, node) != null or try r.compileTime(node),
                .test_decl => return false,
                else => {
                    // Container-level code, such as a declaration's value.
                    var container: [2]Node.Index = undefined;
                    if (tree.fullContainerDecl(&container, node) != null) return true;
                },
            }
        }
        return true;
    }

    fn function(r: *Rule, fn_decl: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        const proto_node, const body = tree.nodeData(fn_decl).node_and_node;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, proto_node).?;

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
                .type_expr = .fromOptional(param.type_expr),
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
                switch (site.sink) {
                    .@"return" => {},
                    // Only a loop's capture is gone before the local is,
                    // and only when the capture is declared after it, so
                    // that its loop runs inside the local's scope.
                    .outer_local => {
                        const capture = source.capture orelse continue;
                        if (capture < site.local.?) continue;
                    },
                    // A named local stored outward is often deliberate: a
                    // context pointer for the length of a call, a thread's
                    // `current`, `argv` just before `execve`. A temporary
                    // stored outward never is, nor a loop's capture, which
                    // the next turn writes over. Returned, all are wrong.
                    else => if (!source.temporary and source.capture == null) continue,
                }
                const gop = try r.reported.getOrPut(r.arena, .{ source.token, site.sink });
                if (gop.found_existing) continue;
                try r.findings.append(r.arena, .{
                    .offset = tree.tokenStart(source.token),
                    .hint = if (source.capture) |capture| try r.captureHint(capture, site.sink, source.hint) else source.hint,
                    .detail = .{ .escape = .{
                        .what = source.what,
                        .function = r.function_name,
                        .sink = site.sink,
                        .local = if (site.local) |local| r.bindings.items[local].name else "",
                    } },
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
                    .type_expr = typeOfLocal(tree, decl.ast.type_node, decl.ast.init_node),
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
                if (full.payload_token) |t| try r.declareCaptures(t, false, &.{full.ast.cond_expr}, .none);
                try r.walk(full.ast.then_expr);
                r.scope.shrinkRetainingCapacity(outer);
                if (full.ast.else_expr.unwrap()) |else_expr| {
                    if (full.error_token) |t| try r.declareCaptures(t, false, &.{}, .none);
                    try r.walk(else_expr);
                    r.scope.shrinkRetainingCapacity(outer);
                }
            },

            .while_simple, .while_cont, .@"while" => {
                const full = tree.fullWhile(node).?;
                try r.walk(full.ast.cond_expr);
                const outer = r.scope.items.len;
                if (full.payload_token) |t| try r.declareCaptures(t, full.inline_token != null, &.{full.ast.cond_expr}, .@"while");
                if (full.ast.cont_expr.unwrap()) |cont| try r.walk(cont);
                try r.walk(full.ast.then_expr);
                r.scope.shrinkRetainingCapacity(outer);
                if (full.ast.else_expr.unwrap()) |else_expr| {
                    if (full.error_token) |t| try r.declareCaptures(t, false, &.{}, .none);
                    try r.walk(else_expr);
                    r.scope.shrinkRetainingCapacity(outer);
                }
            },

            .for_simple, .@"for" => {
                const full = tree.fullFor(node).?;
                for (full.ast.inputs) |input| try r.walk(input);
                const outer = r.scope.items.len;
                try r.declareCaptures(full.payload_token, full.inline_token != null, full.ast.inputs, .@"for");
                try r.walk(full.ast.then_expr);
                r.scope.shrinkRetainingCapacity(outer);
                if (full.ast.else_expr.unwrap()) |else_expr| try r.walk(else_expr);
            },

            .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {
                const full = tree.fullSwitchCase(node).?;
                for (full.ast.values) |value| try r.walk(value);
                const outer = r.scope.items.len;
                if (full.payload_token) |t| try r.declareCaptures(t, full.inline_token != null, &.{}, .none);
                try r.walk(full.ast.target_expr);
                r.scope.shrinkRetainingCapacity(outer);
            },

            .@"catch" => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                try r.walk(lhs);
                const outer = r.scope.items.len;
                const catch_token = tree.nodeMainToken(node);
                if (tree.tokenTag(catch_token + 1) == .pipe) try r.declareCaptures(catch_token + 2, false, &.{}, .none);
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
    /// `inputs` are what the captures are taken from, in order: a `for`
    /// loop's inputs, or the condition of an `if` or `while`. A capture
    /// held by value in a loop is a copy made for each turn, and in a `for`
    /// loop it has the type of an element of its input, when the file
    /// shows it.
    fn declareCaptures(r: *Rule, first: Ast.TokenIndex, is_comptime: bool, inputs: []const Node.Index, loop: Loop) Allocator.Error!void {
        const tree = r.tree;
        var token = first;
        var i: usize = 0;
        while (true) : (i += 1) {
            const by_pointer = tree.tokenTag(token) == .asterisk;
            if (by_pointer) token += 1;
            if (tree.tokenTag(token) != .identifier) return;
            const name = tree.tokenSlice(token);
            const input: ?Node.Index = if (i < inputs.len) inputs[i] else null;
            const element: ?Node.Index = if (loop != .@"for" or by_pointer) null else if (input) |n| r.elementType(n) else null;
            if (!std.mem.eql(u8, name, "_")) try r.declare(.{
                .name = name,
                .kind = .capture,
                .mutable = false,
                .is_comptime = is_comptime,
                .storage = if (by_pointer) .pointer else if (element) |t| storageOfType(tree, t) else .unknown,
                .type_expr = .fromOptional(element),
                .init = .fromOptional(input),
                .per_turn = loop != .none and !by_pointer,
            });
            token += 1;
            if (tree.tokenTag(token) != .comma) return;
            token += 1;
        }
    }

    /// Records `lhs = rhs` as a sink when `lhs` is memory outside the
    /// function or a local that outlives a loop's capture in scope, and as
    /// a store to a local for following aliases.
    fn assignment(r: *Rule, node: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        var root, const through_field = rootOf(tree, lhs);
        if (tree.nodeTag(root) != .identifier) return;
        const whole = root == lhs;
        // A pointer capture points into what its loop or `if` walks, so a
        // store through it is a store into that.
        var hops: u8 = 0;
        while (r.resolved.get(root)) |index| : (hops += 1) {
            const binding = r.bindings.items[index];
            if (binding.kind != .capture or binding.storage != .pointer or hops == 4) break;
            root = rootOf(tree, binding.init.unwrap() orelse return)[0];
            if (tree.nodeTag(root) != .identifier) return;
        }

        const index = r.resolved.get(root) orelse {
            // `_ = x` discards; any other name not in scope is a
            // container-level variable.
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(root)), "_")) return;
            return r.sinks.append(r.arena, .{ .value = rhs, .sink = .global, .target = lhs });
        };
        switch (r.bindings.items[index].kind) {
            // Parameters are immutable, so a store through one goes through
            // a pointer the caller passed in.
            .parameter => if (!whole) try r.sinks.append(r.arena, .{
                .value = rhs,
                .sink = if (through_field) .field else .out_param,
                .target = lhs,
            }),
            .local => {
                if (whole) try r.stores.append(r.arena, .{ .binding = index, .value = rhs });
                if (r.capturedSince(index)) try r.sinks.append(r.arena, .{
                    .value = rhs,
                    .sink = .outer_local,
                    .target = lhs,
                    .local = index,
                });
            },
            .capture => {},
        }
    }

    /// Whether a capture held by value in a loop, declared after binding
    /// `index`, is in scope: a store to `index` from there outlives the
    /// capture's turn.
    fn capturedSince(r: *const Rule, index: u32) bool {
        // Scope holds binding indices in the order they were declared.
        var i = r.scope.items.len;
        while (i > 0) {
            i -= 1;
            const later = r.scope.items[i];
            if (later <= index) return false;
            if (r.bindings.items[later].per_turn) return true;
        }
        return false;
    }

    /// The type of an element of a `for` loop's input, when the file shows
    /// it: `xs`, `&xs` or `xs[a..b]`, with `xs` an array, a slice or a
    /// pointer to an array, a binding or a field of a struct the file
    /// declares (`self.items`).
    fn elementType(r: *Rule, input: Node.Index) ?Node.Index {
        const tree = r.tree;
        return switch (tree.nodeTag(input)) {
            .grouped_expression => r.elementType(tree.nodeData(input).node_and_token[0]),
            .address_of => r.elementType(tree.nodeData(input).node),
            .slice_open, .slice, .slice_sentinel => r.elementType(tree.fullSlice(input).?.ast.sliced),
            else => elementOf(tree, r.typeOf(input, 0) orelse return null),
        };
    }

    /// The type of `node` as the file writes it: a binding's, or a field's
    /// reached from one through structs the file declares, held by value
    /// or through a pointer (`self.items`).
    fn typeOf(r: *Rule, node: Node.Index, depth: u8) ?Node.Index {
        const tree = r.tree;
        if (depth > 8) return null;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return r.typeOf(tree.nodeData(node).node_and_token[0], depth + 1),
            .identifier => return r.bindings.items[r.resolved.get(node) orelse return null].type_expr.unwrap(),
            .field_access => {
                const lhs, const field = tree.nodeData(node).node_and_token;
                const outer = r.typeOf(lhs, depth + 1) orelse return null;
                const container = r.types.containerOf(pointee(tree, outer) orelse outer, 0) orelse return null;
                return fieldType(tree, container, tree.tokenSlice(field));
            },
            else => return null,
        }
    }

    /// A place in a binding's own memory.
    const Place = struct {
        binding: u32,
        /// The binding's name where the place starts, for a report.
        root: Node.Index,
        /// A field of the binding, not the binding itself.
        field: bool,
        storage: Storage,
        type_expr: Node.OptionalIndex,
    };

    /// `node` as a place in a binding's own memory, reached without going
    /// through a pointer: the binding, or a field of one held by value, as
    /// deep as the file's types show it (`t.name` with `t: Topic` and
    /// `name: Name` declared in `Topic`).
    fn place(r: *Rule, node: Node.Index, depth: u8) ?Place {
        const tree = r.tree;
        if (depth > 8) return null;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return r.place(tree.nodeData(node).node_and_token[0], depth + 1),
            .identifier => {
                const index = r.resolved.get(node) orelse return null;
                const binding = r.bindings.items[index];
                return .{ .binding = index, .root = node, .field = false, .storage = binding.storage, .type_expr = binding.type_expr };
            },
            .field_access => {
                const lhs, const field = tree.nodeData(node).node_and_token;
                const outer = r.place(lhs, depth + 1) orelse return null;
                if (outer.storage != .value) return null;
                const container = r.types.containerOf(outer.type_expr.unwrap() orelse return null, 0) orelse return null;
                const field_type = fieldType(tree, container, tree.tokenSlice(field)) orelse return null;
                return .{
                    .binding = outer.binding,
                    .root = outer.root,
                    .field = true,
                    .storage = storageOfType(tree, field_type),
                    .type_expr = field_type.toOptional(),
                };
            },
            else => return null,
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
        /// The capture held by value in a loop that it points into: a copy
        /// the next turn writes over.
        capture: ?u32 = null,
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
            // `slice.ptr` points where the slice does; another field of a
            // local made with an initializer holds what it was given.
            .field_access => {
                const lhs, const field = tree.nodeData(node).node_and_token;
                const name = tree.tokenSlice(field);
                if (std.mem.eql(u8, name, "ptr")) return r.stackSource(lhs, depth);
                return r.heldSource(lhs, .{ .field = name }, depth);
            },
            // An element of a local array made with an initializer.
            .array_access => {
                const lhs, const index = tree.nodeData(node).node_and_node;
                const at: ?usize = if (tree.nodeTag(index) == .number_literal)
                    std.fmt.parseInt(usize, tree.tokenSlice(tree.nodeMainToken(index)), 0) catch null
                else
                    null;
                return r.heldSource(lhs, .{ .element = at }, depth);
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
                if (r.viewedArgument(node)) |argument| return r.stackSource(argument, depth);
                return r.ownViewSource(node, depth);
            },
            else => null,
        };
    }

    /// What is read out of a local made with an initializer, an element
    /// (`whole[i]` of `const whole = [_][]const T{ &.{}, &.{.{ .end = n }} };`)
    /// or a field (`s.all` of `const s = .{ .all = &[_]T{...} };`): what
    /// that element or field was given, there or in a store of the whole
    /// local. An index the syntax does not give picks any element.
    fn heldSource(r: *Rule, holder: Node.Index, read: union(enum) { element: ?usize, field: []const u8 }, depth: u8) Allocator.Error!?Source {
        const tree = r.tree;
        var h = holder;
        while (tree.nodeTag(h) == .grouped_expression) h = tree.nodeData(h).node_and_token[0];
        if (tree.nodeTag(h) != .identifier) return null;
        const index = r.resolved.get(h) orelse return null;
        const binding = r.bindings.items[index];
        if (binding.kind != .local or binding.is_comptime) return null;
        var made: std.ArrayList(Node.Index) = .empty;
        if (binding.init.unwrap()) |init| try made.append(r.arena, init);
        for (r.stores.items) |store| if (store.binding == index) try made.append(r.arena, store.value);
        for (made.items) |value| {
            var init = value;
            while (tree.nodeTag(init) == .grouped_expression) init = tree.nodeData(init).node_and_token[0];
            var buffer: [2]Node.Index = undefined;
            switch (read) {
                .element => |at| {
                    const elements = (tree.fullArrayInit(&buffer, init) orelse continue).ast.elements;
                    if (at) |i| {
                        if (i >= elements.len) continue;
                        if (try r.leafSource(elements[i], depth + 1)) |source| return source;
                    } else for (elements) |element| {
                        if (try r.leafSource(element, depth + 1)) |source| return source;
                    }
                },
                .field => |name| for ((tree.fullStructInit(&buffer, init) orelse continue).ast.fields) |value_node| {
                    // A field's value follows its `.name =`.
                    if (!std.mem.eql(u8, tree.tokenSlice(tree.firstToken(value_node) - 2), name)) continue;
                    if (try r.leafSource(value_node, depth + 1)) |source| return source;
                },
            }
        }
        return null;
    }

    /// A call to one of the file's own functions whose result points into
    /// what a pointer parameter points at (`viewOf`): where that pointer
    /// comes from. A method called on a binding is given the binding's
    /// address when it takes a pointer, so `id.slice()` points into `id`
    /// when `id` is held by value, and wherever `id` points when it is a
    /// pointer.
    fn ownViewSource(r: *Rule, node: Node.Index, depth: u8) Allocator.Error!?Source {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node).?;
        const callee = call.ast.fn_expr;
        const arguments = call.ast.params;
        switch (tree.nodeTag(callee)) {
            .identifier => {
                if (r.resolved.contains(callee)) return null;
                const fn_decl = r.types.declaredFn(callee, tree.tokenSlice(tree.nodeMainToken(callee))) orelse return null;
                const view = try r.viewOf(fn_decl) orelse return null;
                return if (view < arguments.len) r.stackSource(arguments[view], depth) else null;
            },
            .field_access => {
                const receiver, const name_token = tree.nodeData(callee).node_and_token;
                const name = tree.tokenSlice(name_token);
                // A method: the receiver, a binding or a field of one held
                // by value (`t.name.slice()`), is its first argument.
                const p = r.place(receiver, 0) orelse {
                    // `Id.slice(&id)`, through the type's namespace.
                    const container = r.types.containerOf(receiver, 0) orelse return null;
                    const fn_decl = memberFn(tree, container, name) orelse return null;
                    const view = try r.viewOf(fn_decl) orelse return null;
                    return if (view < arguments.len) r.stackSource(arguments[view], depth) else null;
                };
                const type_expr = p.type_expr.unwrap() orelse return null;
                const value_type = switch (p.storage) {
                    .value => type_expr,
                    .pointer => pointee(tree, type_expr) orelse return null,
                    .array, .unknown => return null,
                };
                const container = r.types.containerOf(value_type, 0) orelse return null;
                const fn_decl = memberFn(tree, container, name) orelse return null;
                const view = try r.viewOf(fn_decl) orelse return null;
                if (view > 0) return if (view - 1 < arguments.len) r.stackSource(arguments[view - 1], depth) else null;
                // A pointer field points where nothing here shows.
                if (p.storage == .pointer) return if (p.field) null else r.stackSource(receiver, depth);
                if (r.isComptimeBinding(p.binding)) return null;
                return try r.storageSource(tree.nodeMainToken(p.root), if (p.field) "address of a field of" else "address of", p.binding);
            },
            else => return null,
        }
    }

    /// Which parameter of `fn_decl`, one of the file's own, its result
    /// points into, if any: one that points at one value (`p: *const T`)
    /// and is returned sliced or with a field's address taken, as
    /// `return p.bytes[0..p.len];` with `bytes` an array of the file's `T`,
    /// `return &p.field;`, or `return p[0..n];` with `p: *const [N]u8`.
    /// Only what it returns directly is looked at, through `if`, `switch`
    /// and the like, not through its locals or its own calls.
    fn viewOf(r: *Rule, fn_decl: Node.Index) Allocator.Error!?u32 {
        if (r.views.get(fn_decl)) |known| return known;
        const tree = r.tree;
        const proto_node, const body = tree.nodeData(fn_decl).node_and_node;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, proto_node).?;
        var returned: std.ArrayList(Node.Index) = .empty;
        try returnValues(r.arena, tree, body, &returned);
        var values: std.ArrayList(Node.Index) = .empty;
        for (returned.items) |value| try r.leaves(value, &values);
        const view = for (values.items) |value| {
            if (r.viewedParam(proto, value)) |param| break param;
        } else null;
        try r.views.put(r.arena, fn_decl, view);
        return view;
    }

    /// The parameter of `proto` that `value` points into, as `viewOf`
    /// describes.
    fn viewedParam(r: *Rule, proto: Ast.full.FnProto, value: Node.Index) ?u32 {
        const tree = r.tree;
        switch (tree.nodeTag(value)) {
            .slice_open, .slice, .slice_sentinel => {
                var sliced = tree.fullSlice(value).?.ast.sliced;
                while (tree.nodeTag(sliced) == .grouped_expression) sliced = tree.nodeData(sliced).node_and_token[0];
                switch (tree.nodeTag(sliced)) {
                    // `p[a..b]` and `p.*[a..b]`, with `p: *const [N]T`.
                    .identifier, .deref => {
                        const name = if (tree.nodeTag(sliced) == .deref) tree.nodeData(sliced).node else sliced;
                        const param, const pointed = pointerParam(tree, proto, name) orelse return null;
                        return switch (tree.nodeTag(pointed)) {
                            .array_type, .array_type_sentinel => param,
                            else => null,
                        };
                    },
                    // `p.field[a..b]`, with `field` an array.
                    .field_access => {
                        const lhs, const field = tree.nodeData(sliced).node_and_token;
                        const param, const pointed = pointerParam(tree, proto, lhs) orelse return null;
                        const container = r.types.containerOf(pointed, 0) orelse return null;
                        return if (fieldIsArray(tree, container, tree.tokenSlice(field))) param else null;
                    },
                    else => return null,
                }
            },
            // `&p.field`, whatever the field.
            .address_of => {
                const operand = tree.nodeData(value).node;
                if (tree.nodeTag(operand) != .field_access) return null;
                const param, _ = pointerParam(tree, proto, tree.nodeData(operand).node_and_token[0]) orelse return null;
                return param;
            },
            else => return null,
        }
    }

    /// The argument a call's result points into, when the callee is one of
    /// `std_view_fns`: named through its namespace (`std.fmt.bufPrint`,
    /// `fmt.bufPrint`), or, for most, alone (`bufPrint`) in a file that
    /// declares no function of that name.
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
                const view = std_view_fns.get(name) orelse return null;
                if (!view.alone) return null;
                break :view view;
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
            // Deeper only where the file's types show every field on the
            // way is held by value (`&t.name.bytes`): in `&s.a.b`, `a` may
            // be a pointer, and `.b` would then reach through it to memory
            // that is not `s`'s.
            .field_access, .array_access => {
                const by_field = tree.nodeTag(operand) == .field_access;
                const root = if (by_field) tree.nodeData(operand).node_and_token[0] else tree.nodeData(operand).node_and_node[0];
                const p = r.place(root, 0) orelse return null;
                if (r.isComptimeBinding(p.binding)) return null;
                if (p.storage != if (by_field) Storage.value else Storage.array) return null;
                const access = if (by_field or p.field) "address of a field of" else "address of an element of";
                return try r.storageSource(amp, access, p.binding);
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
            // `x.field[a..b]` of an `x` held by value, with `field` an
            // array, through as many fields held by value as the file's
            // types show (`t.name.bytes[0..]`).
            .field_access => if (r.place(sliced, 0)) |p| {
                if (p.storage == .array and !r.isComptimeBinding(p.binding)) {
                    return try r.storageSource(tree.nodeMainToken(p.root), "slice of a field of", p.binding);
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
            .capture = if (binding.per_turn) index else null,
        };
    }

    fn storageHint(r: *const Rule) []const u8 {
        return if (r.comptime_params) hint_storage_comptime else hint_storage;
    }

    /// The hint for what points into `capture`, held by value in a loop
    /// and stored to `sink`: capture by pointer, when the capture's type
    /// shows what the loop walks and that it outlives the turn. Returned
    /// or stored outward from a loop over an array of the function's own,
    /// a pointer capture would still point into the function's frame.
    fn captureHint(r: *Rule, capture: u32, sink: Sink, otherwise: []const u8) Allocator.Error![]const u8 {
        const binding = r.bindings.items[capture];
        const input = binding.init.unwrap() orelse return otherwise;
        if (binding.type_expr == .none or (sink != .outer_local and r.walksOwnArray(input))) {
            return if (sink == .outer_local) hint_turn else otherwise;
        }
        return r.arena.print("capture it by pointer, `|*{s}|`, to point into what the loop walks rather than a copy made for one turn", .{binding.name});
    }

    /// Whether `input`, a loop's input, is an array in the function's own
    /// memory: `arr`, `&arr` or `arr[a..b]` with `arr: [N]T`, or such a
    /// field of a struct held by value.
    fn walksOwnArray(r: *Rule, input: Node.Index) bool {
        const tree = r.tree;
        var node = input;
        while (true) switch (tree.nodeTag(node)) {
            .grouped_expression => node = tree.nodeData(node).node_and_token[0],
            .address_of => node = tree.nodeData(node).node,
            .slice_open, .slice, .slice_sentinel => node = tree.fullSlice(node).?.ast.sliced,
            else => break,
        };
        const p = r.place(node, 0) orelse return false;
        return p.storage == .array;
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
    // What 0.17.0 deprecates bufPrint in favor of.
    .{ "print", ViewFn{ .namespace = "mem", .argument = 0, .alone = false } },
    .{ "printSentinel", ViewFn{ .namespace = "mem", .argument = 0, .alone = false } },
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

const ViewFn = struct {
    namespace: []const u8,
    argument: usize,
    /// Known by its name alone, `bufPrint(...)`, in a file that declares no
    /// function of that name. A `print` alone is more often something
    /// else, such as `std.debug.print` under another name.
    alone: bool = true,
};

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
    /// Its type as written: a parameter's, a local's annotation, `T` of a
    /// local's `T{...}`, or the element type of a `for` loop's input for a
    /// capture held by value.
    type_expr: Node.OptionalIndex,
    /// A local's initializer, or what a capture is taken from: its `for`
    /// loop's input, or the condition of its `if` or `while`.
    init: Node.OptionalIndex,
    /// A capture held by value in a loop: a copy made for one turn.
    per_turn: bool = false,

    const Kind = enum { local, parameter, capture };
};

/// The loop a capture is declared by, if any.
const Loop = enum { none, @"while", @"for" };

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
    /// The local stored to, for `.outer_local`.
    local: ?u32 = null,
};

/// Builtins whose result is always known at compile time.
pub const comptime_builtins: std.StaticStringMap(void) = .initComptime(.{
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

fn typeOfLocal(tree: *const Ast, type_node: Node.OptionalIndex, init_node: Node.OptionalIndex) Node.OptionalIndex {
    if (type_node != .none) return type_node;
    const init = init_node.unwrap() orelse return .none;
    var buffer: [2]Node.Index = undefined;
    if (tree.fullStructInit(&buffer, init)) |struct_init| return struct_init.ast.type_expr;
    if (tree.fullArrayInit(&buffer, init)) |array_init| return array_init.ast.type_expr;
    return .none;
}

/// The index of the parameter of `proto` that `node` names, when it points
/// at one value, and what it points at.
fn pointerParam(tree: *const Ast, proto: Ast.full.FnProto, node: Node.Index) ?struct { u32, Node.Index } {
    if (tree.nodeTag(node) != .identifier) return null;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    var params = proto.iterate(tree);
    var index: u32 = 0;
    while (params.next()) |param| : (index += 1) {
        const name_token = param.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;
        const pointed = pointee(tree, param.type_expr orelse return null) orelse return null;
        return .{ index, pointed };
    }
    return null;
}

/// Whether `container` has a field `name` declared as an array.
fn fieldIsArray(tree: *const Ast, container: Node.Index, name: []const u8) bool {
    const type_expr = fieldType(tree, container, name) orelse return false;
    return switch (tree.nodeTag(type_expr)) {
        .array_type, .array_type_sentinel => true,
        else => false,
    };
}

/// The name at the root of a place, `self` of `self.items[i].*`, or of a
/// loop's input, `self` of `&self.buf` or `self.items[1..]`, and whether a
/// field is reached on the way.
fn rootOf(tree: *const Ast, node: Node.Index) struct { Node.Index, bool } {
    var root = node;
    var through_field = false;
    while (true) switch (tree.nodeTag(root)) {
        .field_access => {
            through_field = true;
            root = tree.nodeData(root).node_and_token[0];
        },
        .array_access => root = tree.nodeData(root).node_and_node[0],
        .deref, .address_of => root = tree.nodeData(root).node,
        .unwrap_optional, .grouped_expression => root = tree.nodeData(root).node_and_token[0],
        .slice_open, .slice, .slice_sentinel => root = tree.fullSlice(root).?.ast.sliced,
        else => return .{ root, through_field },
    };
}

/// Appends the value of every `return` in `node`, a function's body, but
/// not of the functions and types declared in it.
fn returnValues(gpa: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    var nodes: std.ArrayList(Node.Index) = .empty;
    try children.append(gpa, tree, node, &nodes);
    for (nodes.items) |child| {
        var buffer: [2]Node.Index = undefined;
        if (tree.nodeTag(child) == .fn_decl or tree.fullContainerDecl(&buffer, child) != null) continue;
        if (tree.nodeTag(child) == .@"return") {
            if (tree.nodeData(child).opt_node.unwrap()) |value| try out.append(gpa, value);
        }
        try returnValues(gpa, tree, child, out);
    }
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
        if (e.sink == .outer_local) {
            try out.writer.print("{d}:{d} {s} -> a loop in {s} through local '{s}'\n", .{ loc.line + 1, loc.column + 1, e.what, e.function, e.local });
        } else {
            try out.writer.print("{d}:{d} {s} -> {s} through {s}\n", .{ loc.line + 1, loc.column + 1, e.what, e.function, e.sink.text() });
        }
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

test "an element or field of a local made with an initializer (#59)" {
    try expectEscapes(
        \\const C = struct { start: usize, end: usize };
        \\fn element(n: usize) []const C { const whole = [_][]const C{ &.{}, &.{.{ .start = 0, .end = n }} }; return whole[1]; }
        \\fn picked(n: usize, some: bool) struct { c: []const C } { const whole = [_][]const C{ &.{}, &.{.{ .start = 0, .end = n }} }; return .{ .c = whole[@intFromBool(some)] }; }
        \\fn field(n: usize) []const C { const s = .{ .all = &[_]C{.{ .start = 0, .end = n }}, .none = &[_]C{} }; return s.all; }
        \\fn aliased(n: usize) []const C { const whole = [_][]const C{ &.{}, &.{.{ .start = 0, .end = n }} }; const one = whole[1]; return one; }
        \\fn stored(n: usize, out: *[]const C) void { const whole = [_][]const C{&.{.{ .start = 0, .end = n }}}; out.* = whole[0]; }
        \\fn ofLocal(n: usize) *const usize { var x = n; const ptrs = [_]*const usize{&x}; return ptrs[0]; }
        \\fn static(n: usize) []const C { const whole = [_][]const C{ &.{}, &.{.{ .start = 0, .end = n }} }; return whole[0]; }
        \\fn values(n: usize) usize { const pair = [_]usize{ n, n + 1 }; return pair[1]; }
        \\fn fromParam(items: []const C) []const C { const whole = [_][]const C{ items, items[1..] }; return whole[1]; }
        \\fn literal() []const u8 { const names = [_][]const u8{ "a", "b" }; return names[1]; }
        \\fn otherField(n: usize, keep: []const C) []const C { const s = .{ .all = &[_]C{.{ .start = 0, .end = n }}, .kept = keep }; _ = s.all.len; return s.kept; }
    ,
        \\2:68 anonymous array -> element through return
        \\3:93 anonymous array -> picked through return
        \\4:52 array literal -> field through return
        \\5:68 anonymous array -> aliased through return
        \\6:72 anonymous array -> stored through out param
        \\7:77 address of local 'x' -> ofLocal through return
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

test "a function the file only calls at compile time is not checked" {
    try expectEscapes(
        \\const entries: []const u8 = entriesArray();
        \\fn entriesArray() []const u8 { var a: [2]u8 = .{ 1, 2 }; a[0] = 3; const f = a; return &f; }
        \\fn fixture(n: u8) []const u8 { return &.{n}; }
        \\test { _ = comptime fixture(1); }
        \\fn describe(n: u8) []const u8 { var out: [1]u8 = .{n}; return out[0..1]; }
        \\fn generate() []const u8 { return describe(3); }
        \\pub const completions = comptimeGenerate();
        \\fn comptimeGenerate() []const u8 { comptime { return generate(); } }
        \\pub fn alphabet() []const u8 { var count = 0; count += 1; var a: [count]u8 = undefined; a[0] = 'a'; const r = a; return &r; }
        \\pub const sigs = blk: { var arr: [1][]const u8 = undefined; arr[0] = derive(7); break :blk arr; };
        \\fn derive(n: u8) []const u8 { return &.{n}; }
    , "");
}

test "a function called at run time, named, exported, or never called in the file is checked" {
    try expectEscapes(
        \\fn leak(n: u8) []const u8 { return &.{n}; }
        \\fn use(n: u8) usize { return leak(n).len; }
        \\fn mixed(n: u8) []const u8 { return &.{n}; }
        \\const m = mixed(1);
        \\fn run(n: u8) usize { return mixed(n).len; }
        \\fn pointed(n: u8) []const u8 { return &.{n}; }
        \\const fp = &pointed;
        \\pub fn api(n: u8) []const u8 { return &.{n}; }
        \\export fn exported(n: u8) [*]const u8 { return &[_]u8{n}; }
        \\const e = exported(1);
        \\fn counted(n: u8) []const u8 { comptime var count = 0; count += 1; return &.{n}; }
    ,
        \\1:36 anonymous array -> leak through return
        \\3:37 anonymous array -> mixed through return
        \\6:39 anonymous array -> pointed through return
        \\8:39 anonymous array -> api through return
        \\9:48 array literal -> exported through return
        \\11:75 anonymous array -> counted through return
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
        \\fn memPrint(id: u32) []const u8 { var buf: [32]u8 = undefined; return std.mem.print(&buf, "{d}", .{id}) catch unreachable; }
        \\fn memSentinel(id: u32) [:0]const u8 { var buf: [32]u8 = undefined; return mem.printSentinel(&buf, "{d}", .{id}, 0) catch unreachable; }
        \\fn bare(id: u32) []const u8 { var buf: [32]u8 = undefined; return print(&buf, id); }
    ,
        \\3:85 address of local 'buf' -> label through return
        \\4:88 address of local 'buf' -> aliased through return
        \\5:91 address of local 'buf' -> viaLocal through return
        \\9:85 address of local 'buf' -> memPrint through return
        \\10:94 address of local 'buf' -> memSentinel through return
        \\
    );
}

test "a file's own function is not taken for the std one of the same name" {
    try expectEscapes(
        \\fn sliceTo(a: *const [4]u8, end: u8) []const u8 { _ = a; _ = end; return "fixed"; }
        \\fn own(n: u8) []const u8 { var buf: [4]u8 = .{ n, n, n, n }; return sliceTo(&buf, 0); }
    , "");
}

test "an array field of a struct held by value, sliced or through the file's own view of it (#28)" {
    try expectEscapes(
        \\const Id = struct {
        \\    bytes: [8]u8 = undefined,
        \\    name: []const u8 = "",
        \\    len: u8 = 0,
        \\    const Self = @This();
        \\    fn slice(self: *const Id) []const u8 { return self.bytes[0..self.len]; }
        \\    fn whole(self: *const Self) []const u8 { return &self.bytes; }
        \\    fn label(self: *const Id) []const u8 { return self.name; }
        \\    fn copied(self: Id) []const u8 { return self.bytes[0..self.len]; }
        \\};
        \\const Other = struct { b: [2]u8, fn slice(self: *const Other) []const u8 { _ = self; return "x"; } };
        \\fn name(id: Id) []const u8 { return id.slice(); }
        \\fn direct(id: Id) []const u8 { return id.bytes[0..id.len]; }
        \\fn borrowed(id: *const Id) []const u8 { return id.slice(); }
        \\fn viaSelf(id: Id) []const u8 { return id.whole(); }
        \\fn local() []const u8 { var id: Id = .{}; return id.slice(); }
        \\fn typed(n: u8) []const u8 { const id = Id{ .len = n }; return id.bytes[0..]; }
        \\fn namespaced(id: Id) []const u8 { return Id.slice(&id); }
        \\fn throughPointer() []const u8 { var id: Id = .{}; const p: *const Id = &id; return p.slice(); }
        \\fn free(buf: *const [4]u8, n: usize) []const u8 { return buf[0..n]; }
        \\fn freeCall(n: u8) []const u8 { var buf: [4]u8 = .{ n, n, n, n }; return free(&buf, 2); }
        \\fn sliceField(id: Id) []const u8 { return id.name[0..]; }
        \\fn labelled(id: Id) []const u8 { return id.label(); }
        \\fn sameName(o: Other) []const u8 { return o.slice(); }
        \\fn elsewhere(o: @import("o.zig").Id) []const u8 { return o.bytes[0..]; }
    ,
        \\9:45 slice of a field of parameter 'self' -> copied through return
        \\12:37 address of parameter 'id' -> name through return
        \\13:39 slice of a field of parameter 'id' -> direct through return
        \\15:40 address of parameter 'id' -> viaSelf through return
        \\16:50 address of local 'id' -> local through return
        \\17:64 slice of a field of local 'id' -> typed through return
        \\18:52 address of parameter 'id' -> namespaced through return
        \\19:73 address of local 'id' -> throughPointer through return
        \\21:79 address of local 'buf' -> freeCall through return
        \\
    );
}

test "a capture held by value in a loop is a copy made for one turn (#34)" {
    try expectEscapes(
        \\const Name = struct {
        \\    bytes: [16]u8 = undefined,
        \\    len: usize = 0,
        \\    fn slice(self: *const Name) []const u8 { return self.bytes[0..self.len]; }
        \\};
        \\const Topic = struct { name: Name, ref: *const Name, partitions: u32 };
        \\const Holder = struct { topics: []const Topic, last: []const u8, names: [2]Name };
        \\fn direct(topics: []const Topic, into: [][]const u8) void { for (topics, into) |topic, *out| out.* = topic.name.bytes[0..topic.name.len]; }
        \\fn method(topics: []const Topic, into: [][]const u8) void { for (topics, into) |topic, *out| out.* = topic.name.slice(); }
        \\fn local(topics: []const Topic) usize { var last: []const u8 = ""; for (topics) |topic| last = topic.name.slice(); return last.len; }
        \\fn returned(topics: []const Topic) []const u8 { for (topics) |topic| return topic.name.slice(); return ""; }
        \\fn field(h: *Holder) void { for (h.topics) |topic| h.last = topic.name.slice(); }
        \\fn outerArray(topics: []const Topic) usize { var names: [4][]const u8 = undefined; for (topics, &names) |topic, *n| n.* = topic.name.slice(); return names[0].len; }
        \\fn ownArray(h: Holder) []const u8 { for (h.names) |n| return n.slice(); return ""; }
        \\fn nested(t: Topic) []const u8 { return t.name.bytes[0..t.name.len]; }
        \\fn nestedMethod(t: Topic) []const u8 { return t.name.slice(); }
        \\fn nestedAddress(t: Topic) *const [16]u8 { return &t.name.bytes; }
        \\fn temporaryThroughCapture(into: [][]const u8, n: u8) void { for (into) |*b| b.* = &.{n}; }
        \\fn borrowed(topics: []const Topic, into: [][]const u8) void { for (topics, into) |*topic, *out| out.* = topic.name.slice(); }
        \\fn inside(topics: []const Topic) usize { var n: usize = 0; for (topics) |topic| { var name: []const u8 = ""; name = topic.name.slice(); n += name.len; } return n; }
        \\fn pointerField(topics: []const Topic, into: [][]const u8) void { for (topics, into) |topic, *out| out.* = topic.ref.slice(); }
        \\fn indices(topics: []const Topic, into: []usize) void { for (topics, into, 0..) |_, *out, i| out.* = i; }
        \\fn temporaryIntoLocal(n: u8) usize { var bufs: [2][]const u8 = undefined; for (&bufs) |*b| b.* = &.{n}; return bufs[0].len; }
        \\fn passed(topics: []const Topic) bool { for (topics) |topic| if (eql(topic.name.slice(), "a")) return true; return false; }
        \\fn eql(a: []const u8, b: []const u8) bool { return a.len == b.len; }
    ,
        \\8:102 slice of a field of capture 'topic' -> direct through out param
        \\9:102 address of a field of capture 'topic' -> method through out param
        \\10:96 address of a field of capture 'topic' -> a loop in local through local 'last'
        \\11:77 address of a field of capture 'topic' -> returned through return
        \\12:61 address of a field of capture 'topic' -> field through field
        \\13:123 address of a field of capture 'topic' -> a loop in outerArray through local 'names'
        \\14:62 address of capture 'n' -> ownArray through return
        \\15:41 slice of a field of parameter 't' -> nested through return
        \\16:47 address of a field of parameter 't' -> nestedMethod through return
        \\17:51 address of a field of parameter 't' -> nestedAddress through return
        \\18:84 anonymous array -> temporaryThroughCapture through out param
        \\
    );
}

test "a loop capture's hint: by pointer when the loop walks memory that outlives it" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\const Name = struct { bytes: [4]u8, fn slice(self: *const Name) []const u8 { return &self.bytes; } };
        \\fn caller(names: []const Name) []const u8 { for (names) |n| return n.slice(); return ""; }
        \\fn own(n: u8) []const u8 { const names = [_]Name{.{ .bytes = .{ n, n, n, n } }}; for (names) |m| return m.slice(); return ""; }
        \\fn untyped(it: *Iterator) usize { var last: *const u8 = undefined; while (it.next()) |b| last = &b; return last.*; }
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
    const expected = [_][]const u8{
        "capture it by pointer, `|*n|`, to point into what the loop walks rather than a copy made for one turn",
        hint_storage,
        hint_turn,
    };
    try std.testing.expectEqual(expected.len, findings.items.len);
    for (expected, findings.items) |hint, finding| try std.testing.expectEqualStrings(hint, finding.hint);
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
