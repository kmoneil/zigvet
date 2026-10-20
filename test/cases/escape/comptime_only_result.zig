const std = @import("std");

// A return type only comptime has: these run only at compile time, so
// nothing they return is on a run-time stack (#9).
fn reversed(comptime types: []const type) []const type {
    var array: [types.len]type = types[0..types.len].*;
    std.mem.reverse(type, &array);
    const final = array;
    return &final;
}

fn widths(comptime types: []const type) []const comptime_int {
    var array: [types.len]comptime_int = undefined;
    for (types, 0..) |T, i| array[i] = @bitSizeOf(T);
    const final = array;
    return &final;
}

fn firstOf(comptime types: []const type) ?*const type {
    var array: [types.len]type = types[0..types.len].*;
    return &array[0];
}

comptime {
    _ = reversed(&.{ u8, u16, u32 });
    _ = widths(&.{ u8, u16 });
    _ = firstOf(&.{u8});
}

// compile
