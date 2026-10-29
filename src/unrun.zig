//! Rule eighteen, unrun: a file whose tests never run, because nothing the
//! test build analyses refers to it.
//!
//!     // storage.zig: its own tests run, from `test { _ = storage; }` above it
//!     pub const s3 = @import("storage/s3.zig");
//!     pub const S3 = s3.S3;
//!     test "storage: a key that could leave the store is refused" { ... }
//!
//! Zig analyses a declaration only when something it analyses refers to it,
//! and runs a file's tests only when it analyses the file. None of
//! storage.zig's tests names `s3` or `S3`, so s3.zig is never analysed, and
//! `zig build test` passes without building or running a test of it. It
//! compiles clean in every build mode; `test { _ = s3; }` in storage.zig
//! runs them. A module the test build imports by name never runs its tests
//! in it, however much of it the build uses, so that is no way in.
//!
//! The only rule that reads more than one file: it asks which of the files
//! checked the tests reach. It starts from the roots, the files whose tests
//! the build runs without anything referring to them: a `.zig` path a build
//! script names (a `build.zig`, or a file with a `*std.Build` parameter),
//! every file under a directory one opens, and, as nothing shows where else
//! the roots are, every file of an import cycle that nothing outside it
//! imports, such as a file nothing imports. A root's tests reach what they
//! name, and a declaration reached reaches what it names, all of it: a
//! function's body, a type's members and their tests. `alias.Name`, with
//! `alias` a constant `@import("x.zig")`, reaches `Name` in x.zig; `_ =
//! alias;` reaches x.zig alone, its tests; and an import used as a value,
//! as an argument (`refAllDecls(alias)`, `@typeInfo(alias)`), a type or a
//! local constant, reaches every pub declaration of x.zig, as reflection
//! over it may, and every declaration if x.zig is its own file.
//! `refAllDecls(@This())` reaches the pub ones of its own file, and
//! `refAllDeclsRecursive` those of the files they import too. In the
//! standard library, `@import("std")` is the std.zig above the file.
//!
//! Reported, at its first test: a file with tests that something checked
//! imports by path and nothing reached refers to. Every guess errs toward
//! reached, so the rule misses rather than reports: a name is taken to mean
//! the file's declaration of it wherever it is used, and code a comptime
//! condition rules out is counted. Not seen: a root only the build's own
//! logic names (`b.path(b.fmt(...))`), a file outside those checked, a
//! test run some other way (`zig test` in a script), and a module that
//! names itself, `@import("mylib")` inside mylib, which only the build maps
//! to a file. Name the project's directory, build.zig with it, for the
//! build's roots to be seen.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const cached = @import("cached.zig");
const children = @import("children.zig");
const expect = @import("expect.zig");
const report = @import("report.zig");
const Finding = report.Finding;

/// What one file holds that the rule asks about. It outlives the file's
/// tree: every string is copied.
pub const Summary = struct {
    /// As zigvet prints it.
    path: []const u8,
    /// Its tests at the top level, and where the first one's `test` is.
    tests: usize = 0,
    first_test: usize = 0,
    decls: []const Decl = &.{},
    /// What is analysed with the file: its tests, `comptime` blocks,
    /// fields and exported declarations.
    always: []const Chain = &.{},
    /// Every file it imports by path, anywhere in it.
    imports: []const Import = &.{},
    /// Whether it imports `std`, which is a file checked here too when the
    /// standard library is: std.zig, in a directory above it.
    imports_std: bool = false,
    /// As a build script: the `.zig` paths it names, and the directories
    /// it opens, as written. Null when it is not one.
    build: ?Build = null,
    /// Its tree had parse errors: nothing more is known of it.
    unparsed: bool = false,
};

pub const Import = struct {
    /// Resolved against the importing file's directory, as walk cleans a
    /// path.
    path: []const u8,
    /// The string literal's contents, for the hint.
    written: []const u8,
};

pub const Build = struct {
    paths: []const []const u8,
    dirs: []const []const u8,
};

/// A top-level declaration with a name.
pub const Decl = struct {
    name: []const u8,
    public: bool,
    /// Its initializer, when that is a chain: what it stands for, should it
    /// name a file.
    init: ?Chain,
    /// What it names, its initializer included.
    refs: []const Chain,
};

/// A name, an `@import`, or `@This()` of the file, and the fields after it:
/// `s3.S3.init` is the name `s3` and the fields `S3` and `init`.
pub const Chain = struct {
    root: Root,
    fields: []const []const u8,
    use: Use,

    pub const Root = union(enum) {
        name: []const u8,
        /// A path, resolved as `Import.path`.
        file: []const u8,
        /// `@This()` outside any type the file declares.
        self,
        /// `@import("std")`.
        std,
    };

    /// What a chain that ends on a file does with it.
    pub const Use = enum {
        /// Names it: `_ = alias;`, a top-level constant's initializer, a
        /// callee. Its tests run, and nothing in it is reached.
        plain,
        /// Uses it as a value, which reflection over it may turn into a
        /// reference to every declaration in it another file can name, or,
        /// in its own file, every one.
        whole,
        /// `refAllDecls`'s argument: every pub declaration in it.
        public,
        /// `refAllDeclsRecursive`'s argument: every pub declaration in it,
        /// and in every file those import.
        deep,
    };
};

