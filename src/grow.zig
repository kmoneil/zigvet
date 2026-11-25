//! Rule fourteen, grow: a pointer into a list's items, kept across a call
//! that can move them.
//!
//!     const first = &list.items[0];
//!     try list.append(gpa, x);
//!     first.* = 7; // append moved the items when the list was full
//!
//! `append` reallocates when the list has no room, and `first` is left
//! pointing at freed memory. The same holds for `getPtr`, or `getOrPut`'s
//! `value_ptr`, kept across a `put` on the same map, and for a `for` over
//! `list.items` whose body appends to `list`: the loop took the slice once
//! and walks on through the old memory. It compiles clean in every build
//! mode, and it works whenever the list happened to have room, which is
//! most test runs.
//!
//! A `std.Io.Reader`'s buffer moves the same way (#188): a slice from
//! `in.buffered()`, `in.peek(n)` or `in.take(n)`, kept across a call that
//! reads more, such as `in.fill(n)`, shows other bytes once the reader
//! rebases, moving what it has not handed out yet to the start of its
//! buffer and reading new bytes in after.
//!
//! Across the methods of one type (#189): a method whose doc comment says
//! the slice it returns stays valid (until `deinit`, for the value's life,
//! never moves), while another method grows the list it is a slice of. See
//! `promised` for what it reads.
//!
//! What points in is a local made with `&x.items[...]`, `x.items` or a
//! slice of it, `x.addOne(...)` and its kind when the file shows `x` is an
//! `ArrayList`, or `x.getPtr(...)`, `x.getOrPut(...)`, `x.getEntry(...)`
//! and their kind when it shows `x` is a hash map, as escape finds types;
//! what an `if` captures from such a `getPtr`; a `for` over `x.items` or a
//! slice of it; and a local made with `x.buffered()`, `x.peek(...)`,
//! `x.take(...)` and their kind, or a slice of one, when the file shows `x`
//! is a reader (a type named `Reader` it does not declare itself, or the
//! `interface` of one, `&file_reader.interface`) not made with `fixed`,
//! whose buffer is the bytes it reads and never moves. What moves is a call
//! on the same `x`, as written, that can reallocate: `append`,
//! `appendSlice`, `insert`, `addOne`, `resize`, `ensureTotalCapacity` and
//! the rest for a list, `put`, `getOrPut`, `fetchPut`,
//! `ensureTotalCapacity` and the rest for a map, and for a reader any call
//! that can read more: `fill`, `fillMore`, `rebase`, and those named
//! `peek`, `take`, `discard`, `read`, `stream`, `append` or `alloc` and
//! more, but not `toss`, which only moves the reader on.
//! It is reported when, on a path after the call, the local is used, or
//! the `for` goes on to its next turn: later in the same block, after the
//! loop or block a `break` leaves, or on the next turn of a loop around
//! the call that the local was declared outside of, with no `return`,
//! `break` or `continue` that leaves first.
//!
//! Not reported: the `AssumeCapacity` calls, which cannot move anything; a
//! use in another branch of the `if` or another prong of the `switch` the
//! call is in, or after a `continue` to a loop the local is declared in,
//! which takes it again; a call that comes, on every path from the
//! pointer, after the list or map, or what holds it, is stored again
//! (`s.list = saved;`, `list.* = .empty;`), which grows what was stored; a
//! pointer taken again before the use; a length, or `found_existing` or
//! `index`, read out of it, which are copies; a `getOrPut` that makes a new
//! entry only on a path that leaves at once, when a `getOrPut` made the
//! pointer and so left a free slot; a list or map handed to a call
//! (`try fill(&list)`), which only the callee can judge; and a type the
//! file does not show, such as `std.SegmentedList`, whose elements never
//! move.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const expect = @import("expect.zig");
const kept = @import("kept.zig");
const report = @import("report.zig");
const Finding = report.Finding;
const types = @import("types.zig");

/// Appends a finding for every call that can move what a pointer kept
/// across it points into. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    var rule: Rule = .{ .arena = arena, .tree = tree, .findings = findings };
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(node)) {
            .for_simple, .@"for" => try rule.loop(node),
            .if_simple, .@"if" => try rule.captured(node),
            else => {},
        }
        var container_buffer: [2]Node.Index = undefined;
        if (tree.fullContainerDecl(&container_buffer, node)) |container| try rule.promised(node, container.ast.members);
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, node) orelse continue;
        for (statements, 0..) |statement, at| {
            const decl = tree.fullVarDecl(statement) orelse continue;
            const init = decl.ast.init_node.unwrap() orelse continue;
            var into = try rule.pointsInto(init) orelse continue;
            // Only when the pointer's own `getOrPut` found its key on the
            // path that goes on: a new entry may take the last free slot.
            if (into.slot_left) into.slot_left = try rule.insertsOnlyToLeave(if (tree.nodeTag(init) == .@"try") tree.nodeData(init).node else init);
            try rule.across(node, statements[at + 1 ..], into, tree.tokenSlice(decl.ast.mut_token + 1));
        }
    }
}

const hint_list = "keep the index and take the pointer again after it, or reserve first with `ensureUnusedCapacity` and grow with an `AssumeCapacity` call, which cannot move anything";
const hint_map = "look it up again after it, or reserve first with `ensureUnusedCapacity` and use `putAssumeCapacity` or `getOrPutAssumeCapacity`, which cannot move anything";
const hint_loop = "walk an index (`while (i < list.items.len)`) so each turn reads the items afresh, or reserve first with `ensureUnusedCapacity` and grow with an `AssumeCapacity` call";
const hint_reader = "take the slice again after it, or copy the bytes out before it (into an array, or with `gpa.dupe`) when they must outlive it";

/// What a pointer points into: the list or map, as written.
const Into = struct {
    owner: Node.Index,
    kind: Kind,
    /// Made by a `getOrPut` that found its key, which grows the map first
    /// if it has no free slot and takes none, so one is left after it.
    slot_left: bool = false,
};

const Kind = enum { list, map, reader };

/// What a path after a moving call is watched for: a use of `name`, the
/// pointer, unless it is empty, before the end of `scope`, the block that
/// declares it; or, with `loop`, the next turn of `scope`, a `for` over the
/// items.
const Watch = struct {
    name: []const u8,
    scope: Node.Index,
    loop: bool,
};

/// A method that grows a list field, and the call in it that does.
const Grower = struct { method: Node.Index, call: Node.Index };

