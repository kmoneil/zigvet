// A lock taken, then something that can fail before the unlock, with no
// defer to unlock it (#57): the error leaves the function holding the lock,
// and the next lock waits for good. `acquire` is an HTTP server library's
// connection pool.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Conn = struct { fd: i32 = 0 };

const Pool = struct {
    io: Io,
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    free: std.ArrayList(*Conn) = .empty,

    fn acquire(self: *Pool) !*Conn {
        try self.mutex.lock(self.io);
        const conn = try self.gpa.create(Conn);
        self.mutex.unlock(self.io);
        return conn;
    }

    // Not reported: unlocked by a defer, whatever fails.
    fn acquireSafely(self: *Pool) !*Conn {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.gpa.create(Conn);
    }
};

comptime {
    _ = &Pool.acquire;
    _ = &Pool.acquireSafely;
}

// error
//
// :18:9: error: self.mutex is locked here and left locked if self.gpa.create fails before it is unlocked
