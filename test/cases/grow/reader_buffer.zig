// A slice of a reader's buffer kept across a call that can read more
// (#188): when what is left unread does not fit, the reader moves it to
// the start of its buffer and reads new bytes in after, so `head` shows
// other bytes. It passes a test whose second read needs no room.
const std = @import("std");

fn first(in: *std.Io.Reader) !u8 {
    const head = in.buffered();
    try in.fill(4);
    return head[0];
}

// Zig 0.17.1's resinator: `chunk_id` is read over by the refill
// `takeInt` makes when the id was the last 4 bytes buffered.
fn isAnih(reader: *std.Io.Reader) !bool {
    const chunk_id = try reader.takeArray(4);
    const chunk_len = try reader.takeInt(u32, .little);
    _ = chunk_len;
    return std.mem.eql(u8, chunk_id, "anih");
}

// Not reported: a reader made with `fixed` reads the bytes it was given
// in place and never moves them, `toss` reads nothing, and a slice taken
// again after the fill.
fn pair(bytes: []const u8) !bool {
    var in: std.Io.Reader = .fixed(bytes);
    const a = try in.take(2);
    const b = try in.take(2);
    return std.mem.eql(u8, a, b);
}
fn tossed(in: *std.Io.Reader) !u8 {
    const head = try in.peek(2);
    in.toss(2);
    return head[1];
}
fn again(in: *std.Io.Reader) !u8 {
    try in.fill(4);
    const head = in.buffered();
    return head[0];
}

comptime {
    _ = &first;
    _ = &isAnih;
    _ = &pair;
    _ = &tossed;
    _ = &again;
}

// error
//
// :9:9: error: `in.fill` can move the bytes in `in`'s buffer and read others into their place, and 'head', taken before it, still points there where it is used after
// :17:27: error: `reader.takeInt` can move the bytes in `reader`'s buffer and read others into their place, and 'chunk_id', taken before it, still points there where it is used after