const Rule = struct {
    arena: Allocator,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),
    t: ?types.Types = null,

    fn lazyTypes(r: *Rule) Allocator.Error!types.Types {
        if (r.t == null) r.t = try .init(r.arena, r.tree);
        return r.t.?;
    }

    /// The list, map or reader a local's initializer points into:
    /// `&x.items[i]`, `x.items[a..]`, `try x.addOne(gpa)`, `x.getPtr(k)` or
    /// `x.buffered()`.
    fn pointsInto(r: *Rule, init: Node.Index) Allocator.Error!?Into {
        const tree = r.tree;
        const n = unwrapped(tree, init);
        switch (tree.nodeTag(n)) {
            .address_of => {
                const operand = tree.nodeData(n).node;
                if (tree.nodeTag(operand) != .array_access) return null;
                const owner = itemsOf(tree, tree.nodeData(operand).node_and_node[0]) orelse return null;
                return .{ .owner = owner, .kind = .list };
            },
            .field_access => return .{ .owner = itemsOf(tree, n) orelse return null, .kind = .list },
            .slice_open, .slice, .slice_sentinel => {
                const sliced = tree.fullSlice(n).?.ast.sliced;
                if (itemsOf(tree, sliced)) |owner| return .{ .owner = owner, .kind = .list };
                // `(try in.peek(8))[0..4]`: a slice of a reader's view.
                const into = try r.pointsInto(sliced) orelse return null;
                return if (into.kind == .reader) into else null;
            },
            else => return r.madeBy(n),
        }
    }

    /// What `n`, a call such as `list.addOne(gpa)`, `map.getPtr(k)` or
    /// `in.peek(4)`, makes a pointer into.
    fn madeBy(r: *Rule, n: Node.Index) Allocator.Error!?Into {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, n) orelse return null;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
        const owner, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!isPlace(tree, owner)) return null;
        const name = tree.tokenSlice(method);
        if (in(name, &adds)) {
            if (!try r.declaredAs(owner, &.{ "ArrayList", "array_list" })) return null;
            return .{ .owner = owner, .kind = .list };
        }
        if (in(name, &lookups)) {
            if (!try r.declaredAs(owner, &.{"HashMap"})) return null;
            const grows_first = std.mem.startsWith(u8, name, "getOrPut") and !std.mem.endsWith(u8, name, "AssumeCapacity");
            return .{ .owner = owner, .kind = .map, .slot_left = grows_first };
        }
        if (in(name, &reader_views)) {
            if (!try r.isReader(owner, 0)) return null;
            return .{ .owner = owner, .kind = .reader };
        }
        return null;
    }

    /// Whether `place` is a reader whose buffer can move: the file shows
    /// its type with `Reader` in the name and does not declare that type
    /// itself, or it is the `interface` of a reader (`&fr.interface`, with
    /// `fr` a `std.Io.File.Reader` or made by `file.reader(...)`), and it
    /// was not made with `fixed`, whose buffer is the bytes it reads.
    fn isReader(r: *Rule, place: Node.Index, depth: u8) Allocator.Error!bool {
        const tree = r.tree;
        if (depth > 4) return false;
        if (tree.nodeTag(place) == .identifier) if ((try r.lazyTypes()).localInit(place)) |init| {
            if (isFixed(tree, init)) return false;
            const made = if (tree.nodeTag(init) == .address_of) tree.nodeData(init).node else init;
            // `const in = &source.interface;`, or `&r` of a reader `r`.
            if (interfaceOf(tree, made)) |holder| return r.readerNamed(holder, &.{ "Reader", "reader" });
            if (tree.nodeTag(made) == .identifier) return r.isReader(made, depth + 1);
        };
        if (interfaceOf(tree, place)) |holder| return r.readerNamed(holder, &.{ "Reader", "reader" });
        return r.readerNamed(place, &.{"Reader"});
    }

    /// Whether the file shows `place`'s type with one of `words` in its
    /// name, and does not declare that type itself, as it would its own
    /// `Reader` whose `take` may keep what it returns.
    fn readerNamed(r: *Rule, place: Node.Index, words: []const []const u8) Allocator.Error!bool {
        const t = try r.lazyTypes();
        if (t.typeOf(place, 0)) |of| if (t.containerOf(types.pointee(r.tree, of) orelse of, 0) != null) return false;
        return r.declaredAs(place, words);
    }

    /// Whether the type the file shows for `place`, written or, for a
    /// local, made by its initializer, has one of `words` in its name.
    fn declaredAs(r: *Rule, place: Node.Index, words: []const []const u8) Allocator.Error!bool {
        const t = try r.lazyTypes();
        const text = if (t.typeOf(place, 0)) |of|
            r.tree.getNodeSource(of)
        else if (r.tree.nodeTag(place) == .identifier)
            r.tree.getNodeSource(t.localInit(place) orelse return false)
        else
            return false;
        // The type's own name, before its arguments: not `List(HashMap(..))`.
        const head = text[0 .. std.mem.findScalar(u8, text, '(') orelse text.len];
        for (words) |word| if (std.mem.find(u8, head, word) != null) return true;
        return false;
    }

    /// A pointer local `name`, declared in `block` before `after`, that
    /// points into `into`: reports the first call among `after` that can
    /// move it with a use of `name` after.
    fn across(r: *Rule, block: Node.Index, after: []const Node.Index, into: Into, name: []const u8) Allocator.Error!void {
        var nodes: std.ArrayList(Node.Index) = .empty;
        for (after) |statement| try within(r.arena, r.tree, statement, &nodes);
        for (nodes.items) |node| {
            if (!r.moves(node, into)) continue;
            if (try r.replaced(node, block, after, into)) continue;
            if (into.slot_left and try r.insertsOnlyToLeave(node)) continue;
            if (!try r.reached(node, .{ .name = name, .scope = block, .loop = false })) continue;
            return r.add(node, into, name);
        }
    }

    /// Whether `call` is a `getOrPut` whose new entry is made only on a
    /// path that leaves at once: `const g = try map.getOrPut(k);` then
    /// `if (!g.found_existing) { ...; return ...; }`. A key already there
    /// takes no slot, so, with a slot left by the `getOrPut` that made the
    /// pointer, the path that goes on moves nothing. Zig's own LLVM IR
    /// builder names its values this way. Asked of the pointer's own
    /// `getOrPut` as well, whose new entry may take the last free slot.
    fn insertsOnlyToLeave(r: *Rule, call: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        const parents = (try r.lazyTypes()).parents;
        var buffer: [1]Node.Index = undefined;
        const full = tree.fullCall(&buffer, call) orelse return false;
        if (!std.mem.startsWith(u8, tree.tokenSlice(tree.nodeData(full.ast.fn_expr).node_and_token[1]), "getOrPut")) return false;
        var decl = parents[@backingInt(call)].unwrap() orelse return false;
        if (tree.nodeTag(decl) == .@"try") decl = parents[@backingInt(decl)].unwrap() orelse return false;
        const var_decl = tree.fullVarDecl(decl) orelse return false;
        const result = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const block = parents[@backingInt(decl)].unwrap() orelse return false;
        var statements_buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&statements_buffer, block) orelse return false;
        const at = std.mem.findScalar(Node.Index, statements, decl) orelse return false;
        if (at + 1 == statements.len) return false;
        const check_found = tree.fullIf(statements[at + 1]) orelse return false;
        if (check_found.ast.else_expr != .none) return false;
        // `!g.found_existing`.
        const cond = check_found.ast.cond_expr;
        if (tree.nodeTag(cond) != .bool_not) return false;
        const read = tree.nodeData(cond).node;
        if (tree.nodeTag(read) != .field_access) return false;
        const of, const field = tree.nodeData(read).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(field), "found_existing") or !isNamed(tree, of, result)) return false;
        var then_buffer: [2]Node.Index = undefined;
        const then = tree.blockStatements(&then_buffer, check_found.ast.then_expr) orelse (&check_found.ast.then_expr)[0..1];
        if (then.len == 0) return false;
        return switch (tree.nodeTag(then[then.len - 1])) {
            .@"return", .@"break", .@"continue" => true,
            else => false,
        };
    }

    /// `if (map.getPtr(k)) |p| { ... }`: `p` points into the map for the
    /// `if`'s body.
    fn captured(r: *Rule, node: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        const full = tree.fullIf(node).?;
        const payload = full.payload_token orelse return;
        if (tree.tokenTag(payload) != .identifier) return;
        const into = try r.pointsInto(full.ast.cond_expr) orelse return;
        var buffer: [2]Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, full.ast.then_expr) orelse return;
        try r.across(full.ast.then_expr, statements, into, tree.tokenSlice(payload));
    }

    /// A `for` over `x.items`: reports the first call in its body that can
    /// move them with a path on to the next turn.
    fn loop(r: *Rule, node: Node.Index) Allocator.Error!void {
        const tree = r.tree;
        const full = tree.fullFor(node).?;
        var capture = full.payload_token;
        for (full.ast.inputs) |input| {
            const by_pointer = tree.tokenTag(capture) == .asterisk;
            const capture_name = tree.tokenSlice(if (by_pointer) capture + 1 else capture);
            capture += if (by_pointer) 3 else 2;
            const sliced = switch (tree.nodeTag(input)) {
                .slice_open, .slice, .slice_sentinel => tree.fullSlice(input).?.ast.sliced,
                else => input,
            };
            const owner = itemsOf(tree, sliced) orelse continue;
            const into: Into = .{ .owner = owner, .kind = .list };
            var nodes: std.ArrayList(Node.Index) = .empty;
            try within(r.arena, tree, full.ast.then_expr, &nodes);
            for (nodes.items) |inner| {
                if (!r.moves(inner, into)) continue;
                if (try r.replaced(inner, node, &.{}, into)) continue;
                // A pointer capture, `|*item|`, is a pointer kept as well.
                const watch: Watch = .{ .name = if (by_pointer) capture_name else "", .scope = node, .loop = true };
                if (!try r.reached(inner, watch)) continue;
                return r.add(inner, into, "");
            }
        }
    }

    /// Whether `node` is a call on `into`'s owner, as written, that can
    /// move what it holds.
    fn moves(r: *Rule, node: Node.Index, into: Into) bool {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse return false;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
        const owner, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, tree.getNodeSource(owner), tree.getNodeSource(into.owner))) return false;
        return switch (into.kind) {
            .list => in(tree.tokenSlice(method), &list_moves),
            .map => in(tree.tokenSlice(method), &map_moves),
            .reader => readerReads(tree.tokenSlice(method)),
        };
    }

    /// Whether `call`, a call that moves, comes after a statement that
    /// stores another list or map in `into`'s owner, or in what holds it
    /// (`s.list = saved;`), on every path to it from the pointer: before it
    /// in a block around it, inside `scope`, and in `scope` itself among
    /// `after`, the statements after the pointer was taken. The call then
    /// grows what was stored, and the pointer's memory stays where it is
    /// (#95). A copy stored back that holds the pointer's memory, taken
    /// after it, is missed.
    fn replaced(r: *Rule, call: Node.Index, scope: Node.Index, after: []const Node.Index, into: Into) Allocator.Error!bool {
        const tree = r.tree;
        const parents = (try r.lazyTypes()).parents;
        const owner = tree.getNodeSource(into.owner);
        var child = call;
        while (parents[@backingInt(child)].unwrap()) |parent| : (child = parent) {
            var buffer: [2]Node.Index = undefined;
            const statements = if (parent == scope) after else tree.blockStatements(&buffer, parent) orelse continue;
            const at = std.mem.findScalar(Node.Index, statements, child) orelse return false;
            for (statements[0..at]) |before| if (replaces(tree, before, owner)) return true;
            if (parent == scope) return false;
        }
        return false;
    }

    /// Whether a path from `call`, a call that moves, reaches what `watch`
    /// is watched for before it leaves.
    fn reached(r: *Rule, call: Node.Index, watch: Watch) Allocator.Error!bool {
        const tree = r.tree;
        const parents = (try r.lazyTypes()).parents;
        var child = call;
        var up = parents[@backingInt(call)].unwrap();
        climb: while (up) |parent| : ({
            child = parent;
            up = parents[@backingInt(parent)].unwrap();
        }) {
            // The end of the loop's body: the next turn.
            if (watch.loop and parent == watch.scope) return child == tree.fullFor(parent).?.ast.then_expr;
            if (kept.isNested(tree.nodeTag(parent))) return false;
            switch (tree.nodeTag(parent)) {
                .fn_decl, .test_decl => return false,
                .while_simple, .while_cont, .@"while", .for_simple, .@"for" => {
                    // The next turn of a loop around the call, declared
                    // after the pointer: it may read it again.
                    if (!watch.loop and isBody(tree, parent, child) and uses(tree, parent, watch.name)) return true;
                    continue;
                },
                else => {},
            }
            var buffer: [2]Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, parent) orelse continue;
            const at = std.mem.findScalar(Node.Index, statements, child) orelse return false;
            for (statements[at + 1 ..]) |next| {
                if (assigns(tree, next, watch.name)) return false;
                if (uses(tree, next, watch.name)) return true;
                switch (tree.nodeTag(next)) {
                    .@"return" => return false,
                    .@"break", .@"continue" => {
                        const target = jumpTarget(tree, parents, next) orelse return false;
                        const again = tree.nodeTag(next) == .@"continue";
                        if (watch.loop and target == watch.scope) return again;
                        if (!inside(parents, target, watch.scope)) return false;
                        if (again and !watch.loop and uses(tree, target, watch.name)) return true;
                        // On after the loop or block it leaves.
                        child = target;
                        up = parents[@backingInt(target)].unwrap();
                        continue :climb;
                    },
                    else => {},
                }
            }
            if (!watch.loop and parent == watch.scope) return false;
        }
        return false;
    }

    /// Methods of `container` that hand out a slice of a list field's
    /// items, and say in their doc comment that it stays valid (until
    /// `deinit`, for the value's life), while another method of the type
    /// grows that list (#189). Each is right alone; the pair is the bug.
    fn promised(r: *Rule, container: Node.Index, members: []const Node.Index) Allocator.Error!void {
        const tree = r.tree;
        for (members) |member| {
            if (tree.nodeTag(member) != .fn_decl) continue;
            const doc = try docComment(r.arena, tree, member) orelse continue;
            if (!promisesToKeep(doc)) continue;
            var values: std.ArrayList(Node.Index) = .empty;
            try returned(r.arena, tree, member, &values);
            for (values.items) |value| {
                const field = r.handsOut(members, member, value, 1) orelse continue;
                if (!try r.isListField(container, field)) continue;
                const grows = try r.grower(members, field) orelse continue;
                if (honest(doc, fnName(tree, grows.method))) continue;
                if (!try r.isOpen(container, member, grows.method)) continue;
                try r.addPromise(member, value, field, grows);
                break;
            }
        }
    }

    /// The list field whose items `value`, returned from `method`, is a
    /// slice of or points into: `self.names.items`, `self.bytes.items[a..]`,
    /// `&self.nodes.items[i]`, or, `depth` times, a call to another method
    /// of the type that returns one (`self.spanOf(span)`).
    fn handsOut(r: *Rule, members: []const Node.Index, method: Node.Index, value: Node.Index, depth: u8) ?Ast.TokenIndex {
        const tree = r.tree;
        const self = receiver(tree, method) orelse return null;
        var n = value;
        while (tree.fullSlice(n)) |slice| n = slice.ast.sliced;
        if (tree.nodeTag(n) == .address_of and tree.nodeTag(tree.nodeData(n).node) == .array_access) {
            n = tree.nodeData(tree.nodeData(n).node).node_and_node[0];
        }
        if (itemsOf(tree, n)) |owner| return fieldOf(tree, owner, self);
        if (depth == 0) return null;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, value) orelse return null;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
        const on, const name = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!isNamed(tree, on, self)) return null;
        const helper = memberFnIn(tree, members, tree.tokenSlice(name)) orelse return null;
        var values: std.ArrayList(Node.Index) = .empty;
        returned(r.arena, tree, helper, &values) catch return null;
        for (values.items) |inner| if (r.handsOut(members, helper, inner, depth - 1)) |field| return field;
        return null;
    }

    /// Whether the type declares `field` as an `ArrayList`.
    fn isListField(r: *Rule, container: Node.Index, field: Ast.TokenIndex) Allocator.Error!bool {
        const tree = r.tree;
        const of = types.fieldType(tree, container, tree.tokenSlice(field)) orelse return false;
        const text = tree.getNodeSource(of);
        const head = text[0 .. std.mem.findScalar(u8, text, '(') orelse text.len];
        return std.mem.find(u8, head, "ArrayList") != null or std.mem.find(u8, head, "array_list") != null;
    }

    /// The first method among `members` that calls a growing method on
    /// its receiver's `field`: `self.bytes.appendSlice(...)`.
    fn grower(r: *Rule, members: []const Node.Index, field: Ast.TokenIndex) Allocator.Error!?Grower {
        const tree = r.tree;
        const name = tree.tokenSlice(field);
        for (members) |member| {
            if (tree.nodeTag(member) != .fn_decl) continue;
            const self = receiver(tree, member) orelse continue;
            var nodes: std.ArrayList(Node.Index) = .empty;
            try within(r.arena, tree, tree.nodeData(member).node_and_node[1], &nodes);
            for (nodes.items) |node| {
                var buffer: [1]Node.Index = undefined;
                const call = tree.fullCall(&buffer, node) orelse continue;
                if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
                const owner, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
                if (!in(tree.tokenSlice(method), &list_moves)) continue;
                const of = fieldOf(tree, owner, self) orelse continue;
                if (std.mem.eql(u8, tree.tokenSlice(of), name)) return .{ .method = member, .call = node };
            }
        }
        return null;
    }

    /// Whether whoever holds what `getter` returns can grow the list with
    /// `grower`: it is `pub`, or a function outside `container` calls both.
    /// A method only the type itself calls grows the list when the type
    /// decides (a phase it runs once, as a checker records what it found,
    /// or a table filled before it is handed on), and the doc's promise may
    /// rest on that phase being over, which the syntax does not show.
    fn isOpen(r: *Rule, container: Node.Index, getter: Node.Index, grower_fn: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        if (tree.fullFnProto(&buffer, tree.nodeData(grower_fn).node_and_node[0]).?.visib_token != null) return true;
        const parents = (try r.lazyTypes()).parents;
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @fromBackingInt(@intCast(i));
            if (!try r.callsOn(node, fnName(tree, grower_fn), container) or inside(parents, node, container)) continue;
            const caller = enclosingFn(tree, parents, node) orelse continue;
            var nodes: std.ArrayList(Node.Index) = .empty;
            const body = switch (tree.nodeTag(caller)) {
                .test_decl => tree.nodeData(caller).opt_token_and_node[1],
                else => tree.nodeData(caller).node_and_node[1],
            };
            try within(r.arena, tree, body, &nodes);
            for (nodes.items) |n| if (try r.callsOn(n, fnName(tree, getter), container)) return true;
        }
        return false;
    }

    /// Whether `node` calls a method named `name`, on a value the file does
    /// not show the type of, or shows is `container`.
    fn callsOn(r: *Rule, node: Node.Index, name: []const u8, container: Node.Index) Allocator.Error!bool {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse return false;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
        const on, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(method), name)) return false;
        const t = try r.lazyTypes();
        const of = t.typeOf(on, 0) orelse return true;
        const named = t.containerOf(types.pointee(tree, of) orelse of, 0) orelse return true;
        return named == container;
    }

    fn addPromise(r: *Rule, method: Node.Index, value: Node.Index, field: Ast.TokenIndex, grows: Grower) Allocator.Error!void {
        const tree = r.tree;
        const grower_name = fnName(tree, grows.method);
        var buffer: [1]Node.Index = undefined;
        const call = tree.fullCall(&buffer, grows.call).?;
        try r.findings.append(r.arena, .{
            .offset = tree.tokenStart(tree.firstToken(value)),
            .hint = try r.arena.print("keep what it returns where growing the list cannot move it (an arena, or each one allocated on its own), or say in its doc that it is valid until the next `{s}`", .{grower_name}),
            .detail = .{ .grow = .{
                .call = tree.getNodeSource(call.ast.fn_expr),
                .moved = try r.arena.print("`{s}.{s}.items`", .{ receiver(tree, method).?, tree.tokenSlice(field) }),
                .pointer = fnName(tree, method),
                .grower = grower_name,
            } },
        });
    }

    fn add(r: *Rule, call: Node.Index, into: Into, pointer: []const u8) Allocator.Error!void {
        const tree = r.tree;
        var buffer: [1]Node.Index = undefined;
        const full = tree.fullCall(&buffer, call).?;
        const owner = tree.getNodeSource(into.owner);
        try r.findings.append(r.arena, .{
            .offset = tree.tokenStart(tree.firstToken(call)),
            .hint = if (pointer.len == 0) hint_loop else switch (into.kind) {
                .list => hint_list,
                .map => hint_map,
                .reader => hint_reader,
            },
            .detail = .{ .grow = .{
                .call = tree.getNodeSource(full.ast.fn_expr),
                .moved = switch (into.kind) {
                    .list => try r.arena.print("`{s}.items`", .{owner}),
                    .map => try r.arena.print("`{s}`'s entries", .{owner}),
                    .reader => try r.arena.print("`{s}`'s buffer", .{owner}),
                },
                .pointer = pointer,
                .rebased = into.kind == .reader,
            } },
        });
    }
};

