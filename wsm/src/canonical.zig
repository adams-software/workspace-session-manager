const std = @import("std");

pub const Error = error{
    Empty,
    StartsWithSlash,
    EndsWithSlash,
    EmptySegment,
    DotSegment,
    InvalidChar,
};

pub fn validateId(id: []const u8) Error!void {
    if (id.len == 0) return Error.Empty;
    if (id[0] == '/') return Error.StartsWithSlash;
    if (id[id.len - 1] == '/') return Error.EndsWithSlash;

    var iter = std.mem.splitScalar(u8, id, '/');
    while (iter.next()) |segment| {
        if (segment.len == 0) return Error.EmptySegment;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return Error.DotSegment;
        for (segment) |ch| {
            const ok = (ch >= 'a' and ch <= 'z') or
                (ch >= '0' and ch <= '9') or
                ch == '.' or ch == '_' or ch == '-';
            if (!ok) return Error.InvalidChar;
        }
    }
}

pub fn socketPath(allocator: std.mem.Allocator, root: []const u8, id: []const u8) ![]u8 {
    try validateId(id);
    const leaf = try std.fmt.allocPrint(allocator, "{s}.msr", .{id});
    defer allocator.free(leaf);
    return try std.fs.path.join(allocator, &.{ root, leaf });
}

test "validateId accepts simple canonical ids" {
    try validateId("api");
    try validateId("api/dev");
    try validateId("api/dev/server-1");
}

test "validateId rejects bad ids" {
    try std.testing.expectError(Error.Empty, validateId(""));
    try std.testing.expectError(Error.StartsWithSlash, validateId("/api"));
    try std.testing.expectError(Error.EndsWithSlash, validateId("api/"));
    try std.testing.expectError(Error.EmptySegment, validateId("api//dev"));
    try std.testing.expectError(Error.DotSegment, validateId("api/./dev"));
    try std.testing.expectError(Error.DotSegment, validateId("api/../dev"));
    try std.testing.expectError(Error.InvalidChar, validateId("API/dev"));
    try std.testing.expectError(Error.InvalidChar, validateId("api/dev!"));
}