/// Reads what `tree`, the file at `path`, declares, tests and refers to.
/// The summary is allocated with `arena`, and the scan's working memory
/// with `gpa`, freed before it returns.
pub fn summarize(gpa: Allocator, arena: Allocator, path: []const u8, tree: *const Ast) Allocator.Error!Summary {
    if (tree.errors.len > 0) return .{ .path = try arena.dupe(u8, path), .unparsed = true };
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    var scan: Scan = .{
        .arena = arena,
        .scratch = scratch_state.allocator(),
        .tree = tree,
        .dir = std.fs.path.dirname(path) orelse ".",
        .build = std.mem.eql(u8, std.fs.path.basename(path), "build.zig") or hasBuildParam(tree),
    };
    for (tree.rootDecls()) |member| if (declName(tree, member)) |name| try scan.names.put(scan.scratch, name, {});
    var summary: Summary = .{ .path = try arena.dupe(u8, path) };
    var decls: std.ArrayList(Decl) = .empty;
    var always: Set = .{};
    for (tree.rootDecls()) |member| {
        switch (tree.nodeTag(member)) {
            .test_decl => {
                if (summary.tests == 0) summary.first_test = tree.tokenStart(tree.nodeMainToken(member));
                summary.tests += 1;
                try scan.walk(&always, member, .whole, false);
                continue;
            },
            .fn_decl => {
                var buffer: [1]Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, member).?;
                if (proto.extern_export_inline_token) |t| if (tree.tokenTag(t) == .keyword_export) {
                    try scan.walk(&always, member, .whole, false);
                    continue;
                };
                if (proto.name_token) |name| {
                    var refs: Set = .{};
                    try scan.walk(&refs, member, .whole, false);
                    try decls.append(arena, .{
                        .name = try arena.dupe(u8, identifier(tree, name)),
                        .public = proto.visib_token != null,
                        .init = null,
                        .refs = refs.list.items,
                    });
                    continue;
                }
            },
            else => if (tree.fullVarDecl(member)) |decl| {
                if (decl.extern_export_token) |t| if (tree.tokenTag(t) == .keyword_export) {
                    try scan.walk(&always, member, .whole, false);
                    continue;
                };
                var refs: Set = .{};
                if (decl.ast.type_node.unwrap()) |t| try scan.walk(&refs, t, .whole, false);
                var init: ?Chain = null;
                if (decl.ast.init_node.unwrap()) |node| {
                    if (try scan.chain(node, .plain, false)) |c| init = try scan.keep(c);
                    try scan.walk(&refs, node, .plain, false);
                }
                try decls.append(arena, .{
                    .name = try arena.dupe(u8, identifier(tree, decl.ast.mut_token + 1)),
                    .public = decl.visib_token != null,
                    .init = init,
                    .refs = refs.list.items,
                });
                continue;
            },
        }
        // A field, a `comptime` block, an extern function.
        try scan.walk(&always, member, .whole, false);
    }
    summary.decls = decls.items;
    summary.always = always.list.items;
    summary.imports = scan.imports.items;
    summary.imports_std = scan.imports_std;
    if (scan.build) summary.build = .{ .paths = scan.build_paths.items, .dirs = scan.build_dirs.items };
    return summary;
}

/// The name a top-level `member` declares, if it declares one.
fn declName(tree: *const Ast, member: Node.Index) ?[]const u8 {
    if (tree.nodeTag(member) == .fn_decl) {
        var buffer: [1]Node.Index = undefined;
        return identifier(tree, tree.fullFnProto(&buffer, member).?.name_token orelse return null);
    }
    const decl = tree.fullVarDecl(member) orelse return null;
    return identifier(tree, decl.ast.mut_token + 1);
}

fn hasBuildParam(tree: *const Ast) bool {
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]Node.Index = undefined;
        if (cached.buildParam(tree, tree.fullFnProto(&buffer, node).?) != null) return true;
    }
    return false;
}

/// Chains, each once: the list kept, the keys seen while scanning.
const Set = struct {
    list: std.ArrayList(Chain) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
};

