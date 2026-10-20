//! The `zigvet` command: reports code the Zig compiler accepts in every
//! build mode that is almost certainly wrong.

const std = @import("std");
const Io = std.Io;

const vet = @import("vet.zig");
const walk = @import("walk.zig");

const usage =
    \\Usage: zigvet <path>...
    \\
    \\Checks each file named, and every .zig file under each directory named,
    \\for code the Zig compiler accepts that is almost certainly wrong.
    \\Directories that are hidden, zig-out or zig-pkg are skipped.
    \\
    \\Exit status: 0 if nothing was reported, 1 if a finding or parse error
    \\was, 2 on a usage error or a path that could not be read.
    \\
;

/// `Ast` offsets are 32-bit.
const max_source_bytes = std.math.maxInt(u32);

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = (try init.minimal.args.toSlice(arena))[1..];
    if (args.len == 0) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            try out.flush();
            return 0;
        }
        if (arg.len > 1 and arg[0] == '-') {
            std.debug.print("zigvet: unknown option '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        }
    }

    const cwd = Io.Dir.cwd();
    var unreadable = false;
    var files: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        walk.collect(arena, io, cwd, arg, &files) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                std.debug.print("zigvet: {s}: {t}\n", .{ arg, err });
                unreadable = true;
            },
        };
    }
    walk.sortUnique(&files);

    var reported: usize = 0;
    for (files.items) |path| {
        const source = cwd.readFileAllocOptions(io, path, gpa, .limited(max_source_bytes), .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                std.debug.print("zigvet: {s}: {t}\n", .{ path, err });
                unreadable = true;
                continue;
            },
        };
        defer gpa.free(source);
        reported += try vet.vetSource(gpa, path, source, out);
    }
    try out.flush();

    if (unreadable) return 2;
    return @intFromBool(reported > 0);
}

test {
    _ = @import("allow.zig");
    _ = @import("children.zig");
    _ = @import("escape.zig");
    _ = @import("report.zig");
    _ = @import("vet.zig");
    _ = @import("walk.zig");
}
