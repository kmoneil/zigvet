//! Rule twenty-seven, tail: `@call(.always_tail, ...)` with nothing that
//! tests the backend first.
//!
//!     return @call(.always_tail, rest, .{ xs, i });
//!
//! `.always_tail` asks for a tail call or a compile error. LLVM makes one,
//! and Zig's own x86_64 backend makes none, and that backend is the Debug
//! default on x86_64 Linux. So the code compiles in every build mode on
//! macOS and on aarch64, and in every release build on x86_64 Linux, and
//! every Debug build there fails: "unable to perform tail call: compiler
//! backend 'stage2_x86_64' does not support tail calls". In a library the
//! error lands on its consumers, one for each instantiation: a scanner
//! shipped two releases with one before a program that imports it ran its
//! tests on x86_64 Linux, 54 errors in one build (#219).
//!
//! What is reported is the `@call` whose modifier is written as
//! `.always_tail` (or `CallModifier.always_tail`) when nothing before it in
//! its function tests the backend: `builtin.zig_backend`, by itself or
//! through a declaration of the file that reads it.
//!
//! Not reported: a modifier held in a name or computed, which is the fix
//! (`const tail: std.lang.CallModifier = if (builtin.zig_backend ==
//! .stage2_llvm) .always_tail else .auto;`); a call in a branch on the
//! backend, or after a test of it in its function, such as `if
//! (builtin.zig_backend == .stage2_x86_64) @compileError(...);`; every call
//! in a file whose top level refuses a backend, a `comptime` block that
//! tests it and calls `@compileError`; and a call in a function that is not
//! `pub` and is named only in branches on the backend (`const run = if
//! (llvm) runTail else runLoop;`).
//!
//! Reported though the build may be right: one that asks for LLVM for
//! every artifact (`.use_llvm = true`), which the file does not show and
//! a library's consumers do not inherit; and a test of the CPU or the build
//! mode, which says nothing of the backend that `-fno-llvm` or a later
//! default picks.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const expect = @import("expect.zig");
const report = @import("report.zig");
const Finding = report.Finding;

/// Appends a finding for every `@call(.always_tail, ...)` that nothing
/// tests the backend for. Everything is allocated with `arena`.
pub fn check(arena: Allocator, tree: *const Ast, findings: *std.ArrayList(Finding)) Allocator.Error!void {
    // Few files ask for a tail call: look before reading a node.
    if (std.mem.find(u8, tree.source, "always_tail") == null) return;
    var file: ?File = null;
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const call = alwaysTail(tree, node) orelse continue;
        if (file == null) file = try .init(arena, tree);
        if (file.?.guarded(tree.nodeMainToken(node))) continue;
        try findings.append(arena, .{
            .offset = tree.tokenStart(tree.nodeMainToken(node)),
            .hint = hint,
            .detail = .{ .tail = .{
                .modifier = tree.getNodeSource(call.modifier),
                .callee = try shown(arena, tree, call.callee),
            } },
        });
    }
}

const hint = "ask for it only where the backend has tail calls: `const tail: std.lang.CallModifier = if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto;`, then `@call(tail, ...)`";