/// A list's calls that make a pointer into it.
const adds = [_][]const u8{
    "addOne",                       "addManyAsSlice",          "addManyAsArray",
    "addManyAt",                    "addOneAssumeCapacity",    "addManyAsSliceAssumeCapacity",
    "addManyAsArrayAssumeCapacity", "addManyAtAssumeCapacity",
};

/// A hash map's calls that make a pointer into it.
const lookups = [_][]const u8{
    "getPtr",        "getPtrAdapted",    "getPtrContext",          "getOrPut",        "getOrPutAdapted",
    "getOrPutValue", "getOrPutContext",  "getEntry",               "getEntryAdapted", "getEntryContext",
    "getKeyPtr",     "getKeyPtrAdapted", "getOrPutAssumeCapacity",
};

/// A list's calls that can reallocate its items.
const list_moves = [_][]const u8{
    "append",                     "appendSlice",          "appendNTimes", "appendUnalignedSlice",
    "insert",                     "insertSlice",          "addOne",       "addManyAsSlice",
    "addManyAsArray",             "addManyAt",            "resize",       "ensureTotalCapacity",
    "ensureTotalCapacityPrecise", "ensureUnusedCapacity", "replaceRange", "print",
};

/// A hash map's calls that can rehash or reallocate its entries.
const map_moves = [_][]const u8{
    "put",                 "putNoClobber",         "putContext",                 "putNoClobberContext",
    "getOrPut",            "getOrPutAdapted",      "getOrPutContext",            "getOrPutContextAdapted",
    "getOrPutValue",       "getOrPutValueContext", "fetchPut",                   "fetchPutContext",
    "ensureTotalCapacity", "ensureUnusedCapacity", "ensureTotalCapacityContext", "ensureUnusedCapacityContext",
};

