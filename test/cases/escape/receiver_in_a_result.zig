// A method whose result holds its receiver carries the receiver out with
// it (#100): `reader` takes `self` by pointer, so `buffer.reader()` hands it
// `&buffer`, and the `Reader` it returns points into `open`'s frame.
const Buffer = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,

    const Reader = struct {
        buffer: *const Buffer,
        at: usize = 0,
    };

    fn reader(self: *const Buffer) Reader {
        return .{ .buffer = self };
    }
};

fn open() Buffer.Reader {
    var buffer: Buffer = .{};
    buffer.len = 3;
    return buffer.reader();
}

// Taken by value, the receiver is a copy, and what it points at leaves.
const Config = struct {
    name: []const u8,

    fn held(self: Config) Holder {
        return .{ .config = self };
    }
};
const Holder = struct { config: Config };

fn named(id: u8) Holder {
    var name: [4]u8 = .{ 'n', id, id, id };
    name[0] = 'm';
    const config: Config = .{ .name = &name };
    return config.held();
}

// Not reported: the receiver is the caller's memory, or only a field read
// out of the result leaves.
fn borrowed(buffer: *const Buffer) Buffer.Reader {
    return buffer.reader();
}
fn position() usize {
    var buffer: Buffer = .{};
    buffer.len = 3;
    return buffer.reader().at;
}

comptime {
    _ = &open;
    _ = &named;
    _ = &borrowed;
    _ = &position;
}

// error
//
// :21:12: error: address of local 'buffer' made here leaves open through return
// :37:39: error: address of local 'name' made here leaves named through return