/// The modifier and the callee of `node`, when it is a `@call` whose
/// modifier is written as `.always_tail` or `CallModifier.always_tail`.
fn alwaysTail(tree: *const Ast, node: Node.Index) ?struct { modifier: Node.Index, callee: Node.Index } {
    switch (tree.nodeTag(node)) {
        .builtin_call, .builtin_call_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@call")) return null;
    var buffer: [2]Node.Index = undefined;
    const params = tree.builtinCallParams(&buffer, node).?;
    if (params.len != 3) return null;
    const modifier = params[0];
    const name = switch (tree.nodeTag(modifier)) {
        .enum_literal => tree.nodeMainToken(modifier),
        .field_access => tree.nodeData(modifier).node_and_token[1],
        else => return null,
    };
    if (!std.mem.eql(u8, tree.tokenSlice(name), "always_tail")) return null;
    return .{ .modifier = modifier, .callee = params[1] };
}

/// What the file says of the backend, read once for a file that asks for
/// a tail call.
const File = struct {
    tree: *const Ast,
    /// The declarations whose initializers read `builtin.zig_backend`, by
    /// itself or through another of them: `const llvm = builtin.zig_backend
    /// == .stage2_llvm;`.
    reads: std.StringHashMapUnmanaged(void),
    /// Whether a `comptime` block at the top of a container tests the
    /// backend and calls `@compileError`: the file refuses a backend.
    refuses: bool,
    /// The tokens of each `if` and `switch` whose condition tests the
    /// backend, first and last.
    branches: []const [2]Ast.TokenIndex,
    /// Every function and test, its tokens first and last.
    functions: []const Function,

    const Function = struct {
        first: Ast.TokenIndex,
        last: Ast.TokenIndex,
        /// The first token of its body, after its name and parameters.
        body: Ast.TokenIndex,
        /// The function's name, if it is one that is not `pub`.
        private: ?[]const u8,
    };

    fn init(arena: Allocator, tree: *const Ast) Allocator.Error!File {
        var file: File = .{ .tree = tree, .reads = .empty, .refuses = false, .branches = &.{}, .functions = &.{} };
        try file.readDeclarations(arena);
        var branches: std.ArrayList([2]Ast.TokenIndex) = .empty;
        var functions: std.ArrayList(Function) = .empty;
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @fromBackingInt(@intCast(i));
            if (file.onBackend(node)) try branches.append(arena, .{ tree.firstToken(node), tree.lastToken(node) });
            if (functionAt(tree, node)) |function| try functions.append(arena, function);
            if (file.refusesIn(node)) file.refuses = true;
        }
        file.branches = branches.items;
        file.functions = functions.items;
        return file;
    }

    /// Fills `reads`, to a fixed point, for a declaration that reads
    /// another.
    fn readDeclarations(file: *File, arena: Allocator) Allocator.Error!void {
        const tree = file.tree;
        var grew = true;
        while (grew) {
            grew = false;
            for (0..tree.nodes.len) |i| {
                const decl = tree.fullVarDecl(@fromBackingInt(@intCast(i))) orelse continue;
                const value = decl.ast.init_node.unwrap() orelse continue;
                const name = tree.tokenSlice(decl.ast.mut_token + 1);
                if (file.reads.contains(name) or !file.tests(tree.firstToken(value), tree.lastToken(value))) continue;
                try file.reads.put(arena, name, {});
                grew = true;
            }
        }
    }

    /// Whether `node` is an `if` or a `switch` whose condition tests the
    /// backend.
    fn onBackend(file: File, node: Node.Index) bool {
        const tree = file.tree;
        const tested = if (tree.fullIf(node)) |full| full.ast.cond_expr else if (tree.fullSwitch(node)) |full| full.ast.condition else return false;
        return file.tests(tree.firstToken(tested), tree.lastToken(tested));
    }

    /// Whether `node` is a container with a `comptime` block at its top
    /// that tests the backend and calls `@compileError`.
    fn refusesIn(file: File, node: Node.Index) bool {
        const tree = file.tree;
        var buffer: [2]Node.Index = undefined;
        const members = if (tree.nodeTag(node) == .root) tree.rootDecls() else if (tree.fullContainerDecl(&buffer, node)) |container| container.ast.members else return false;
        for (members) |member| {
            if (tree.nodeTag(member) != .@"comptime") continue;
            const first = tree.firstToken(member);
            const last = tree.lastToken(member);
            if (file.tests(first, last) and calls(tree, first, last, "@compileError")) return true;
        }
        return false;
    }

    /// Whether the tokens from `first` to `last` read the backend:
    /// `zig_backend`, or a declaration that reads it.
    fn tests(file: File, first: Ast.TokenIndex, last: Ast.TokenIndex) bool {
        const tree = file.tree;
        for (first..last + 1) |token| {
            if (tree.tokenTag(@intCast(token)) != .identifier) continue;
            const name = tree.tokenSlice(@intCast(token));
            if (std.mem.eql(u8, name, "zig_backend") or file.reads.contains(name)) return true;
        }
        return false;
    }

    /// Whether the `@call` at `call` is one the file tests the backend for:
    /// before it in its function, at the top of a container with
    /// `@compileError`, or in every place its function, not `pub`, is
    /// named.
    fn guarded(file: File, call: Ast.TokenIndex) bool {
        if (file.refuses) return true;
        const function = file.functionOf(call) orelse return false;
        if (file.tests(function.body, call)) return true;
        const name = function.private orelse return false;
        return file.namedOnlyInBranches(name, function);
    }

    /// The innermost function or test that holds `token`.
    fn functionOf(file: File, token: Ast.TokenIndex) ?Function {
        var inner: ?Function = null;
        for (file.functions) |function| {
            if (token < function.first or token > function.last) continue;
            if (inner == null or function.first > inner.?.first) inner = function;
        }
        return inner;
    }

    /// Whether `name` is named outside `function`, and each time in a
    /// branch on the backend.
    fn namedOnlyInBranches(file: File, name: []const u8, function: Function) bool {
        const tree = file.tree;
        var named = false;
        for (0..tree.tokens.len) |i| {
            const token: Ast.TokenIndex = @intCast(i);
            if (token >= function.first and token <= function.last) continue;
            if (tree.tokenTag(token) != .identifier or !std.mem.eql(u8, tree.tokenSlice(token), name)) continue;
            for (file.branches) |branch| {
                if (token >= branch[0] and token <= branch[1]) break;
            } else return false;
            named = true;
        }
        return named;
    }
};