/// `n` without the `try`, parentheses, `.?` or `orelse` around it:
/// `map.getPtr(k) orelse return`.
fn unwrapped(tree: *const Ast, n: Node.Index) Node.Index {
    var at = n;
    while (true) switch (tree.nodeTag(at)) {
        .@"try" => at = tree.nodeData(at).node,
        .grouped_expression, .unwrap_optional => at = tree.nodeData(at).node_and_token[0],
        .@"orelse" => at = tree.nodeData(at).node_and_node[0],
        else => return at,
    };
}

/// A reader's calls that return a slice of its buffer.
const reader_views = [_][]const u8{
    "buffered",               "peek",                   "peekGreedy",             "take",
    "peekArray",              "takeArray",              "peekSentinel",           "takeSentinel",
    "peekDelimiterInclusive", "takeDelimiterInclusive", "peekDelimiterExclusive", "takeDelimiterExclusive",
    "takeDelimiter",          "peekStructPointer",      "takeStructPointer",
};

/// Whether `method`, called on a reader, can read more into its buffer,
/// and so rebase it. `buffered` and `toss` only look or move the reader on.
fn readerReads(method: []const u8) bool {
    const reads = [_][]const u8{ "fill", "rebase", "peek", "take", "discard", "read", "stream", "append", "alloc" };
    for (reads) |prefix| if (std.mem.startsWith(u8, method, prefix)) return true;
    return false;
}