const Scan = struct {
    /// What the summary keeps.
    arena: Allocator,
    /// What the scan needs only while it runs.
    scratch: Allocator,
    tree: *const Ast,
    /// The directory of the file, which its imports are relative to.
    dir: []const u8,
    /// The names the file declares at the top level: a chain from any
    /// other name, a local's or a parameter's, names nothing to reach.
    names: std.StringHashMapUnmanaged(void) = .empty,
    imports: std.ArrayList(Import) = .empty,
    imported: std.StringHashMapUnmanaged(void) = .empty,
    imports_std: bool = false,
    build: bool,
    build_paths: std.ArrayList([]const u8) = .empty,
    build_dirs: std.ArrayList([]const u8) = .empty,
    /// A chain's key in a `Set`, reused.
    key: std.ArrayList(u8) = .empty,

    /// Adds to `set` every chain in `node`, in a type the file declares
    /// when `nested`, as `use` says the outermost one is used.
    fn walk(scan: *Scan, set: *Set, node: Node.Index, use: Chain.Use, nested: bool) Allocator.Error!void {
        const tree = scan.tree;
        // Nothing under a chain names more: its root is a name, or an
        // `@import` of a string.
        if (try scan.chain(node, use, nested)) |c| return scan.add(set, c);
        switch (tree.nodeTag(node)) {
            .field_access, .unwrap_optional => {
                // A chain off something that is not a name: `f().x`.
                return scan.walk(set, tree.nodeData(node).node_and_token[0], .plain, nested);
            },
            .assign => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                if (tree.nodeTag(lhs) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(lhs)), "_"))
                    return scan.walk(set, rhs, .plain, nested);
            },
            .call_one, .call_one_comma, .call, .call_comma => {
                var buffer: [1]Node.Index = undefined;
                const call = tree.fullCall(&buffer, node).?;
                try scan.walk(set, call.ast.fn_expr, .plain, nested);
                const callee = lastName(tree, call.ast.fn_expr);
                const arg_use: Chain.Use = if (std.mem.eql(u8, callee, "refAllDeclsRecursive"))
                    .deep
                else if (std.mem.eql(u8, callee, "refAllDecls")) .public else .whole;
                for (call.ast.params) |param| try scan.walk(set, param, arg_use, nested);
                if (scan.build and std.mem.eql(u8, callee, "openDir")) {
                    for (call.ast.params) |param| if (literal(tree, param)) |dir| try scan.build_dirs.append(scan.arena, try scan.arena.dupe(u8, dir));
                }
                return;
            },
            .string_literal => if (scan.build) {
                if (literal(tree, node)) |text| if (std.mem.endsWith(u8, text, ".zig")) try scan.build_paths.append(scan.arena, try scan.arena.dupe(u8, text));
                return;
            },
            else => {},
        }
        var buffer: [2]Node.Index = undefined;
        const inner = nested or tree.fullContainerDecl(&buffer, node) != null;
        var kids: std.ArrayList(Node.Index) = .empty;
        defer kids.deinit(scan.scratch);
        try children.append(scan.scratch, tree, node, &kids);
        for (kids.items) |kid| try scan.walk(set, kid, .whole, inner);
    }

    /// `node` as a chain: a name, `@import` of a `.zig` file or `@This()`
    /// of the file, and the fields after it, allocated with `scratch`.
    /// Records an `@import` it starts from. Null for anything else.
    fn chain(scan: *Scan, node: Node.Index, use: Chain.Use, nested: bool) Allocator.Error!?Chain {
        const tree = scan.tree;
        var fields: std.ArrayList([]const u8) = .empty;
        var base = node;
        while (tree.nodeTag(base) == .field_access) {
            const lhs, const name = tree.nodeData(base).node_and_token;
            try fields.append(scan.scratch, identifier(tree, name));
            base = lhs;
        }
        std.mem.reverse([]const u8, fields.items);
        const root: Chain.Root = switch (tree.nodeTag(base)) {
            .identifier => root: {
                const name = identifier(tree, tree.nodeMainToken(base));
                if (std.mem.eql(u8, name, "_")) return null;
                break :root .{ .name = name };
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => root: {
                const builtin = tree.tokenSlice(tree.nodeMainToken(base));
                if (std.mem.eql(u8, builtin, "@This")) {
                    if (nested) return null;
                    break :root .self;
                }
                if (!std.mem.eql(u8, builtin, "@import")) return null;
                var buffer: [2]Node.Index = undefined;
                const params = tree.builtinCallParams(&buffer, base).?;
                if (params.len != 1) return null;
                const written = literal(tree, params[0]) orelse return null;
                if (std.mem.eql(u8, written, "std")) {
                    scan.imports_std = true;
                    break :root .std;
                }
                // A module, by name: its tests never run in this one.
                if (!std.mem.endsWith(u8, written, ".zig")) return null;
                const path = try std.fs.path.resolveAlloc(scan.scratch, &.{ scan.dir, written });
                const entry = try scan.imported.getOrPut(scan.scratch, path);
                if (!entry.found_existing) try scan.imports.append(scan.arena, .{
                    .path = try scan.arena.dupe(u8, path),
                    .written = try scan.arena.dupe(u8, written),
                });
                break :root .{ .file = path };
            },
            else => return null,
        };
        return .{ .root = root, .fields = fields.items, .use = use };
    }

    /// Adds `c` to `set`, kept, unless it holds it already.
    fn add(scan: *Scan, set: *Set, c: Chain) Allocator.Error!void {
        if (c.root == .name and !scan.names.contains(c.root.name)) return;
        const s = scan.scratch;
        scan.key.clearRetainingCapacity();
        try scan.key.append(s, @backingInt(c.use));
        switch (c.root) {
            .name => |name| try scan.key.print(s, "n{s}", .{name}),
            .file => |path| try scan.key.print(s, "f{s}", .{path}),
            .self => try scan.key.append(s, 's'),
            .std => try scan.key.append(s, 'S'),
        }
        for (c.fields) |field| try scan.key.print(s, ".{s}", .{field});
        const entry = try set.seen.getOrPut(s, scan.key.items);
        if (entry.found_existing) return;
        entry.key_ptr.* = try s.dupe(u8, scan.key.items);
        try set.list.append(scan.arena, try scan.keep(c));
    }

    /// `c` copied out of the scan's memory into the summary's.
    fn keep(scan: *Scan, c: Chain) Allocator.Error!Chain {
        const a = scan.arena;
        const fields = try a.alloc([]const u8, c.fields.len);
        for (fields, c.fields) |*kept, field| kept.* = try a.dupe(u8, field);
        return .{
            .root = switch (c.root) {
                .name => |name| .{ .name = try a.dupe(u8, name) },
                .file => |path| .{ .file = try a.dupe(u8, path) },
                .self => .self,
                .std => .std,
            },
            .fields = fields,
            .use = c.use,
        };
    }
};

