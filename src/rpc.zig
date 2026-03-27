const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
});

pub const MsgType = enum {
    control_req,
    control_res,
    data,
};

pub const ControlReq = struct {
    op: []const u8,
    path: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    signal: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};

pub const ControlRes = struct {
    ok: bool,
    value: ?std.json.Value = null,
    err: ?ErrBody = null,

    pub const ErrBody = struct {
        code: []const u8,
        message: ?[]const u8 = null,
    };
};

pub fn writeFrame(fd: c_int, bytes: []const u8) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(bytes.len), .little);
    try writeAll(fd, &hdr);
    try writeAll(fd, bytes);
}

pub fn readFrame(allocator: std.mem.Allocator, fd: c_int, max_len: usize) ![]u8 {
    var hdr: [4]u8 = undefined;
    try readExact(fd, &hdr);
    const n = std.mem.readInt(u32, &hdr, .little);
    if (n > max_len) return error.FrameTooLarge;

    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    try readExact(fd, buf);
    return buf;
}

pub fn encodeControlReq(allocator: std.mem.Allocator, req: ControlReq) ![]u8 {
    const env = .{ .type = "control_req", .payload = req };
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(env, .{})});
}

pub fn encodeControlRes(allocator: std.mem.Allocator, res: ControlRes) ![]u8 {
    const env = .{ .type = "control_res", .payload = res };
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(env, .{})});
}

pub fn parseControlReq(allocator: std.mem.Allocator, bytes: []const u8) !ControlReq {
    const Env = struct {
        type: []const u8,
        payload: ControlReq,
    };
    var parsed = try std.json.parseFromSlice(Env, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "control_req")) return error.BadMessageType;
    return parsed.value.payload;
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn readExact(fd: c_int, dst: []u8) !void {
    var off: usize = 0;
    while (off < dst.len) {
        const n = c.read(fd, dst.ptr + off, dst.len - off);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.UnexpectedEof;
        off += @intCast(n);
    }
}

test "rpc frame roundtrip" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    try writeFrame(fds[1], "hello");
    const got = try readFrame(std.testing.allocator, fds[0], 1024);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello", got);
}

test "encode/decode control request" {
    const req = ControlReq{ .op = "exists", .path = "/tmp/s1.sock" };
    const payload = try encodeControlReq(std.testing.allocator, req);
    defer std.testing.allocator.free(payload);

    const out = try parseControlReq(std.testing.allocator, payload);
    try std.testing.expectEqualStrings("exists", out.op);
    try std.testing.expect(out.path != null);
    try std.testing.expectEqualStrings("/tmp/s1.sock", out.path.?);
}
