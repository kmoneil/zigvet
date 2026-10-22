// A capture held by value in a loop is a copy made for one turn, so a slice
// of its array field, directly or through the file's own method, is gone by
// the next turn: stored through a parameter, or to a local declared outside
// the loop (#34). Fields held by value are followed as deep as the file's
// types go, for a parameter as for a capture.
const Name = struct {
    bytes: [16]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Topic = struct { name: Name, partitions: u32 };

fn direct(topics: []const Topic, into: [][]const u8) void {
    for (topics, into) |topic, *out| out.* = topic.name.bytes[0..topic.name.len];
}
fn method(topics: []const Topic, into: [][]const u8) void {
    for (topics, into) |topic, *out| out.* = topic.name.slice();
}
fn local(topics: []const Topic) usize {
    var last: []const u8 = "";
    for (topics) |topic| last = topic.name.slice();
    return last.len;
}
fn nested(topic: Topic) []const u8 {
    return topic.name.slice();
}

// Not reported: captured by pointer, the slice is the caller's; a local
// declared inside the loop goes with the turn; a call reads it within it.
fn borrowed(topics: []const Topic, into: [][]const u8) void {
    for (topics, into) |*topic, *out| out.* = topic.name.slice();
}
fn inside(topics: []const Topic) usize {
    var total: usize = 0;
    for (topics) |topic| {
        const name = topic.name.slice();
        total += name.len;
    }
    return total;
}
fn counted(topics: []const Topic) usize {
    var total: usize = 0;
    for (topics) |topic| total += count(topic.name.slice());
    return total;
}
fn count(s: []const u8) usize {
    return s.len;
}

comptime {
    _ = &direct;
    _ = &method;
    _ = &local;
    _ = &nested;
    _ = &borrowed;
    _ = &inside;
    _ = &counted;
}

// error
//
// :18:46: error: slice of a field of capture 'topic' made here leaves direct through out param
// :21:46: error: address of a field of capture 'topic' made here leaves method through out param
// :25:33: error: address of a field of capture 'topic' made here leaves its turn of the loop through local 'last'
// :29:12: error: address of a field of parameter 'topic' made here leaves nested through return