/// `node`'s tokens and, for a function that is not `pub`, its name, when
/// it is a function or a test.
fn functionAt(tree: *const Ast, node: Node.Index) ?File.Function {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    switch (tree.nodeTag(node)) {
        .fn_decl => {
            var buffer: [1]Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, node).?;
            const name = if (proto.visib_token == null) proto.name_token else null;
            const body = tree.firstToken(tree.nodeData(node).node_and_node[1]);
            return .{ .first = first, .last = last, .body = body, .private = if (name) |token| tree.tokenSlice(token) else null };
        },
        .test_decl => {
            const body = tree.firstToken(tree.nodeData(node).opt_token_and_node[1]);
            return .{ .first = first, .last = last, .body = body, .private = null };
        },
        else => return null,
    }
}

/// Whether a token from `first` to `last` is the builtin `builtin`.
fn calls(tree: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex, builtin: []const u8) bool {
    for (first..last + 1) |token| {
        if (tree.tokenTag(@intCast(token)) == .builtin and std.mem.eql(u8, tree.tokenSlice(@intCast(token)), builtin)) return true;
    }
    return false;
}

/// `node` as written when it is one short line, else what is indexed or
/// called with `[...]` or `(...)` for the rest: `handlers[...]`.
fn shown(arena: Allocator, tree: *const Ast, node: Node.Index) Allocator.Error![]const u8 {
    const source = tree.getNodeSource(node);
    if (source.len <= 48 and std.mem.findScalar(u8, source, '\n') == null) return source;
    if (tree.nodeTag(node) == .array_access) return arena.print("{s}[...]", .{try shown(arena, tree, tree.nodeData(node).node_and_node[0])});
    var buffer: [1]Node.Index = undefined;
    if (tree.fullCall(&buffer, node)) |call| return arena.print("{s}(...)", .{try shown(arena, tree, call.ast.fn_expr)});
    return arena.print("...{s}", .{tree.tokenSlice(tree.lastToken(node))});
}

/// Runs the rule over `source` and compares one line per finding,
/// `line:col modifier callee`, in source order.
fn expectTail(source: [:0]const u8, expected: []const u8) !void {
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
        const loc = report.location(source, finding.offset);
        const t = finding.detail.tail;
        try out.writer.print("{d}:{d} {s} {s}\n", .{ loc.line + 1, loc.column + 1, t.modifier, t.callee });
    }
    try expect.findings(@src(), expected, out.written());
}

test "@call(.always_tail, ...) with nothing that tests the backend (#219)" {
    try expectTail(
        \\pub fn scan(xs: []const u8, start: usize) usize { var i = start; while (i + 4 <= xs.len) : (i += 4) {} return @call(.always_tail, rest, .{ xs, i }); }
        \\fn step(vm: *Vm, ip: usize) void { return @call(.always_tail, handlers[vm.code[ip]], .{ vm, ip + 1 }); }
        \\fn named(vm: *Vm) void { return @call(std.lang.CallModifier.always_tail, next, .{vm}); }
        \\fn old(vm: *Vm) void { return @call(std.builtin.CallModifier.always_tail, next, .{vm}); }
        \\fn recurse(i: c_uint) void { @call(.always_tail, recurse, .{i +% 1}); }
        \\test "tail" { try @call(.always_tail, check, .{}); }
        \\fn long(vm: *Vm) void { return @call(.always_tail, vm.dispatch_table.handlers[@intFromEnum(vm.code[vm.ip])], .{vm}); }
        \\fn unrelated(x: u8) void { if (builtin.mode == .Debug) return; if (builtin.cpu.arch == .x86_64) return; @call(.always_tail, f, .{x}); }
        \\fn made(vm: *Vm) void { return @call(.always_tail, vm.tables.dispatch.forOpcode(vm.code[vm.ip], vm.mode, vm.flags), .{vm}); }
    ,
        \\1:111 .always_tail rest
        \\2:43 .always_tail handlers[vm.code[ip]]
        \\3:33 std.lang.CallModifier.always_tail next
        \\4:31 std.builtin.CallModifier.always_tail next
        \\5:30 .always_tail recurse
        \\6:19 .always_tail check
        \\7:32 .always_tail vm.dispatch_table.handlers[...]
        \\8:105 .always_tail f
        \\9:32 .always_tail vm.tables.dispatch.forOpcode(...)
        \\
    );
}

