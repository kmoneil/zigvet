// A function only ever run at compile time returns comptime memory, which
// is legal. When the file shows it, every use of the function a call made
// at compile time, it is not checked: `sizes`, called in a `comptime`
// block, and `widths`, in a container-level declaration. A `pub` function
// the file never calls may be called at run time from another file, so it
// is reported, the one accepted false positive: say so with `comptime`, as
// `sizesSaidComptime` does, or with an allow comment.
pub fn sizesForOthers(comptime types: []const type) []const usize {
    var array: [types.len]usize = undefined;
    for (types, 0..) |T, i| array[i] = @sizeOf(T);
    const finalized = array;
    return &finalized;
}

fn sizes(comptime types: []const type) []const usize {
    var array: [types.len]usize = undefined;
    for (types, 0..) |T, i| array[i] = @sizeOf(T);
    const finalized = array;
    return &finalized;
}

const table = widths();
fn widths() []const u8 {
    var array: [2]u8 = .{ 1, 2 };
    array[0] = 3;
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
    _ = table;
    _ = sizesSaidComptime(&.{ u8, u16 });
}

// error
//
// :12:12: error: address of local 'finalized' made here leaves sizesForOthers through return
