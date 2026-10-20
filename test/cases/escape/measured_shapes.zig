const Scope = enum {
    monitoring,
    logging,
    fn url(self: Scope) []const u8 {
        return switch (self) {
            .monitoring => "https://www.googleapis.com/auth/monitoring.read",
            .logging => "https://www.googleapis.com/auth/logging.read",
        };
    }
};

fn dangling(scope: Scope) []const []const u8 {
    return &.{scope.url()};
}
fn danglingToo() []const []const u8 {
    return &.{Scope.monitoring.url()};
}
fn sliceOfVar(n: u8) []const u8 {
    var buf: [4]u8 = .{ 1, 2, 3, n };
    return buf[0..2];
}
fn sliceOfAddress(n: u8) []const u8 {
    var x: u8 = n;
    return (&x)[0..1];
}
fn constArray(n: u8) []const u8 {
    const arr = [_]u8{ n, n };
    return &arr;
}
fn typedLiteral(n: u8) []const u8 {
    return &[_]u8{ n, n };
}
fn anonymousLiteral(n: u8) []const u8 {
    return &.{ n, n };
}

comptime {
    _ = &dangling;
    _ = &danglingToo;
    _ = &sliceOfVar;
    _ = &sliceOfAddress;
    _ = &constArray;
    _ = &typedLiteral;
    _ = &anonymousLiteral;
}

// error
//
// :13:12: error: anonymous array made here leaves dangling through return
// :16:12: error: anonymous array made here leaves danglingToo through return
// :20:12: error: slice of local 'buf' made here leaves sliceOfVar through return
// :24:13: error: address of local 'x' made here leaves sliceOfAddress through return
// :28:12: error: address of local 'arr' made here leaves constArray through return
// :31:12: error: array literal made here leaves typedLiteral through return
// :34:12: error: anonymous array made here leaves anonymousLiteral through return