/// A plain string literal's contents, in the source. Null for anything
/// else, or one with an escape, which no path here needs.
fn literal(tree: *const Ast, node: Node.Index) ?[]const u8 {
    if (tree.nodeTag(node) != .string_literal) return null;
    const text = tree.tokenSlice(tree.nodeMainToken(node));
    if (std.mem.findScalar(u8, text, '\\') != null) return null;
    return text[1 .. text.len - 1];
}

/// The last name in `node`: `refAllDecls` of `std.testing.refAllDecls`.
fn lastName(tree: *const Ast, node: Node.Index) []const u8 {
    return switch (tree.nodeTag(node)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
        else => "",
    };
}

/// The name `token` spells, `@"x"` as `x`, in the source.
fn identifier(tree: *const Ast, token: Ast.TokenIndex) []const u8 {
    const text = tree.tokenSlice(token);
    if (std.mem.startsWith(u8, text, "@\"") and std.mem.findScalar(u8, text, '\\') == null)
        return text[2 .. text.len - 1];
    return text;
}

/// One finding for each file in `files` with tests that nothing reached
/// refers to, by the file's index. Allocated with `arena`.
pub fn check(arena: Allocator, files: []const Summary) Allocator.Error![]?Finding {
    var r: Reach = try .init(arena, files);
    try r.markRoots();
    while (r.work.pop()) |item| switch (item) {
        .chains => |c| for (c.list) |each| try r.follow(c.file, each),
        .whole => |w| try r.whole(w.file, w.whole),
    };

    const found = try arena.alloc(?Finding, files.len);
    @memset(found, null);
    for (files, 0..) |file, f| {
        if (file.tests == 0 or r.analysed[f] or r.root[f]) continue;
        // The importer named in the hint: one whose tests run, if any does.
        var importer: ?usize = null;
        for (r.importers[f].items) |i| {
            if (importer == null or (r.analysed[i] and !r.analysed[importer.?])) importer = i;
        }
        const by = importer orelse continue;
        found[f] = .{
            .offset = file.first_test,
            .hint = try hint(arena, files[by], file.path, r.analysed[by]),
            .detail = .{ .unrun = .{ .tests = file.tests } },
        };
    }
    return found;
}

/// How to reach `path` from `importer`, whose tests run if `runs`: by
/// the constant that imports it, if one does.
fn hint(arena: Allocator, importer: Summary, path: []const u8, runs: bool) Allocator.Error![]const u8 {
    const reference = reference: {
        for (importer.decls) |decl| {
            const init = decl.init orelse continue;
            if (init.fields.len == 0 and init.root == .file and std.mem.eql(u8, init.root.file, path))
                break :reference try arena.print("_ = {s};", .{decl.name});
        }
        for (importer.imports) |import| {
            if (std.mem.eql(u8, import.path, path))
                break :reference try arena.print("_ = @import(\"{s}\");", .{import.written});
        }
        break :reference "_ = @import(\"std\");";
    };
    const where = if (importer.tests == 0)
        try arena.print("add `test {{ {s} }}` to {s}", .{ reference, importer.path })
    else
        try arena.print("add `{s}` to a test block in {s}", .{ reference, importer.path });
    if (runs) return where;
    return arena.print("{s}, and reach that file from a test too", .{where});
}

