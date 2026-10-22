pub fn onlyAtComptime(n: u8) []const u8 {
    // zigvet: allow escape called only from comptime blocks in other files,
    // where the array is comptime memory
    return &.{ n, n };
}

comptime {
    _ = &onlyAtComptime;
}

// compile