/// Whether `init` makes a reader with `fixed`, `.fixed(bytes)` or
/// `std.Io.Reader.fixed(bytes)`, which reads `bytes` in place.
fn isFixed(tree: *const Ast, init: Node.Index) bool {
    var buffer: [1]Node.Index = undefined;
    const call = tree.fullCall(&buffer, init) orelse return false;
    const last = tree.lastToken(call.ast.fn_expr);
    return tree.tokenTag(last) == .identifier and std.mem.eql(u8, tree.tokenSlice(last), "fixed");
}

/// `x` of `x.interface`, `x` a name or a field of one.
fn interfaceOf(tree: *const Ast, node: Node.Index) ?Node.Index {
    if (tree.nodeTag(node) != .field_access) return null;
    const holder, const field = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(field), "interface") or !isPlace(tree, holder)) return null;
    return holder;
}

/// The doc comment above `fn_decl`, its `///` lines joined and lowercased,
/// or null for none.
fn docComment(arena: Allocator, tree: *const Ast, fn_decl: Node.Index) Allocator.Error!?[]const u8 {
    var buffer: [1]Node.Index = undefined;
    const first = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?.firstToken();
    var top = first;
    while (top > 0 and tree.tokenTag(top - 1) == .doc_comment) top -= 1;
    if (top == first) return null;
    var text: std.ArrayList(u8) = .empty;
    for (top..first) |token| {
        for (tree.tokenSlice(@intCast(token))[3..]) |c| try text.append(arena, std.ascii.toLower(c));
        try text.append(arena, ' ');
    }
    return text.items;
}

/// Whether a doc comment, lowercased, says what the function returns
/// stays valid: until `deinit` (or the value is freed), for the value's
/// life, or that it never moves.
fn promisesToKeep(doc: []const u8) bool {
    if (std.mem.find(u8, doc, "until")) |at| {
        for ([_][]const u8{ "deinit", "freed", "destroy" }) |end| if (std.mem.find(u8, doc[at..], end) != null) return true;
    }
    for ([_][]const u8{ "lifetime", "for the life", "as long as", "never move" }) |phrase| {
        if (std.mem.find(u8, doc, phrase) != null) return true;
    }
    return false;
}

/// Whether a doc comment, lowercased, also says what ends the slice short
/// of that: the next call, a change to the value, or `grower` by name.
fn honest(doc: []const u8, grower: []const u8) bool {
    const ends = [_][]const u8{ "next", "modif", "mutat", "chang", "resiz", "grow", "append", "insert", "invalidat" };
    for (ends) |end| if (std.mem.find(u8, doc, end) != null) return true;
    var lower: [64]u8 = undefined;
    if (grower.len > lower.len) return false;
    return std.mem.find(u8, doc, std.ascii.lowerString(&lower, grower)) != null;
}

/// The values `fn_decl` can return: each `return`'s operand, through a
/// `try`, parentheses and the branches of an `if` or `switch`.
fn returned(arena: Allocator, tree: *const Ast, fn_decl: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    var nodes: std.ArrayList(Node.Index) = .empty;
    try within(arena, tree, tree.nodeData(fn_decl).node_and_node[1], &nodes);
    for (nodes.items) |node| {
        if (tree.nodeTag(node) != .@"return") continue;
        try branches(arena, tree, tree.nodeData(node).opt_node.unwrap() orelse continue, out);
    }
}

fn branches(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    switch (tree.nodeTag(node)) {
        .grouped_expression => return branches(arena, tree, tree.nodeData(node).node_and_token[0], out),
        .@"try" => return branches(arena, tree, tree.nodeData(node).node, out),
        .if_simple, .@"if" => {
            const full = tree.fullIf(node).?;
            try branches(arena, tree, full.ast.then_expr, out);
            if (full.ast.else_expr.unwrap()) |other| try branches(arena, tree, other, out);
        },
        .@"switch", .switch_comma => for (tree.fullSwitch(node).?.ast.cases) |case| {
            try branches(arena, tree, tree.fullSwitchCase(case).?.ast.target_expr, out);
        },
        else => try out.append(arena, node),
    }
}

/// The name of `fn_decl`'s first parameter, its receiver as a method.
fn receiver(tree: *const Ast, fn_decl: Node.Index) ?[]const u8 {
    var buffer: [1]Node.Index = undefined;
    var params = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?.iterate(tree);
    const first = params.next() orelse return null;
    return tree.tokenSlice(first.name_token orelse return null);
}

/// `F` of `self.F`, with `self` the name given.
fn fieldOf(tree: *const Ast, node: Node.Index, self: []const u8) ?Ast.TokenIndex {
    if (tree.nodeTag(node) != .field_access) return null;
    const on, const field = tree.nodeData(node).node_and_token;
    return if (isNamed(tree, on, self)) field else null;
}

/// The function `name` among `members`.
fn memberFnIn(tree: *const Ast, members: []const Node.Index, name: []const u8) ?Node.Index {
    for (members) |member| {
        if (tree.nodeTag(member) == .fn_decl and std.mem.eql(u8, fnName(tree, member), name)) return member;
    }
    return null;
}