const Reach = struct {
    arena: Allocator,
    files: []const Summary,
    by_path: std.StringHashMapUnmanaged(usize),
    by_name: []std.StringHashMapUnmanaged(usize),
    /// What each file imports by path, and what imports it, of the files
    /// checked.
    imports: []std.ArrayList(usize),
    importers: []std.ArrayList(usize),
    /// The std.zig each file's `@import("std")` is, if it is one checked.
    std_of: []?usize,
    root: []bool,
    analysed: []bool,
    reached: [][]bool,
    /// What `whole` has been asked of each file already.
    wholes: []std.EnumSet(Whole),
    work: std.ArrayList(Item) = .empty,

    const Item = union(enum) {
        chains: struct { file: usize, list: []const Chain },
        whole: struct { file: usize, whole: Whole },
    };

    /// Which declarations of a file `whole` reaches.
    const Whole = enum {
        all,
        public,
        /// Every pub one, and those of each file a pub one imports.
        deep,
    };

    fn init(arena: Allocator, files: []const Summary) Allocator.Error!Reach {
        var r: Reach = .{
            .arena = arena,
            .files = files,
            .by_path = .empty,
            .by_name = try arena.alloc(std.StringHashMapUnmanaged(usize), files.len),
            .imports = try arena.alloc(std.ArrayList(usize), files.len),
            .importers = try arena.alloc(std.ArrayList(usize), files.len),
            .std_of = try arena.alloc(?usize, files.len),
            .root = try arena.alloc(bool, files.len),
            .analysed = try arena.alloc(bool, files.len),
            .reached = try arena.alloc([]bool, files.len),
            .wholes = try arena.alloc(std.EnumSet(Whole), files.len),
        };
        @memset(r.root, false);
        @memset(r.analysed, false);
        @memset(r.wholes, .empty);
        for (files, 0..) |file, f| {
            try r.by_path.put(arena, file.path, f);
            r.by_name[f] = .empty;
            for (file.decls, 0..) |decl, d| try r.by_name[f].put(arena, decl.name, d);
            r.imports[f] = .empty;
            r.importers[f] = .empty;
            r.reached[f] = try arena.alloc(bool, file.decls.len);
            @memset(r.reached[f], false);
        }
        // `@import("std")` is no edge: a program beside the standard library,
        // a benchmark, imports it as a module of its own.
        for (files, 0..) |file, f| {
            r.std_of[f] = if (file.imports_std) try r.stdAbove(file.path) else null;
            for (file.imports) |import| if (r.by_path.get(import.path)) |t| try r.edge(f, t);
        }
        return r;
    }

    fn edge(r: *Reach, f: usize, t: usize) Allocator.Error!void {
        if (t == f or std.mem.findScalar(usize, r.imports[f].items, t) != null) return;
        try r.imports[f].append(r.arena, t);
        try r.importers[t].append(r.arena, f);
    }

    /// The std.zig checked in the directory of `path` or the nearest one
    /// above it: the standard library's own files import it as `std`.
    fn stdAbove(r: *Reach, path: []const u8) Allocator.Error!?usize {
        var dir = std.fs.path.dirname(path);
        while (true) {
            const candidate = try std.fs.path.resolveAlloc(r.arena, &.{ dir orelse ".", "std.zig" });
            if (r.by_path.get(candidate)) |t| return t;
            dir = std.fs.path.dirname(dir orelse return null);
        }
    }

    /// The files whose tests run with nothing referring to them, analysed.
    fn markRoots(r: *Reach) Allocator.Error!void {
        const files = r.files;
        // A file that does not parse may import anything.
        for (files, 0..) |file, f| if (file.unparsed) {
            r.root[f] = true;
        };
        for (files) |file| {
            const build = file.build orelse continue;
            // A build helper's `b.path` is relative to the build root, a
            // directory above it with a build.zig.
            var bases: std.ArrayList([]const u8) = .empty;
            try bases.append(r.arena, std.fs.path.dirname(file.path) orelse ".");
            for (files) |other| {
                if (!std.mem.eql(u8, std.fs.path.basename(other.path), "build.zig")) continue;
                const dir = std.fs.path.dirname(other.path) orelse ".";
                if (within(file.path, dir)) try bases.append(r.arena, dir);
            }
            for (bases.items) |base| {
                for (build.paths) |path| {
                    const resolved = try std.fs.path.resolveAlloc(r.arena, &.{ base, path });
                    if (r.by_path.get(resolved)) |t| r.root[t] = true;
                }
                for (build.dirs) |dir| {
                    const resolved = try std.fs.path.resolveAlloc(r.arena, &.{ base, dir });
                    for (files, 0..) |under, t| if (within(under.path, resolved)) {
                        r.root[t] = true;
                    };
                }
            }
        }
        try r.cycleRoots();
        for (r.root, 0..) |is_root, f| if (is_root) try r.analyse(f);
    }

    /// Makes roots of every file of each import cycle, or lone file, that
    /// nothing outside it imports and that holds no root already.
    fn cycleRoots(r: *Reach) Allocator.Error!void {
        const n = r.files.len;
        const component = try sccs(r.arena, r.imports);
        const imported = try r.arena.alloc(bool, n);
        const rooted = try r.arena.alloc(bool, n);
        @memset(imported, false);
        @memset(rooted, false);
        for (0..n) |t| {
            if (r.root[t]) rooted[component[t]] = true;
            for (r.importers[t].items) |f| if (component[f] != component[t]) {
                imported[component[t]] = true;
            };
        }
        for (0..n) |f| {
            const c = component[f];
            if (!imported[c] and !rooted[c]) r.root[f] = true;
        }
    }

    fn analyse(r: *Reach, f: usize) Allocator.Error!void {
        if (r.analysed[f]) return;
        r.analysed[f] = true;
        try r.work.append(r.arena, .{ .chains = .{ .file = f, .list = r.files[f].always } });
    }

    fn reach(r: *Reach, f: usize, d: usize) Allocator.Error!void {
        try r.analyse(f);
        if (r.reached[f][d]) return;
        r.reached[f][d] = true;
        try r.work.append(r.arena, .{ .chains = .{ .file = f, .list = r.files[f].decls[d].refs } });
    }

    fn whole(r: *Reach, f: usize, which: Whole) Allocator.Error!void {
        if (r.wholes[f].contains(which)) return;
        r.wholes[f].insert(which);
        try r.analyse(f);
        for (r.files[f].decls, 0..) |decl, d| {
            if (which != .all and !decl.public) continue;
            try r.reach(f, d);
            if (which == .deep) if (r.aliasOf(f, d, 0)) |t| try r.work.append(r.arena, .{ .whole = .{ .file = t, .whole = .deep } });
        }
    }

    /// Reaches what `c`, in file `f`, names.
    fn follow(r: *Reach, f: usize, c: Chain) Allocator.Error!void {
        var target: ?usize = switch (c.root) {
            .name => |name| target: {
                const d = r.by_name[f].get(name) orelse return;
                try r.reach(f, d);
                break :target r.aliasOf(f, d, 0);
            },
            .file => |path| target: {
                const t = r.by_path.get(path) orelse return;
                try r.analyse(t);
                break :target t;
            },
            .self => f,
            .std => target: {
                const t = r.std_of[f] orelse return;
                try r.analyse(t);
                break :target t;
            },
        };
        for (c.fields) |field| {
            const t = target orelse return;
            const d = r.by_name[t].get(field) orelse return;
            try r.reach(t, d);
            target = r.aliasOf(t, d, 0);
        }
        const t = target orelse return;
        const which: Whole = switch (c.use) {
            .plain => return r.analyse(t),
            // Another file names only its pub declarations.
            .whole => if (t == f) .all else .public,
            .public => .public,
            .deep => .deep,
        };
        try r.work.append(r.arena, .{ .whole = .{ .file = t, .whole = which } });
    }

    /// The file declaration `d` of file `f` stands for, if it stands for
    /// one: `const s3 = @import("s3.zig");`, or `const T = other.s3;`.
    fn aliasOf(r: *Reach, f: usize, d: usize, depth: u8) ?usize {
        if (depth > 16) return null;
        const c = r.files[f].decls[d].init orelse return null;
        var target: ?usize = switch (c.root) {
            .name => |name| r.aliasOf(f, r.by_name[f].get(name) orelse return null, depth + 1),
            .file => |path| r.by_path.get(path),
            .self => f,
            .std => r.std_of[f],
        };
        for (c.fields) |field| {
            const t = target orelse return null;
            target = r.aliasOf(t, r.by_name[t].get(field) orelse return null, depth + 1);
        }
        return target;
    }
};

