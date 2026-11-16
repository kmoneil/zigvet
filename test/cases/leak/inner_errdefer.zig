// An `errdefer` in an inner block runs when an error leaves that block, so
// it releases `fd` when the `try` beside it fails, and the `close` after the
// block is the success path's only (#183). A failure after the block is not
// covered by it.
const std = @import("std");

fn open() !i32 {
    return 3;
}

fn close(fd: i32) void {
    _ = fd;
}

fn write(fd: i32, fail: bool) !void {
    _ = fd;
    if (fail) return error.Io;
}

// Not reported: the errdefer covers the write.
fn save(fail: bool) !void {
    const fd = try open();
    {
        errdefer close(fd);
        try write(fd, fail);
    }
    close(fd);
}

fn saveThenSync(fail: bool) !void {
    const fd = try open();
    {
        errdefer close(fd);
        try write(fd, fail);
    }
    try write(fd, !fail);
    close(fd);
}

comptime {
    _ = &save;
    _ = &saveThenSync;
}

// error
//
// :36:5: error: if write fails here, the function returns before `close(fd)` below, and 'fd' is never released
