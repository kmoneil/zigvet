//! The `zigvet` command: reports code the Zig compiler accepts in every
//! build mode that is almost certainly wrong.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const build_options = @import("build_options");
const test_options = @import("test_options");
const vet = @import("vet.zig");
const walk = @import("walk.zig");

const usage =
    \\Usage: zigvet <path>...
    \\       zigvet --version
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

    // Streaming: a positional writer writes a file stdout is redirected to
    // from byte 0, over what it held and under what is written after (#7).
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
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
        if (std.mem.eql(u8, arg, "--version")) {
            try out.print("zigvet {s}\n", .{build_options.version});
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

test "findings land where stdout's file is, not over its start" {
    // On Windows, `std.process.spawn` opens the file again for the child
    // rather than passing on the handle, so the child's position starts at
    // 0 whatever the writer does, and the shared file cannot be set up.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn f(x: u32) []const u32 {\n    return &.{x + 1};\n}\n" });

    // As `{ echo before; zigvet a.zig; echo after; } > out.txt` leaves it:
    // stdout is a regular file, already written to, that the shell writes
    // again after zigvet exits.
    const out = try tmp.dir.createFile(io, "out.txt", .{});
    defer out.close(io);
    try out.writeStreamingAll(io, "before\n");
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.zigvet_exe, gpa);
    defer gpa.free(exe);
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "a.zig" },
        .cwd = .{ .dir = tmp.dir },
        .stdout = .{ .file = out },
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, try child.wait(io));
    try out.writeStreamingAll(io, "after\n");

    const got = try tmp.dir.readFileAlloc(io, "out.txt", gpa, .limited(4096));
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        \\before
        \\a.zig:2:12: escape: anonymous array made here leaves f through return
        \\    hint: make it comptime-known (`comptime` on the runtime elements) or a container-level const
        \\after
        \\
    , got);
}

test {
    _ = @import("allow.zig");
    _ = @import("cases.zig");
    _ = @import("children.zig");
    _ = @import("escape.zig");
    _ = @import("report.zig");
    _ = @import("vet.zig");
    _ = @import("walk.zig");
}
