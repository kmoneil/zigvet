// A std.json value parsed out of what the function's own defer frees
// (#124). parseFromSlice's default, `.allocate = .alloc_if_needed`, leaves
// a string with no escape in it as a slice of the input, so `load` hands
// back a name that points into freed memory: a test of it reads `UUUUUU`
// where the input said `thresh`. A string with an escape is copied, so the
// same code works on some inputs and not others.
const std = @import("std");

const Config = struct { name: []const u8 };

fn load(gpa: std.mem.Allocator, text: []const u8) !std.json.Parsed(Config) {
    const json = try gpa.dupe(u8, text);
    defer gpa.free(json);
    return std.json.parseFromSlice(Config, gpa, json, .{});
}

fn loadInto(arena: std.mem.Allocator, gpa: std.mem.Allocator, text: []const u8) !Config {
    const json = try gpa.dupe(u8, text);
    defer gpa.free(json);
    const config = try std.json.parseFromSliceLeaky(Config, arena, json, .{ .ignore_unknown_fields = true });
    return config;
}

// Not reported: every string copied into the value's own memory, with the
// options written in the call or in a const, and a value read before the
// defer frees what it points into.
fn loadCopied(gpa: std.mem.Allocator, text: []const u8) !std.json.Parsed(Config) {
    const json = try gpa.dupe(u8, text);
    defer gpa.free(json);
    return std.json.parseFromSlice(Config, gpa, json, .{ .allocate = .alloc_always });
}
fn loadNamed(gpa: std.mem.Allocator, text: []const u8) !std.json.Parsed(Config) {
    const options: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = true };
    const json = try gpa.dupe(u8, text);
    defer gpa.free(json);
    return std.json.parseFromSlice(Config, gpa, json, options);
}
fn nameLength(gpa: std.mem.Allocator, text: []const u8) !usize {
    const json = try gpa.dupe(u8, text);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(Config, gpa, json, .{});
    defer parsed.deinit();
    return parsed.value.name.len;
}

comptime {
    _ = &load;
    _ = &loadInto;
    _ = &loadCopied;
    _ = &loadNamed;
    _ = &nameLength;
}

// error
//
// :14:12: error: returns `std.json.parseFromSlice(...)`, whose strings can point into `json`, which `defer gpa.free(json)` above frees before the caller reads them
// :20:24: error: returns `std.json.parseFromSliceLeaky(...)` as `config`, whose strings can point into `json`, which `defer gpa.free(json)` above frees before the caller reads them
