const Key = struct {
    bytes: [4]u8,

    fn toBytes(key: Key) [4]u8 {
        return key.bytes;
    }

    fn view(key: Key) []const u8 {
        return &key.bytes;
    }
};

fn rawOf(key: *const Key) []const u8 {
    return &key.toBytes();
}
fn parameter(n: u8) []const u8 {
    return (&n)[0..1];
}
fn capture(maybe: ?u8) []const u8 {
    if (maybe) |n| return (&n)[0..1];
    return &.{};
}
fn element(n: u8) *const u8 {
    const pair = [_]u8{ n, n };
    return &pair[0];
}

comptime {
    _ = &Key.view;
    _ = &rawOf;
    _ = &parameter;
    _ = &capture;
    _ = &element;
}

// error
//
// :9:16: error: address of a field of parameter 'key' made here leaves view through return
// :14:12: error: result of a call made here leaves rawOf through return
// :17:13: error: address of parameter 'n' made here leaves parameter through return
// :20:28: error: address of capture 'n' made here leaves capture through return
// :25:12: error: address of an element of local 'pair' made here leaves element through return
