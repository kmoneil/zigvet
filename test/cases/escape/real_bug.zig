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

/// What `scope`'s client is given tokens for when it asks `asked`.
fn scopesFor(scope: Scope, asked: []const []const u8) []const []const u8 {
    return if (scope == .monitoring) &.{Scope.monitoring.url()} else asked;
}

comptime {
    _ = &scopesFor;
}

// error
//
// :14:38: error: anonymous array made here leaves scopesFor through return
