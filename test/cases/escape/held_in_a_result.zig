const std = @import("std");

// A call to the file's own function whose result holds a copy of an
// argument carries what points into the argument out with it (#96). A
// handler hands `&errs` to `render`, which copies its params into the
// arena for a writer that runs after the handler returns, and the page
// reads freed stack memory.
const Errors = struct { n: u32 = 0 };
const Params = struct { errors: ?*const Errors = null };
const Response = struct { state: *const Params };

const Ctx = struct {
    arena: std.mem.Allocator,

    fn render(ctx: *Ctx, params: Params) !Response {
        const p = try ctx.arena.create(Params);
        p.* = params;
        return .{ .state = p };
    }
};

fn handler(ctx: *Ctx) !Response {
    var errs: Errors = .{ .n = 1 };
    errs.n += 1;
    return ctx.render(.{ .errors = &errs });
}

// A builder that keeps its config.
const Config = struct { name: []const u8 };
const Builder = struct { config: Config };

fn builder(config: Config) Builder {
    return .{ .config = config };
}

fn named(id: u8) Builder {
    var name: [4]u8 = .{ 'n', id, id, id };
    name[0] = 'm';
    return builder(.{ .name = &name });
}

// Not reported: the argument is the caller's memory, or only a field read
// out of the result leaves.
fn ofParameter(name: []const u8) Builder {
    return builder(.{ .name = name });
}
fn length(id: u8) usize {
    var name: [4]u8 = .{ 'n', id, id, id };
    name[0] = 'm';
    return builder(.{ .name = &name }).config.name.len;
}

comptime {
    _ = &handler;
    _ = &named;
    _ = &ofParameter;
    _ = &length;
}

// error
//
// :25:36: error: address of local 'errs' made here leaves handler through return
// :39:31: error: address of local 'name' made here leaves named through return