/// Whether `path` is `dir` or inside it, both cleaned as walk cleans them.
fn within(path: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, dir, ".")) return !std.fs.path.isAbsolute(path) and !std.mem.startsWith(u8, path, "..");
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or std.fs.path.isSep(path[dir.len]);
}

/// The strongly connected component of each file in the graph of
/// `imports`, numbered from 0. Tarjan's algorithm, with its own stack.
fn sccs(arena: Allocator, imports: []const std.ArrayList(usize)) Allocator.Error![]usize {
    const n = imports.len;
    const unvisited = std.math.maxInt(usize);
    const index = try arena.alloc(usize, n);
    const low = try arena.alloc(usize, n);
    const on_stack = try arena.alloc(bool, n);
    const component = try arena.alloc(usize, n);
    @memset(index, unvisited);
    @memset(on_stack, false);
    var stack: std.ArrayList(usize) = .empty;
    const Frame = struct { file: usize, next: usize };
    var frames: std.ArrayList(Frame) = .empty;
    var counter: usize = 0;
    var components: usize = 0;
    for (0..n) |start| {
        if (index[start] != unvisited) continue;
        try frames.append(arena, .{ .file = start, .next = 0 });
        index[start] = counter;
        low[start] = counter;
        counter += 1;
        try stack.append(arena, start);
        on_stack[start] = true;
        while (frames.items.len > 0) {
            const frame = &frames.items[frames.items.len - 1];
            const v = frame.file;
            const next = imports[v].items;
            if (frame.next < next.len) {
                const w = next[frame.next];
                frame.next += 1;
                if (index[w] == unvisited) {
                    index[w] = counter;
                    low[w] = counter;
                    counter += 1;
                    try stack.append(arena, w);
                    on_stack[w] = true;
                    try frames.append(arena, .{ .file = w, .next = 0 });
                } else if (on_stack[w]) low[v] = @min(low[v], index[w]);
                continue;
            }
            _ = frames.pop();
            if (frames.items.len > 0) {
                const parent = frames.items[frames.items.len - 1].file;
                low[parent] = @min(low[parent], low[v]);
            }
            if (low[v] == index[v]) {
                while (stack.pop()) |w| {
                    on_stack[w] = false;
                    component[w] = components;
                    if (w == v) break;
                }
                components += 1;
            }
        }
    }
    return component;
}

