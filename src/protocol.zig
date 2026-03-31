const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
});

pub const ControlReq = struct {
    op: []const u8,
    path: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    signal: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};

pub const ControlValue = struct {
    exists: ?bool = null,
    status: ?[]const u8 = null,
    code: ?i32 = null,
    signal: ?[]const u8 = null,
};

pub const ControlRes = struct {
    ok: bool,
    value: ?ControlValue = null,
    err: ?ErrBody = null,

    pub const ErrBody = struct {
        code: []const u8,
        message: ?[]const u8 = null,
    };
};

pub const DataMsg = struct {
    stream: []const u8,
    bytes_b64: []const u8,
};

pub const EventMsg = struct {
    kind: []const u8,
    code: ?i32 = null,
    signal: ?[]const u8 = null,
};

pub const LaneReqMsg = struct {
    lane_id: []const u8,
    lane_kind: []const u8,
    req_type: []const u8,
    seq: u32,
    method: ?[]const u8 = null,
    args_json: ?[]const u8 = null,
};

pub const LaneResMsg = struct {
    lane_id: []const u8,
    res_type: []const u8,
    seq: u32,
    value_json: ?[]const u8 = null,
    error_json: ?[]const u8 = null,
    meta_json: ?[]const u8 = null,
    chunk_json: ?[]const u8 = null,
};

pub fn freeControlReq(allocator: std.mem.Allocator, req: *ControlReq) void {
    allocator.free(@constCast(req.op));
    if (req.path) |v| allocator.free(@constCast(v));
    if (req.signal) |v| allocator.free(@constCast(v));
    if (req.mode) |v| allocator.free(@constCast(v));
}

pub fn freeControlRes(allocator: std.mem.Allocator, res: *ControlRes) void {
    if (res.value) |*v| {
        if (v.status) |s| allocator.free(@constCast(s));
        if (v.signal) |s| allocator.free(@constCast(s));
    }
    if (res.err) |*e| {
        allocator.free(@constCast(e.code));
        if (e.message) |m| allocator.free(@constCast(m));
    }
}

pub fn freeDataMsg(allocator: std.mem.Allocator, msg: *DataMsg) void {
    allocator.free(@constCast(msg.stream));
    allocator.free(@constCast(msg.bytes_b64));
}

pub fn freeEventMsg(allocator: std.mem.Allocator, msg: *EventMsg) void {
    allocator.free(@constCast(msg.kind));
    if (msg.signal) |s| allocator.free(@constCast(s));
}

pub fn freeLaneReqMsg(allocator: std.mem.Allocator, msg: *LaneReqMsg) void {
    allocator.free(@constCast(msg.lane_id));
    allocator.free(@constCast(msg.lane_kind));
    allocator.free(@constCast(msg.req_type));
    if (msg.method) |v| allocator.free(@constCast(v));
    if (msg.args_json) |v| allocator.free(@constCast(v));
}

pub fn freeLaneResMsg(allocator: std.mem.Allocator, msg: *LaneResMsg) void {
    allocator.free(@constCast(msg.lane_id));
    allocator.free(@constCast(msg.res_type));
    if (msg.value_json) |v| allocator.free(@constCast(v));
    if (msg.error_json) |v| allocator.free(@constCast(v));
    if (msg.meta_json) |v| allocator.free(@constCast(v));
    if (msg.chunk_json) |v| allocator.free(@constCast(v));
}

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

    const p = parsed.value.payload;
    return .{
        .op = try allocator.dupe(u8, p.op),
        .path = if (p.path) |v| try allocator.dupe(u8, v) else null,
        .cols = p.cols,
        .rows = p.rows,
        .signal = if (p.signal) |v| try allocator.dupe(u8, v) else null,
        .mode = if (p.mode) |v| try allocator.dupe(u8, v) else null,
    };
}

pub fn parseControlRes(allocator: std.mem.Allocator, bytes: []const u8) !ControlRes {
    const Env = struct {
        type: []const u8,
        payload: ControlRes,
    };
    var parsed = try std.json.parseFromSlice(Env, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "control_res")) return error.BadMessageType;

    const p = parsed.value.payload;
    var out: ControlRes = .{ .ok = p.ok, .value = null, .err = null };
    if (p.value) |v| {
        out.value = .{
            .exists = v.exists,
            .status = if (v.status) |s| try allocator.dupe(u8, s) else null,
            .code = v.code,
            .signal = if (v.signal) |s| try allocator.dupe(u8, s) else null,
        };
    }
    if (p.err) |e| {
        out.err = .{
            .code = try allocator.dupe(u8, e.code),
            .message = if (e.message) |m| try allocator.dupe(u8, m) else null,
        };
    }
    return out;
}

pub fn encodeDataMsg(allocator: std.mem.Allocator, msg: DataMsg) ![]u8 {
    const env = .{ .type = "data", .payload = msg };
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(env, .{})});
}

pub fn parseDataMsg(allocator: std.mem.Allocator, bytes: []const u8) !DataMsg {
    const Env = struct {
        type: []const u8,
        payload: DataMsg,
    };
    var parsed = try std.json.parseFromSlice(Env, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "data")) return error.BadMessageType;
    const p = parsed.value.payload;
    return .{
        .stream = try allocator.dupe(u8, p.stream),
        .bytes_b64 = try allocator.dupe(u8, p.bytes_b64),
    };
}

pub fn encodeEventMsg(allocator: std.mem.Allocator, msg: EventMsg) ![]u8 {
    const env = .{ .type = "event", .payload = msg };
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(env, .{})});
}

pub fn encodeLaneReqMsg(allocator: std.mem.Allocator, msg: LaneReqMsg) ![]u8 {
    const env = .{ .type = "lane_req", .payload = msg };
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(env, .{})});
}

