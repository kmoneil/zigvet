var last: []const u8 = &.{};

const Holder = struct {
    items: []const u8,

    fn set(self: *Holder, n: u8) void {
        self.items = &.{n};
    }
};

fn writeOut(out: *[]const u8, n: u8) void {
    out.* = &.{ n, n };
}

fn remember(n: u8) void {
    last = &.{n};
}

comptime {
    _ = &Holder.set;
    _ = &writeOut;
    _ = &remember;
}

// error
//
// :7:22: error: anonymous array made here leaves set through field
// :12:13: error: anonymous array made here leaves writeOut through out param
// :16:12: error: anonymous array made here leaves remember through global
