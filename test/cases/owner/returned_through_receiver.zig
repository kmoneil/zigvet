// The allocation reaches the callee as a field of its receiver, and the
// callee frees that field in a defer before something that can fail:
// when the second allocation fails, `turned` frees the pixels, the error
// returns out of `decode`, and `decode`'s errdefer frees them again. The
// call is returned as it is rather than tried, which runs the errdefers
// all the same. It is an image decoder turning a photo upright by its
// EXIF orientation.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Image = struct {
    pixels: []u8,

    /// Turned; the old pixels are freed.
    fn turned(img: Image, gpa: Allocator) !Image {
        defer gpa.free(img.pixels);
        const out = try gpa.alloc(u8, img.pixels.len);
        @memcpy(out, img.pixels);
        return .{ .pixels = out };
    }
};

fn fill(pixels: []u8) !void {
    if (pixels.len == 0) return error.Empty;
    @memset(pixels, 0);
}

fn decode(gpa: Allocator, n: usize) !Image {
    const pixels = try gpa.alloc(u8, n);
    errdefer gpa.free(pixels);
    try fill(pixels);
    const img: Image = .{ .pixels = pixels };
    return img.turned(gpa);
}

// Not reported: the errdefer's scope ends before the image is handed to
// `turned`, which frees the pixels on its own failure.
fn decodeHanded(gpa: Allocator, n: usize) !Image {
    const pixels = made: {
        const owned = try gpa.alloc(u8, n);
        errdefer gpa.free(owned);
        try fill(owned);
        break :made owned;
    };
    const img: Image = .{ .pixels = pixels };
    return img.turned(gpa);
}

comptime {
    _ = &decode;
    _ = &decodeHanded;
}

// error
//
// :33:12: error: img.turned frees 'pixels' itself when it fails, and an errdefer here frees it again