/// Runs the rule over `sources`, each a path and its source, and compares
/// one line per finding, `path:line:col tests | hint`, in their order.
/// The paths are cleaned as walk cleans them, which on Windows makes every
/// separator `\`, and are compared with `/`.
fn expectUnrun(sources: []const [2][:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const summaries = try arena.alloc(Summary, sources.len);
    for (sources, summaries) |file, *summary| {
        var tree = try Ast.parse(gpa, file[1], .{});
        defer tree.deinit(gpa);
        try std.testing.expectEqual(0, tree.errors.len);
        summary.* = try summarize(gpa, arena, try std.fs.path.resolveAlloc(arena, &.{file[0]}), &tree);
    }
    const found = try check(arena, summaries);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (found, sources) |maybe, file| {
        const finding = maybe orelse continue;
        const loc = report.location(file[1], finding.offset);
        try out.writer.print("{s}:{d}:{d} {d} | {s}\n", .{ file[0], loc.line + 1, loc.column + 1, finding.detail.unrun.tests, finding.hint });
    }
    std.mem.replaceScalar(u8, out.written(), std.fs.path.sep, '/');
    try expect.findings(@src(), expected, out.written());
}

/// A file of `S3`, whose tests run when it is analysed, as `zig test`
/// shows of every case below (Zig 0.17.0).
const s3_source =
    \\const std = @import("std");
    \\pub const S3 = struct { n: u32 };
    \\pub fn g() u32 { return 1; }
    \\test "s3" { try std.testing.expect(g() == 1); }
    \\
;

test "a file whose importer's tests never name it (#108)" {
    // ekur's storage.zig before 851b8c9.
    try expectUnrun(&.{
        .{
            "root.zig",
            \\pub const storage = @import("storage.zig");
            \\test { _ = storage; }
            \\
        },
        .{
            "storage.zig",
            \\pub const s3 = @import("storage/s3.zig");
            \\pub const S3 = s3.S3;
            \\pub fn checkKey(k: []const u8) bool { return k.len > 0; }
            \\test "storage" { _ = checkKey("a"); }
            \\
        },
        .{ "storage/s3.zig", s3_source },
    },
        \\storage/s3.zig:4:1 1 | add `_ = s3;` to a test block in storage.zig
        \\
    );
}

test "not reported: what a test reaches refers to the file, as zig test runs its tests" {
    // A test names a declaration of it; a test calls a function whose
    // return type is from it; it is a type a test uses; an import in a
    // function a test calls; `_ = alias;`; refAllDecls over a pub import.
    try expectUnrun(&.{
        .{
            "a/root.zig",
            \\pub const s3 = @import("s3.zig");
            \\pub const S3 = s3.S3;
            \\test { const x: S3 = .{ .n = 1 }; _ = x; }
            \\
        },
        .{ "a/s3.zig", s3_source },
        .{
            "e/root.zig",
            \\const s3 = @import("s3.zig");
            \\fn make() s3.S3 { return .{ .n = 1 }; }
            \\test { _ = make(); }
            \\
        },
        .{ "e/s3.zig", s3_source },
        .{
            "k/root.zig",
            \\const Foo = @import("s3.zig");
            \\test { var x: Foo = undefined; _ = &x; }
            \\
        },
        .{ "k/s3.zig", s3_source },
        .{
            "m/root.zig",
            \\fn f() u32 { const m = @import("s3.zig"); return m.g(); }
            \\test { _ = f(); }
            \\
        },
        .{ "m/s3.zig", s3_source },
        .{
            "b/root.zig",
            \\const s3 = @import("s3.zig");
            \\test { _ = s3; }
            \\
        },
        .{ "b/s3.zig", s3_source },
        .{
            "c/root.zig",
            \\pub const s3 = @import("s3.zig");
            \\test { @import("std").testing.refAllDecls(@This()); }
            \\
        },
        .{ "c/s3.zig", s3_source },
    }, "");
}

test "an import nothing a test reaches names, a pub fn no test calls" {
    try expectUnrun(&.{
        .{
            "l/root.zig",
            \\const s3 = @import("s3.zig");
            \\test "names nothing" {}
            \\
        },
        .{ "l/s3.zig", s3_source },
        .{
            "n/root.zig",
            \\const s3 = @import("s3.zig");
            \\pub fn api() u32 { return s3.g(); }
            \\test "names nothing in s3" {}
            \\
        },
        .{ "n/s3.zig", s3_source },
    },
        \\l/s3.zig:4:1 1 | add `_ = s3;` to a test block in l/root.zig
        \\n/s3.zig:4:1 1 | add `_ = s3;` to a test block in n/root.zig
        \\
    );
}

test "refAllDecls reaches pub declarations only; refAllDeclsRecursive the files they import too" {
    try expectUnrun(&.{
        .{
            "d/root.zig",
            \\const s3 = @import("s3.zig");
            \\test { @import("std").testing.refAllDecls(@This()); }
            \\
        },
        .{ "d/s3.zig", s3_source },
        .{
            "r/root.zig",
            \\pub const mid = @import("mid.zig");
            \\test { @import("std").testing.refAllDeclsRecursive(@This()); }
            \\
        },
        .{
            "r/mid.zig",
            \\pub const s3 = @import("s3.zig");
            \\
        },
        .{ "r/s3.zig", s3_source },
    },
        \\d/s3.zig:4:1 1 | add `_ = s3;` to a test block in d/root.zig
        \\
    );
}

test "roots: a path a build script names, a directory it opens, a path a build helper names" {
    // Each file here would be reported if it were not a root: lib.zig's
    // importer is an executable's root, whose `main` no test reaches;
    // util.zig's importer's tests do not name it; extra.zig's importer is
    // never reached.
    try expectUnrun(&.{
        .{
            "build.zig",
            \\const std = @import("std");
            \\pub fn build(b: *std.Build) void {
            \\    _ = b.path("src/main.zig");
            \\    _ = b.path("src/lib.zig");
            \\    var dir = b.root.openDir(b.graph.io, "test", .{ .iterate = true }) catch return;
            \\    defer dir.close(b.graph.io);
            \\}
            \\
        },
        .{
            "build/helper.zig",
            \\const std = @import("std");
            \\pub fn add(b: *std.Build) void {
            \\    _ = b.path("src/extra.zig");
            \\}
            \\
        },
        .{
            "src/main.zig",
            \\const lib = @import("lib.zig");
            \\const extra = @import("extra.zig");
            \\pub fn main() void { _ = lib.s3; _ = extra; }
            \\
        },
        .{
            "src/lib.zig",
            \\pub const s3 = @import("s3.zig");
            \\test { _ = s3; }
            \\
        },
        .{ "src/s3.zig", s3_source },
        .{ "src/extra.zig", "test \"extra\" {}\n" },
        .{
            "test/a_test.zig",
            \\const util = @import("util.zig");
            \\test "names nothing" {}
            \\
        },
        .{ "test/util.zig", "test \"util\" {}\n" },
    }, "");
}

test "roots: an import cycle nothing outside it imports, unless a build script names a root in it" {
    try expectUnrun(&.{
        .{
            "loop/a.zig",
            \\const b = @import("b.zig");
            \\test "a" {}
            \\
        },
        .{
            "loop/b.zig",
            \\const a = @import("a.zig");
            \\test "b" {}
            \\
        },
        .{
            "named/build.zig",
            \\const std = @import("std");
            \\pub fn build(b: *std.Build) void { _ = b.path("a.zig"); }
            \\
        },
        .{
            "named/a.zig",
            \\const b = @import("b.zig");
            \\test "a" {}
            \\
        },
        .{
            "named/b.zig",
            \\const a = @import("a.zig");
            \\test "b" {}
            \\
        },
    },
        \\named/b.zig:2:1 1 | add `_ = b;` to a test block in named/a.zig
        \\
    );
}

test "the standard library's own @import(\"std\") is its std.zig" {
    // std/debug/Info.zig names MachOFile as `std.debug.MachOFile`.
    try expectUnrun(&.{
        .{
            "build.zig",
            \\const std = @import("std");
            \\pub fn build(b: *std.Build) void { _ = b.path("std/std.zig"); }
            \\
        },
        .{
            "std/std.zig",
            \\pub const debug = @import("debug.zig");
            \\test { _ = debug; }
            \\
        },
        .{
            "std/debug.zig",
            \\pub const MachOFile = @import("debug/MachOFile.zig");
            \\pub const Info = @import("debug/Info.zig");
            \\test { _ = Info; }
            \\
        },
        .{
            "std/debug/Info.zig",
            \\const std = @import("std");
            \\const MachOFile = std.debug.MachOFile;
            \\macho: MachOFile,
            \\test "info" {}
            \\
        },
        .{ "std/debug/MachOFile.zig", "test \"macho\" {}\n" },
    }, "");
}

test "@This() in a type the file declares is the type, not the file" {
    // `g(Self)` would reach every declaration of a.zig, s3 with them, if
    // Self were the file.
    try expectUnrun(&.{
        .{
            "root.zig",
            \\const a = @import("a.zig");
            \\test { _ = a.Inner; }
            \\
        },
        .{
            "a.zig",
            \\pub const s3 = @import("s3.zig");
            \\pub const Inner = struct {
            \\    const Self = @This();
            \\    fn f() void { g(Self); }
            \\};
            \\fn g(comptime T: type) void { _ = T; }
            \\test "a" {}
            \\
        },
        .{ "s3.zig", s3_source },
    },
        \\s3.zig:4:1 1 | add `_ = s3;` to a test block in a.zig
        \\
    );
}

test "the hint: an importer with no tests, an import with no constant, an importer no test reaches" {
    try expectUnrun(&.{
        .{
            "build.zig",
            \\const std = @import("std");
            \\pub fn build(b: *std.Build) void { _ = b.path("root.zig"); }
            \\
        },
        .{
            "root.zig",
            \\const quiet = @import("quiet.zig");
            \\const inline_import = @import("inline_import.zig");
            \\const far = @import("far.zig");
            \\test { _ = quiet; _ = inline_import; _ = far; }
            \\
        },
        .{ "quiet.zig", "pub const s3 = @import(\"s3/quiet.zig\");\n" },
        .{ "s3/quiet.zig", s3_source },
        .{
            "inline_import.zig",
            \\pub fn f() u32 { return @import("s3/inline.zig").g(); }
            \\test "names nothing" {}
            \\
        },
        .{ "s3/inline.zig", s3_source },
        .{
            "far.zig",
            \\pub const near = @import("near.zig");
            \\test "names nothing" {}
            \\
        },
        .{
            "near.zig",
            \\pub const s3 = @import("s3/far.zig");
            \\test "near" { _ = s3; }
            \\
        },
        .{ "s3/far.zig", s3_source },
    },
        \\s3/quiet.zig:4:1 1 | add `test { _ = s3; }` to quiet.zig
        \\s3/inline.zig:4:1 1 | add `_ = @import("s3/inline.zig");` to a test block in inline_import.zig
        \\near.zig:2:1 1 | add `_ = near;` to a test block in far.zig
        \\s3/far.zig:4:1 1 | add `_ = s3;` to a test block in near.zig, and reach that file from a test too
        \\
    );
}
