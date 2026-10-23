// An errdefer frees what an optional holds, through `.?`, and leaves the
// optional set: whatever reads it next takes the job as running, and
// `deinit`, which checks it, deinits it again. `start` is a terminal
// emulator's search, whose thread can fail to spawn after its state is
// made.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Job = struct {
    buf: []u8,

    fn init(gpa: Allocator) !Job {
        return .{ .buf = try gpa.alloc(u8, 64) };
    }
    fn deinit(job: *Job, gpa: Allocator) void {
        gpa.free(job.buf);
    }
    fn run(job: *Job) !void {
        if (job.buf.len == 0) return error.Empty;
    }
};

const Runner = struct {
    gpa: Allocator,
    job: ?Job = null,
    jobs: std.ArrayList(u32) = .empty,

    fn deinit(self: *Runner) void {
        if (self.job) |*job| job.deinit(self.gpa);
        self.jobs.deinit(self.gpa);
    }

    fn start(self: *Runner) !void {
        self.job = try .init(self.gpa);
        const job = &self.job.?;
        errdefer job.deinit(self.gpa);
        try job.run();
    }

    // Not reported: the optional set back in the same errdefer, and a
    // local emptied once what it held is handed over (#86).
    fn startReset(self: *Runner) !void {
        self.job = try .init(self.gpa);
        const job = &self.job.?;
        errdefer {
            job.deinit(self.gpa);
            self.job = null;
        }
        try job.run();
    }

    fn replace(self: *Runner, n: usize) !void {
        var jobs = try std.ArrayList(u32).initCapacity(self.gpa, n);
        errdefer jobs.deinit(self.gpa);
        self.jobs.deinit(self.gpa);
        self.jobs = jobs;
        jobs = .empty;
        if (n == 0) return error.Empty;
    }
};

comptime {
    _ = &Runner.deinit;
    _ = &Runner.start;
    _ = &Runner.startReset;
    _ = &Runner.replace;
}

// error
//
// :36:9: error: `job` freed here if job.run fails, but self.job already holds it
