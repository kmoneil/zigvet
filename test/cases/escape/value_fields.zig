// A parameter or local held by value is the function's own copy, so a
// slice of one of its array fields dies with the call, sliced directly or
// through the file's own method that returns part of `self` (#28).
const Id = struct {
    bytes: [8]u8 = undefined,
    len: u8 = 0,
    label: []const u8 = "",

    const Self = @This();

    fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }
    fn whole(self: *const Self) []const u8 {
        return &self.bytes;
    }
    fn name(self: *const Id) []const u8 {
        return self.label;
    }
};

fn viaMethod(id: Id) []const u8 {
    return id.slice();
}
fn direct(id: Id) []const u8 {
    return id.bytes[0..id.len];
}
fn local(n: u8) []const u8 {
    var id: Id = .{ .len = n };
    id.bytes[0] = n;
    return id.whole();
}

// Not reported: the caller's memory, or a field that is itself a slice.
fn borrowed(id: *const Id) []const u8 {
    return id.slice();
}
fn sliceField(id: Id) []const u8 {
    return id.label[0..];
}
fn named(id: Id) []const u8 {
    return id.name();
}

comptime {
    _ = &viaMethod;
    _ = &direct;
    _ = &local;
    _ = &borrowed;
    _ = &sliceField;
    _ = &named;
}

// error
//
// :23:12: error: address of parameter 'id' made here leaves viaMethod through return
// :26:12: error: slice of a field of parameter 'id' made here leaves direct through return
// :31:12: error: address of local 'id' made here leaves local through return