test "not reported: a modifier held in a name, a test of the backend before the call, a file that refuses a backend" {
    try expectTail(
        \\const tail: std.lang.CallModifier = if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto;
        \\fn fixed(xs: []const u8, i: usize) usize { return @call(tail, rest, .{ xs, i }); }
        \\fn inPlace(vm: *Vm) void { return @call(if (@import("builtin").zig_backend == .stage2_llvm) .always_tail else .auto, next, .{vm}); }
        \\fn branch(vm: *Vm) void { if (builtin.zig_backend == .stage2_llvm) return @call(.always_tail, next, .{vm}); return next(vm); }
        \\fn orElse(vm: *Vm) void { if (builtin.zig_backend != .stage2_llvm) { return next(vm); } else { return @call(.always_tail, next, .{vm}); } }
        \\fn switched(vm: *Vm) void { switch (builtin.zig_backend) { .stage2_llvm => return @call(.always_tail, next, .{vm}), else => return next(vm) } }
        \\fn refused(vm: *Vm) void { if (builtin.zig_backend == .stage2_x86_64) { @compileError("needs LLVM for .always_tail"); } return @call(.always_tail, next, .{vm}); }
        \\const llvm = builtin.zig_backend == .stage2_llvm;
        \\const fast = llvm and !builtin.single_threaded;
        \\fn throughName(vm: *Vm) void { if (fast) return @call(.always_tail, next, .{vm}); return next(vm); }
        \\const quick = slow_ok and true;
        \\const slow_ok = builtin.zig_backend == .stage2_llvm;
        \\fn readFirst(vm: *Vm) void { if (quick) return @call(.always_tail, next, .{vm}); return next(vm); }
        \\fn other(vm: *Vm) void { return @call(.never_tail, next, .{vm}); }
        \\fn auto(vm: *Vm) void { return @call(.auto, next, .{vm}); }
        \\pub const run = if (llvm) runTail else runLoop;
        \\fn runTail(vm: *Vm) void { return @call(.always_tail, next, .{vm}); }
        \\fn chosen(vm: *Vm) void { switch (builtin.zig_backend) { .stage2_llvm => dispatchTail(vm), else => dispatchLoop(vm) } }
        \\fn dispatchTail(vm: *Vm) void { return @call(.always_tail, dispatchTail, .{vm}); }
    , "");
    try expectTail(
        \\comptime { if (builtin.zig_backend != .stage2_llvm) @compileError("this interpreter needs LLVM's tail calls"); }
        \\fn step(vm: *Vm) void { return @call(.always_tail, next, .{vm}); }
    , "");
}

test "reported: a function named once outside a branch on the backend, or pub" {
    try expectTail(
        \\const llvm = builtin.zig_backend == .stage2_llvm;
        \\pub const run = if (llvm) runTail else runLoop;
        \\fn runTail(vm: *Vm) void { return @call(.always_tail, next, .{vm}); }
        \\pub fn start(vm: *Vm) void { runTail(vm); }
        \\pub const go = if (llvm) goTail else goLoop;
        \\pub fn goTail(vm: *Vm) void { return @call(.always_tail, next, .{vm}); }
        \\fn unnamed(vm: *Vm) void { return @call(.always_tail, next, .{vm}); }
        \\comptime { if (llvm) _ = &unnamed; }
        \\comptime { _ = &unnamed; }
        \\comptime { if (builtin.zig_backend == .stage2_llvm) _ = &start; }
        \\fn after(vm: *Vm) void { @call(.always_tail, next, .{vm}); if (builtin.zig_backend == .stage2_llvm) {} }
        \\fn refusing(vm: *Vm) void { if (builtin.zig_backend == .stage2_x86_64) @compileError("needs LLVM"); return @call(.always_tail, next, .{vm}); }
        \\fn Outer() type { if (builtin.zig_backend == .stage2_llvm) {} return struct { fn go(vm: *Vm) void { return @call(.always_tail, next, .{vm}); } }; }
        \\fn alone(vm: *Vm) void { return @call(.always_tail, next, .{vm}); }
    ,
        \\3:35 .always_tail next
        \\6:38 .always_tail next
        \\7:35 .always_tail next
        \\11:26 .always_tail next
        \\13:108 .always_tail next
        \\14:33 .always_tail next
        \\
    );
}

test "the message and the hint" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\pub fn scan(xs: []const u8, i: usize) usize { return @call(.always_tail, rest, .{ xs, i }); }
    , .{});
    defer tree.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var findings: std.ArrayList(Finding) = .empty;
    try check(arena_state.allocator(), &tree, &findings);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (findings.items) |finding| {
        try report.writeMessage(&out.writer, finding);
        try out.writer.print("\n{s}\n", .{finding.hint});
    }
    try expect.findings(@src(),
        \\`@call(.always_tail, rest, ...)` is a tail call or a compile error, and Zig's own x86_64 backend, the Debug default on x86_64 Linux, has no tail calls: every Debug build there fails, while LLVM's, on macOS and in every release mode, pass
        \\ask for it only where the backend has tail calls: `const tail: std.lang.CallModifier = if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto;`, then `@call(tail, ...)`
        \\
    , out.written());
}