pub fn encodeLaneResMsg(allocator: std.mem.Allocator, msg: LaneResMsg) ![]u8 {
    const env = .{ .type = "lane_res", .payload = msg };
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(env, .{})});
}

pub fn parseEventMsg(allocator: std.mem.Allocator, bytes: []const u8) !EventMsg {
    const Env = struct {
        type: []const u8,
        payload: EventMsg,
    };
    var parsed = try std.json.parseFromSlice(Env, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "event")) return error.BadMessageType;
    const p = parsed.value.payload;
    return .{
        .kind = try allocator.dupe(u8, p.kind),
        .code = p.code,
        .signal = if (p.signal) |s| try allocator.dupe(u8, s) else null,
    };
}

pub fn parseLaneReqMsg(allocator: std.mem.Allocator, bytes: []const u8) !LaneReqMsg {
    const Env = struct {
        type: []const u8,
        payload: LaneReqMsg,
    };
    var parsed = try std.json.parseFromSlice(Env, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "lane_req")) return error.BadMessageType;
    const p = parsed.value.payload;
    return .{
        .lane_id = try allocator.dupe(u8, p.lane_id),
        .lane_kind = try allocator.dupe(u8, p.lane_kind),
        .req_type = try allocator.dupe(u8, p.req_type),
        .seq = p.seq,
        .method = if (p.method) |v| try allocator.dupe(u8, v) else null,
        .args_json = if (p.args_json) |v| try allocator.dupe(u8, v) else null,
    };
}

pub fn parseLaneResMsg(allocator: std.mem.Allocator, bytes: []const u8) !LaneResMsg {
    const Env = struct {
        type: []const u8,
        payload: LaneResMsg,
    };
    var parsed = try std.json.parseFromSlice(Env, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "lane_res")) return error.BadMessageType;
    const p = parsed.value.payload;
    return .{
        .lane_id = try allocator.dupe(u8, p.lane_id),
        .res_type = try allocator.dupe(u8, p.res_type),
        .seq = p.seq,
        .value_json = if (p.value_json) |v| try allocator.dupe(u8, v) else null,
        .error_json = if (p.error_json) |v| try allocator.dupe(u8, v) else null,
        .meta_json = if (p.meta_json) |v| try allocator.dupe(u8, v) else null,
        .chunk_json = if (p.chunk_json) |v| try allocator.dupe(u8, v) else null,
    };
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

test "protocol frame roundtrip" {
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

test "protocol encode/decode control request" {
    const req = ControlReq{ .op = "status", .path = "/tmp/s1.sock" };
    const payload = try encodeControlReq(std.testing.allocator, req);
    defer std.testing.allocator.free(payload);

    var out = try parseControlReq(std.testing.allocator, payload);
    defer freeControlReq(std.testing.allocator, &out);
    try std.testing.expectEqualStrings("status", out.op);
    try std.testing.expect(out.path != null);
    try std.testing.expectEqualStrings("/tmp/s1.sock", out.path.?);
}

test "protocol encode/decode control response with value" {
    const res = ControlRes{ .ok = true, .value = .{ .exists = true, .status = "running" } };
    const payload = try encodeControlRes(std.testing.allocator, res);
    defer std.testing.allocator.free(payload);

    var out = try parseControlRes(std.testing.allocator, payload);
    defer freeControlRes(std.testing.allocator, &out);
    try std.testing.expect(out.ok);
    try std.testing.expect(out.value != null);
    try std.testing.expect(out.value.?.exists != null);
    try std.testing.expect(out.value.?.exists.?);
    try std.testing.expect(out.value.?.status != null);
    try std.testing.expectEqualStrings("running", out.value.?.status.?);
}

test "protocol encode/decode event message" {
    const msg = EventMsg{ .kind = "session_exit", .code = 0 };
    const payload = try encodeEventMsg(std.testing.allocator, msg);
    defer std.testing.allocator.free(payload);

    var out = try parseEventMsg(std.testing.allocator, payload);
    defer freeEventMsg(std.testing.allocator, &out);
    try std.testing.expectEqualStrings("session_exit", out.kind);
    try std.testing.expectEqual(@as(?i32, 0), out.code);
}

test "protocol encode/decode lane request message" {
    const msg = LaneReqMsg{ .lane_id = "l1", .lane_kind = "owner_control", .req_type = "call", .seq = 1, .method = "attach", .args_json = "{\"path\":\"/tmp/target.msr\"}" };
    const payload = try encodeLaneReqMsg(std.testing.allocator, msg);
    defer std.testing.allocator.free(payload);

    var out = try parseLaneReqMsg(std.testing.allocator, payload);
    defer freeLaneReqMsg(std.testing.allocator, &out);
    try std.testing.expectEqualStrings("l1", out.lane_id);
    try std.testing.expectEqualStrings("owner_control", out.lane_kind);
    try std.testing.expectEqualStrings("call", out.req_type);
    try std.testing.expectEqual(@as(u32, 1), out.seq);
    try std.testing.expectEqualStrings("attach", out.method.?);
}

test "protocol encode/decode lane response message" {
    const msg = LaneResMsg{ .lane_id = "l1", .res_type = "return", .seq = 1, .value_json = "{}" };
    const payload = try encodeLaneResMsg(std.testing.allocator, msg);
    defer std.testing.allocator.free(payload);

    var out = try parseLaneResMsg(std.testing.allocator, payload);
    defer freeLaneResMsg(std.testing.allocator, &out);
    try std.testing.expectEqualStrings("l1", out.lane_id);
    try std.testing.expectEqualStrings("return", out.res_type);
    try std.testing.expectEqual(@as(u32, 1), out.seq);
    try std.testing.expectEqualStrings("{}", out.value_json.?);
}
