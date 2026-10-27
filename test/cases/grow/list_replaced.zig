// A list stored again between taking its items and growing it (#95): the
// append grows what was stored, and `found` still points at memory nothing
// has moved. A template compiler swaps a list field out, scans into a
// fresh one, takes its items and swaps the original back.
const std = @import("std");

const Scanner = struct {
    list: std.ArrayList(u32) = .empty,

    fn scan(s: *Scanner, gpa: std.mem.Allocator) ![]const u32 {
        const saved = s.list;
        s.list = .empty;
        try s.list.append(gpa, 1);
        const found = s.list.items;
        s.list = saved;
        try s.list.append(gpa, 2);
        return found;
    }
};

// The list's place reset whole: the append allocates new memory, and
// `first` keeps the old.
fn restart(gpa: std.mem.Allocator, list: *std.ArrayList(u32)) !u32 {
    const first = &list.items[0];
    list.* = .empty;
    try list.append(gpa, 1);
    return first.*;
}

comptime {
    _ = &Scanner.scan;
    _ = &restart;
}

// compile