/// The function or test `node` is in.
fn enclosingFn(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) ?Node.Index {
    var up = parents[@backingInt(node)].unwrap();
    while (up) |parent| : (up = parents[@backingInt(parent)].unwrap()) {
        switch (tree.nodeTag(parent)) {
            .fn_decl, .test_decl => return parent,
            else => {},
        }
    }
    return null;
}

fn fnName(tree: *const Ast, fn_decl: Node.Index) []const u8 {
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(fn_decl).node_and_node[0]).?;
    return if (proto.name_token) |token| tree.tokenSlice(token) else "";
}

fn isNamed(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

fn in(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// `x` of `x.items`, `x` a name or a field of one.
fn itemsOf(tree: *const Ast, node: Node.Index) ?Node.Index {
    if (tree.nodeTag(node) != .field_access) return null;
    const owner, const field = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(field), "items") or !isPlace(tree, owner)) return null;
    return owner;
}

/// Whether `node` is a name or a field of one: `list`, `self.list`.
fn isPlace(tree: *const Ast, node: Node.Index) bool {
    var n = node;
    while (tree.nodeTag(n) == .field_access) n = tree.nodeData(n).node_and_token[0];
    return tree.nodeTag(n) == .identifier;
}

/// Whether `child` is the body of `loop`, or its continue expression,
/// both of which run again on the next turn.
fn isBody(tree: *const Ast, loop: Node.Index, child: Node.Index) bool {
    if (tree.fullWhile(loop)) |full| return child == full.ast.then_expr or child == full.ast.cont_expr.unwrap();
    return child == tree.fullFor(loop).?.ast.then_expr;
}

/// Whether `node` reads `name`: as a name, not a field's, and not for a
/// copy read out of it (`.len`, `.found_existing`, `.index`).
fn uses(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    if (name.len == 0) return false;
    const last = tree.lastToken(node);
    var token = tree.firstToken(node);
    while (token <= last) : (token += 1) {
        if (tree.tokenTag(token) != .identifier or !std.mem.eql(u8, tree.tokenSlice(token), name)) continue;
        if (token > 0 and tree.tokenTag(token - 1) == .period) continue;
        if (token + 2 <= last and tree.tokenTag(token + 1) == .period) {
            const field = tree.tokenSlice(token + 2);
            if (in(field, &.{ "len", "found_existing", "index" })) continue;
        }
        return true;
    }
    return false;
}

/// Whether `node` stores a new pointer in `name`.
fn assigns(tree: *const Ast, node: Node.Index, name: []const u8) bool {
    if (name.len == 0 or tree.nodeTag(node) != .assign) return false;
    const target = tree.nodeData(node).node_and_node[0];
    return tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), name);
}

/// Whether `node` stores a new value in `place`, as written, or in what
/// holds it: `s.list = saved`, `s.* = .{}` or `s = other` for `s.list`.
fn replaces(tree: *const Ast, node: Node.Index, place: []const u8) bool {
    if (tree.nodeTag(node) != .assign) return false;
    var target = tree.nodeData(node).node_and_node[0];
    if (tree.nodeTag(target) == .deref) target = tree.nodeData(target).node;
    const text = tree.getNodeSource(target);
    if (!std.mem.startsWith(u8, place, text)) return false;
    return place.len == text.len or place[text.len] == '.';
}

/// The loop a `break` or `continue` leaves or turns again, or the block a
/// labeled `break` leaves. Null for a labeled `continue` of a `switch`.
pub fn jumpTarget(tree: *const Ast, parents: []const Node.OptionalIndex, node: Node.Index) ?Node.Index {
    const label = if (tree.nodeData(node).opt_token_and_opt_node[0].unwrap()) |token| tree.tokenSlice(token) else null;
    var up = parents[@backingInt(node)].unwrap();
    while (up) |parent| : (up = parents[@backingInt(parent)].unwrap()) {
        if (kept.isNested(tree.nodeTag(parent))) return null;
        const loop_label: ?Ast.TokenIndex = if (tree.fullWhile(parent)) |full|
            full.label_token
        else if (tree.fullFor(parent)) |full|
            full.label_token
        else {
            const wanted = label orelse continue;
            var buffer: [2]Node.Index = undefined;
            if (tree.blockStatements(&buffer, parent) == null) continue;
            const lbrace = tree.nodeMainToken(parent);
            if (lbrace >= 2 and tree.tokenTag(lbrace - 1) == .colon and std.mem.eql(u8, tree.tokenSlice(lbrace - 2), wanted)) return parent;
            continue;
        };
        const wanted = label orelse return parent;
        if (loop_label) |token| if (std.mem.eql(u8, tree.tokenSlice(token), wanted)) return parent;
    }
    return null;
}

/// Whether `node` is `scope` or inside it.
fn inside(parents: []const Node.OptionalIndex, node: Node.Index, scope: Node.Index) bool {
    var at: ?Node.Index = node;
    while (at) |n| : (at = parents[@backingInt(n)].unwrap()) {
        if (n == scope) return true;
    }
    return false;
}

