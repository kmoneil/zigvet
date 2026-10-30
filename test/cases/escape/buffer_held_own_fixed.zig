// `.fixed(&buf)` in a file that declares a `fixed` of its own may be that
// one, which here copies what it is given, so it is not taken for std's
// reader or writer (#125).
const Line = struct {
    bytes: [8]u8 = @splat(0),

    fn fixed(text: []const u8) Line {
        var line: Line = .{};
        @memcpy(line.bytes[0..text.len], text);
        return line;
    }
};

fn copied(n: u8) Line {
    var text: [2]u8 = @splat(n);
    text[1] = 0;
    return .fixed(&text);
}

comptime {
    _ = &copied;
}

// compile
