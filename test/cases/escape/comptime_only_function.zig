fn sizes(comptime types: []const type) []const usize {
    var array: [types.len]usize = undefined;
    for (types, 0..) |T, i| array[i] = @sizeOf(T);
    const finalized = array;
    return &finalized;
}

fn sizesSaidComptime(comptime types: []const type) []const usize {
    return comptime blk: {
        var array: [types.len]usize = undefined;
        for (types, 0..) |T, i| array[i] = @sizeOf(T);
        const finalized = array;
        break :blk &finalized;
    };
}

comptime {
    _ = sizes(&.{ u8, u16 });
    _ = sizesSaidComptime(&.{ u8, u16 });
}

// error
//
// :5:12: error: address of local 'finalized' made here leaves sizes through return
