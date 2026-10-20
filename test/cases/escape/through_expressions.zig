const Scope = enum {
    monitoring,
    logging,
    fn url(self: Scope) []const u8 {
        return @tagName(self);
    }
};
const Scopes = []const []const u8;

fn viaSwitch(scope: Scope, asked: Scopes) Scopes {
    return switch (scope) {
        .monitoring => &.{scope.url()},
        .logging => asked,
    };
}
fn viaOrelse(maybe: ?Scopes, scope: Scope) Scopes {
    return maybe orelse &.{scope.url()};
}
fn viaCatch(result: anyerror!Scopes, scope: Scope) Scopes {
    return result catch &.{scope.url()};
}
fn viaLabeledBlock(scope: Scope) Scopes {
    return blk: {
        if (scope == .logging) break :blk &.{};
        break :blk &.{scope.url()};
    };
}
fn viaLocal(scope: Scope) Scopes {
    const scopes = &.{scope.url()};
    return scopes;
}
fn viaReassignedVar(scope: Scope, asked: Scopes) Scopes {
    var scopes = asked;
    if (scope == .logging) scopes = &.{scope.url()};
    return scopes;
}
fn viaCast(scope: Scope) Scopes {
    return @as(Scopes, &.{scope.url()});
}
const Request = struct { scopes: Scopes };
fn viaStructByValue(scope: Scope) Request {
    return .{ .scopes = &.{scope.url()} };
}

comptime {
    _ = &viaSwitch;
    _ = &viaOrelse;
    _ = &viaCatch;
    _ = &viaLabeledBlock;
    _ = &viaLocal;
    _ = &viaReassignedVar;
    _ = &viaCast;
    _ = &viaStructByValue;
}

// error
//
// :12:24: error: anonymous array made here leaves viaSwitch through return
// :17:25: error: anonymous array made here leaves viaOrelse through return
// :20:25: error: anonymous array made here leaves viaCatch through return
// :25:20: error: anonymous array made here leaves viaLabeledBlock through return
// :29:20: error: anonymous array made here leaves viaLocal through return
// :34:37: error: anonymous array made here leaves viaReassignedVar through return
// :38:24: error: anonymous array made here leaves viaCast through return
// :42:25: error: anonymous array made here leaves viaStructByValue through return