/// Appends `node` and every node under it, but not what nested functions
/// and types hold, or what a `defer` or `errdefer` runs.
fn within(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    if (kept.isNested(tree.nodeTag(node))) return;
    switch (tree.nodeTag(node)) {
        .@"defer", .@"errdefer" => return,
        else => {},
    }
    try out.append(arena, node);
    var nodes: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, node, &nodes);
    for (nodes.items) |child| try within(arena, tree, child, out);
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col call moved pointer`, in source order.
fn expectGrow(source: [:0]const u8, expected: []const u8) !void {
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
        const g = finding.detail.grow;
        try out.writer.print("{d}:{d} {s} {s} {s}\n", .{ loc.line + 1, loc.column + 1, g.call, g.moved, if (g.pointer.len == 0) "(for)" else g.pointer });
    }
    try expect.findings(@src(), expected, out.written());
}

test "a pointer into a list's items kept across a call that can move them (#55)" {
    try expectGrow(
        \\fn first(gpa: Allocator, list: *List) !void { const p = &list.items[0]; try list.append(gpa, 1); p.* = 7; }
        \\fn slice(gpa: Allocator, self: *Self) !u8 { const s = self.list.items[1..]; try self.list.appendSlice(gpa, "ab"); return s[0]; }
        \\fn added(gpa: Allocator) !void { var list: std.ArrayList(u8) = .empty; const slot = try list.addOne(gpa); try list.ensureUnusedCapacity(gpa, 8); slot.* = 1; }
        \\fn looped(gpa: Allocator, list: *List) !void { const p = &list.items[0]; while (more()) { use(p.*); try list.append(gpa, 1); } }
        \\fn walked(gpa: Allocator, list: *List) !void { for (list.items) |x| { if (x == 0) try list.append(gpa, 1); } }
        \\fn pointed(gpa: Allocator, list: *List) !void { for (list.items[1..]) |*x| { try list.append(gpa, 1); x.* = 0; break; } }
        \\fn broke(gpa: Allocator, list: *List) !void { const p = &list.items[0]; blk: { try list.append(gpa, 1); break :blk; } p.* = 1; }
    ,
        \\1:77 list.append `list.items` p
        \\2:81 self.list.appendSlice `self.list.items` s
        \\3:111 list.ensureUnusedCapacity `list.items` slot
        \\4:105 list.append `list.items` p
        \\5:87 list.append `list.items` (for)
        \\6:82 list.append `list.items` (for)
        \\7:84 list.append `list.items` p
        \\
    );
}

test "a pointer into a hash map kept across a call that can rehash it (#55)" {
    try expectGrow(
        \\fn put(gpa: Allocator) !void { var map: std.AutoHashMapUnmanaged(u32, u32) = .empty; const gop = try map.getOrPut(gpa, 1); try map.put(gpa, 2, 2); gop.value_ptr.* = 1; }
        \\fn held(self: *Self) !void { const v = self.map.getPtr(1).?; try self.map.put(2, 2); v.* += 1; }
        \\fn made(gpa: Allocator) !void { var map = std.StringHashMap(u32).init(gpa); const e = map.getEntry("a").?; try map.ensureUnusedCapacity(4); e.value_ptr.* = 1; }
        \\fn caught(self: *Self) !void { if (self.map.getPtr(1)) |v| { try self.map.put(2, 2); v.* += 1; } }
        \\fn looked(map: *std.AutoHashMap(u32, u32), k: u32) !void { const v = map.getPtr(k) orelse return; const next = try map.getOrPut(k + 1); if (!next.found_existing) return; v.* += 1; }
        \\fn inserted(map: *std.AutoHashMap(u32, u32), k: u32) !void { const gop = try map.getOrPut(k); if (!gop.found_existing) gop.value_ptr.* = 0; const next = try map.getOrPut(k + 1); if (!next.found_existing) return; gop.value_ptr.* += 1; }
        \\const Self = struct { map: std.AutoHashMap(u32, u32) };
    ,
        \\1:128 map.put `map`'s entries gop
        \\2:66 self.map.put `self.map`'s entries v
        \\3:112 map.ensureUnusedCapacity `map`'s entries e
        \\4:66 self.map.put `self.map`'s entries v
        \\5:116 map.getOrPut `map`'s entries v
        \\6:158 map.getOrPut `map`'s entries gop
        \\
    );
}

test "not reported: AssumeCapacity, another branch, a continue, taken again, a copy, a type not shown" {
    try expectGrow(
        \\fn assumed(list: *List) void { const p = &list.items[0]; list.appendAssumeCapacity(1); p.* = 7; }
        \\fn branch(gpa: Allocator, list: *List, c: bool) !void { const p = &list.items[0]; if (c) { try list.append(gpa, 1); } else { p.* = 7; } }
        \\fn stack(gpa: Allocator, frames: *List) !void { while (frames.items.len != 0) { const frame = &frames.items[frames.items.len - 1]; if (frame.next < 4) { frame.next += 1; try frames.append(gpa, .{}); continue; } _ = frames.pop(); } }
        \\fn again(gpa: Allocator, list: *List) !void { var p = &list.items[0]; try list.append(gpa, 1); p = &list.items[0]; p.* = 7; }
        \\fn length(gpa: Allocator, list: *List) !usize { const s = list.items; try list.append(gpa, 1); return s.len; }
        \\fn found(gpa: Allocator, map: *std.AutoHashMap(u32, u32)) !bool { const gop = try map.getOrPut(1); try map.put(2, 2); return gop.found_existing; }
        \\fn segmented(gpa: Allocator, seg: *Segmented) !void { const p = try seg.addOne(gpa); try seg.append(gpa, 1); p.* = 7; }
        \\fn other(gpa: Allocator, a: *List, b: *List) !void { const p = &a.items[0]; try b.append(gpa, 1); p.* = 7; }
        \\fn after(gpa: Allocator, list: *List) !void { const p = &list.items[0]; p.* = 7; try list.append(gpa, 1); }
        \\fn exits(gpa: Allocator, list: *List) !void { for (list.items) |x| { if (x == 0) { try list.append(gpa, 1); break; } } }
        \\fn returns(gpa: Allocator, list: *List) !void { for (list.items) |x| { if (x == 0) { try list.append(gpa, 1); return; } } }
        \\fn index(gpa: Allocator, list: *List) !void { var i: usize = 0; while (i < list.items.len) : (i += 1) { if (list.items[i] == 0) try list.append(gpa, 1); } }
        \\fn notlist(gpa: Allocator, pool: *Pool) !void { const p = pool.getPtr(1); try pool.put(2); p.* = 1; }
        \\fn unique(map: *std.AutoHashMap(u32, u32), k: u32) !u32 { const gop = try map.getOrPut(k); if (!gop.found_existing) { gop.value_ptr.* = 0; return k; } while (true) { gop.value_ptr.* += 1; const next = try map.getOrPut(k + gop.value_ptr.*); if (!next.found_existing) { next.value_ptr.* = 0; return k + gop.value_ptr.*; } } }
    , "");
}

test "a slice of a reader's buffer kept across a call that can rebase it (#188)" {
    try expectGrow(
        \\fn kept(in: *std.Io.Reader) !u8 { const head = in.buffered(); try in.fill(4); return head[0]; }
        \\fn peeked(in: *Io.Reader) !u8 { const a = try in.peek(2); const b = try in.takeByte(); return a[0] + b; }
        \\fn taken(fr: *std.Io.File.Reader) ![]const u8 { const in = &fr.interface; const name = try in.take(4); _ = try in.discardShort(2); return name; }
        \\fn sliced(in: *std.Io.Reader) !u8 { const a = (try in.peekGreedy(1))[0..1]; try in.fillMore(); return a[0]; }
        \\fn made(file: File, io: Io, buf: []u8) !u8 { var fr = file.reader(io, buf); const line = (try fr.interface.takeDelimiter('\n')) orelse return 0; _ = try fr.interface.readSliceShort(buf); return line[0]; }
        \\fn chunks(buf: []u8) !void { var source: std.testing.Reader = .init(buf, &.{}); const in = &source.interface; const head = in.buffered(); try in.fill(8); try expect(head); }
    ,
        \\1:67 in.fill `in`'s buffer head
        \\2:73 in.takeByte `in`'s buffer a
        \\3:112 in.discardShort `in`'s buffer name
        \\4:81 in.fillMore `in`'s buffer a
        \\5:154 fr.interface.readSliceShort `fr.interface`'s buffer line
        \\6:143 in.fill `in`'s buffer head
        \\
    );
}

test "not reported: a fixed reader, toss, taken again, a length, another reader, a writer, a type the file declares" {
    try expectGrow(
        \\fn fixed(bytes: []const u8) !u8 { var in: std.Io.Reader = .fixed(bytes); const a = try in.take(2); const b = try in.take(2); return a[0] + b[0]; }
        \\fn pointed(bytes: []const u8) !u8 { var r = std.Io.Reader.fixed(bytes); const in = &r; const a = try in.take(2); _ = try in.take(2); return a[0]; }
        \\fn tossed(in: *std.Io.Reader) !u8 { const a = try in.peek(2); in.toss(2); return a[0]; }
        \\fn again(in: *std.Io.Reader) !u8 { var a = in.buffered(); try in.fill(4); a = in.buffered(); return a[0]; }
        \\fn length(in: *std.Io.Reader) !usize { const a = in.buffered(); try in.fill(4); return a.len; }
        \\fn other(a: *std.Io.Reader, b: *std.Io.Reader) !u8 { const s = a.buffered(); try b.fill(4); return s[0]; }
        \\fn passed(in: *std.Io.Reader) !u8 { const s = in.buffered(); try refill(in); return s[0]; }
        \\fn writer(w: *std.Io.Writer) !u8 { const a = w.buffered(); try w.writeAll("x"); return a[0]; }
        \\fn own(in: *Reader) !u8 { const a = try in.take(2); _ = try in.take(2); return a[0]; }
        \\const Reader = struct { fn take(r: *Reader, n: usize) ![]const u8 { _ = r; _ = n; return "ab"; } };
    , "");
}

test "a method whose doc says the slice it returns stays valid, and a method that grows the list (#189)" {
    try expectGrow(
        \\const Table = struct {
        \\    gpa: Allocator,
        \\    bytes: std.ArrayList(u8) = .empty,
        \\    spans: std.ArrayList(Span) = .empty,
        \\    pub fn intern(t: *Table, s: []const u8) !usize { try t.bytes.appendSlice(t.gpa, s); try t.spans.append(t.gpa, .{ .start = 0, .len = s.len }); return t.spans.items.len - 1; }
        \\    /// The string `id` names. Valid until `deinit`.
        \\    fn get(t: *const Table, id: usize) []const u8 { return t.spanOf(t.spans.items[id]); }
        \\    fn spanOf(t: *const Table, s: Span) []const u8 { return t.bytes.items[s.start..][0..s.len]; }
        \\    /// The URI of `ns`, for the life of the table.
        \\    pub fn uri(t: *const Table, ns: u32) []const u8 { return switch (ns) { 0 => "", else => |i| t.spanOf(t.spans.items[i]) }; }
        \\    /// Every span. Never moves.
        \\    pub fn all(t: *const Table) []const Span { return t.spans.items; }
        \\    /// The first span; lives until the table is deinit'd.
        \\    pub fn first(t: *Table) *Span { return &t.spans.items[0]; }
        \\};
    ,
        \\7:60 t.bytes.appendSlice `t.bytes.items` get
        \\10:97 t.bytes.appendSlice `t.bytes.items` uri
        \\12:55 t.spans.append `t.spans.items` all
        \\14:44 t.spans.append `t.spans.items` first
        \\
    );
}

test "not reported: a doc that names what ends it, no doc, no method that grows it, not a list" {
    try expectGrow(
        \\const Table = struct {
        \\    bytes: std.ArrayList(u8) = .empty,
        \\    fixed: std.ArrayList(u8) = .empty,
        \\    raw: []u8,
        \\    seg: std.SegmentedList(u8, 0) = .{},
        \\    pub fn intern(t: *Table, gpa: Allocator, s: []const u8) !void { try t.bytes.appendSlice(gpa, s); t.fixed.appendSliceAssumeCapacity(s); try t.seg.append(gpa, 1); }
        \\    fn init(gpa: Allocator, s: []const u8) !Table { var t: Table = .{ .raw = &.{} }; try t.fixed.appendSlice(gpa, s); return t; }
        \\    /// Valid until `deinit` or the next `intern`.
        \\    fn named(t: *const Table) []const u8 { return t.bytes.items; }
        \\    /// Valid until `deinit`; invalidated when the table changes.
        \\    fn changed(t: *const Table) []const u8 { return t.bytes.items; }
        \\    fn undocumented(t: *const Table) []const u8 { return t.bytes.items; }
        \\    /// Valid until `deinit`.
        \\    fn grownAtInit(t: *const Table) []const u8 { return t.fixed.items; }
        \\    /// Valid until `deinit`.
        \\    fn slice(t: *const Table) []u8 { return t.raw; }
        \\    /// Valid until `deinit`.
        \\    fn byte(t: *const Table, i: usize) u8 { return t.bytes.items[i]; }
        \\    /// Valid until `deinit`.
        \\    fn other(t: *const Table, o: *const Table) []const u8 { _ = t; return o.bytes.items; }
        \\};
        \\const Checker = struct {
        \\    found: std.ArrayList(u32) = .empty,
        \\    pub fn check(c: *Checker, gpa: Allocator) !void { try c.record(gpa); }
        \\    fn record(c: *Checker, gpa: Allocator) !void { try c.found.append(gpa, 1); }
        \\    /// What checking found, valid until `deinit`.
        \\    pub fn results(c: *const Checker) []const u32 { return c.found.items; }
        \\};
    , "");
}

test "a method that grows the list, not pub: reported when a function outside the type also calls the getter (#189)" {
    try expectGrow(
        \\const Rows = struct {
        \\    rows: std.ArrayList(u32) = .empty,
        \\    fn add(p: *Rows, gpa: Allocator) !void { try p.rows.append(gpa, 1); }
        \\    /// The rows, valid until `deinit`.
        \\    fn all(p: *const Rows) []const u32 { return p.rows.items; }
        \\};
        \\test { var p: Rows = .{}; try p.add(std.testing.allocator); _ = p.all(); }
        \\const Filled = struct {
        \\    rows: std.ArrayList(u32) = .empty,
        \\    fn add(f: *Filled, gpa: Allocator) !void { try f.rows.append(gpa, 1); }
        \\    /// The rows, valid until `deinit`.
        \\    pub fn all(f: *const Filled) []const u32 { return f.rows.items; }
        \\};
        \\fn fill(f: *Filled, gpa: Allocator) !void { try f.add(gpa); }
    ,
        \\5:49 p.rows.append `p.rows.items` all
        \\
    );
}

test "not reported: the list stored again before the call that grows it (#95)" {
    try expectGrow(
        \\fn swapped(gpa: Allocator, s: *S) ![]const u32 { const saved = s.list; s.list = .empty; try s.list.append(gpa, 1); const found = s.list.items; s.list = saved; try s.list.append(gpa, 2); return found; }
        \\fn reset(gpa: Allocator, list: *List) !void { const p = &list.items[0]; list.* = .empty; try list.append(gpa, 1); p.* = 7; }
        \\fn holder(gpa: Allocator, first: *S, other: *S) !void { var s = first; const p = &s.list.items[0]; s = other; try s.list.append(gpa, 1); p.* = 7; }
        \\fn nested(gpa: Allocator, s: *S, c: bool, other: List) !void { const p = &s.list.items[0]; s.list = other; if (c) { try s.list.append(gpa, 1); } p.* = 7; }
        \\fn turned(gpa: Allocator, s: *S, other: List) !void { for (s.list.items) |x| { s.list = other; try s.list.append(gpa, x); } }
    , "");
}

test "reported: the list stored again on some paths only, after the call, or another place (#95)" {
    try expectGrow(
        \\fn branch(gpa: Allocator, s: *S, c: bool, other: List) !void { const p = &s.list.items[0]; if (c) s.list = other; try s.list.append(gpa, 1); p.* = 7; }
        \\fn later(gpa: Allocator, s: *S, other: List) !void { const p = &s.list.items[0]; try s.list.append(gpa, 1); s.list = other; p.* = 7; }
        \\fn sibling(gpa: Allocator, s: *S, other: List) !void { const p = &s.list.items[0]; s.l = other; try s.list.append(gpa, 1); p.* = 7; }
        \\fn items(gpa: Allocator, s: *S) !void { const p = &s.list.items[0]; s.list.items.len = 0; try s.list.append(gpa, 1); p.* = 7; }
    ,
        \\1:119 s.list.append `s.list.items` p
        \\2:86 s.list.append `s.list.items` p
        \\3:101 s.list.append `s.list.items` p
        \\4:95 s.list.append `s.list.items` p
        \\
    );
}
