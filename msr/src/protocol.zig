const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
});

pub const OwnerAction = struct {
    op: []const u8,
    path: ?[]const u8 = null,
};



pub const ControlReq = struct {
    op: []const u8,
    path: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    signal: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    request_id: ?u32 = null,
    action: ?OwnerAction = null,
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

pub const OwnerControlReq = struct {
    request_id: u32,
    action: OwnerAction,
};

pub const OwnerControlRes = struct {
    request_id: u32,
    ok: bool,
    err: ?ControlRes.ErrBody = null,
};

pub const OwnerReady = struct {};

pub const OwnerResize = struct {
    cols: u16,
    rows: u16,
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

pub const Message = union(enum) {
    control_req: ControlReq,
    control_res: ControlRes,
    owner_control_req: OwnerControlReq,
    owner_control_res: OwnerControlRes,
    owner_ready: OwnerReady,
    owner_resize: OwnerResize,
    data: DataMsg,
    event: EventMsg,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .control_req => |*msg| freeControlReq(allocator, msg),
            .control_res => |*msg| freeControlRes(allocator, msg),
            .owner_control_req => |*msg| freeOwnerControlReq(allocator, msg),
            .owner_control_res => |*msg| freeOwnerControlRes(allocator, msg),
            .owner_ready => {},
            .owner_resize => {},
            .data => |*msg| freeDataMsg(allocator, msg),
            .event => |*msg| freeEventMsg(allocator, msg),
        }
    }
};

pub fn freeOwnerAction(allocator: std.mem.Allocator, action: *OwnerAction) void {
    allocator.free(@constCast(action.op));
    if (action.path) |v| allocator.free(@constCast(v));
}

pub fn freeControlReq(allocator: std.mem.Allocator, req: *ControlReq) void {
    allocator.free(@constCast(req.op));
    if (req.path) |v| allocator.free(@constCast(v));
    if (req.signal) |v| allocator.free(@constCast(v));
    if (req.mode) |v| allocator.free(@constCast(v));
    if (req.action) |*action| freeOwnerAction(allocator, action);
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

pub fn freeOwnerControlReq(allocator: std.mem.Allocator, req: *OwnerControlReq) void {
    freeOwnerAction(allocator, &req.action);
}

pub fn freeOwnerControlRes(allocator: std.mem.Allocator, res: *OwnerControlRes) void {
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
    return encodeMessage(allocator, .{ .control_req = req });
}

pub fn encodeControlRes(allocator: std.mem.Allocator, res: ControlRes) ![]u8 {
    return encodeMessage(allocator, .{ .control_res = res });
}

pub fn encodeOwnerControlReq(allocator: std.mem.Allocator, req: OwnerControlReq) ![]u8 {
    return encodeMessage(allocator, .{ .owner_control_req = req });
}

pub fn encodeOwnerControlRes(allocator: std.mem.Allocator, res: OwnerControlRes) ![]u8 {
    return encodeMessage(allocator, .{ .owner_control_res = res });
}

pub fn encodeOwnerReady(allocator: std.mem.Allocator) ![]u8 {
    return encodeMessage(allocator, .{ .owner_ready = .{} });
}

pub fn encodeOwnerResize(allocator: std.mem.Allocator, msg: OwnerResize) ![]u8 {
    return encodeMessage(allocator, .{ .owner_resize = msg });
}

pub fn encodeDataMsg(allocator: std.mem.Allocator, msg: DataMsg) ![]u8 {
    return encodeMessage(allocator, .{ .data = msg });
}

pub fn encodeEventMsg(allocator: std.mem.Allocator, msg: EventMsg) ![]u8 {
    return encodeMessage(allocator, .{ .event = msg });
}

pub fn parseControlReq(allocator: std.mem.Allocator, bytes: []const u8) !ControlReq {
    var msg = try parseMessage(allocator, bytes);
    errdefer msg.deinit(allocator);
    return switch (msg) {
        .control_req => |req| req,
        else => error.BadMessageType,
    };
}

pub fn parseControlRes(allocator: std.mem.Allocator, bytes: []const u8) !ControlRes {
    var msg = try parseMessage(allocator, bytes);
    errdefer msg.deinit(allocator);
    return switch (msg) {
        .control_res => |res| res,
        else => error.BadMessageType,
    };
}

pub fn parseOwnerControlReq(allocator: std.mem.Allocator, bytes: []const u8) !OwnerControlReq {
    var msg = try parseMessage(allocator, bytes);
    errdefer msg.deinit(allocator);
    return switch (msg) {
        .owner_control_req => |req| req,
        else => error.BadMessageType,
    };
}

pub fn parseOwnerControlRes(allocator: std.mem.Allocator, bytes: []const u8) !OwnerControlRes {
    var msg = try parseMessage(allocator, bytes);
    errdefer msg.deinit(allocator);
    return switch (msg) {
        .owner_control_res => |res| res,
        else => error.BadMessageType,
    };
}

pub fn parseOwnerReady(allocator: std.mem.Allocator, bytes: []const u8) !OwnerReady {
    var msg = try parseMessage(allocator, bytes);
    errdefer msg.deinit(allocator);
    return switch (msg) {
        .owner_ready => |ready| ready,
        else => error.BadMessageType,
    };
}

pub fn parseOwnerResize(allocator: std.mem.Allocator, bytes: []const u8) !OwnerResize {
    var msg = try parseMessage(allocator, bytes);
    errdefer msg.deinit(allocator);
    return switch (msg) {
        .owner_resize => |resize| resize,
        else => error.BadMessageType,
    };
}

pub fn parseDataMsg(allocator: std.mem.Allocator, bytes: []const u8) !DataMsg {
    var msg = try parseMessage(allocator, bytes);
    errdefer msg.deinit(allocator);
    return switch (msg) {
        .data => |data| data,
        else => error.BadMessageType,
    };
}

pub fn parseEventMsg(allocator: std.mem.Allocator, bytes: []const u8) !EventMsg {
    var msg = try parseMessage(allocator, bytes);
    errdefer msg.deinit(allocator);
    return switch (msg) {
        .event => |event| event,
        else => error.BadMessageType,
    };
}

pub fn encodeMessage(allocator: std.mem.Allocator, msg: Message) ![]u8 {
    return switch (msg) {
        .control_req => |payload| encodeEnvelope(allocator, "control_req", payload),
        .control_res => |payload| encodeEnvelope(allocator, "control_res", payload),
        .owner_control_req => |payload| encodeEnvelope(allocator, "owner_control_req", payload),
        .owner_control_res => |payload| encodeEnvelope(allocator, "owner_control_res", payload),
        .owner_ready => |payload| encodeEnvelope(allocator, "owner_ready", payload),
        .owner_resize => |payload| encodeEnvelope(allocator, "owner_resize", payload),
        .data => |payload| encodeEnvelope(allocator, "data", payload),
        .event => |payload| encodeEnvelope(allocator, "event", payload),
    };
}

pub fn parseMessage(allocator: std.mem.Allocator, bytes: []const u8) !Message {
    const EnvType = struct { type: []const u8 };
    var parsed = try std.json.parseFromSlice(EnvType, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.type, "control_req")) {
        return .{ .control_req = try parseEnvelopePayload(ControlReq, cloneControlReq, allocator, bytes, "control_req") };
    }
    if (std.mem.eql(u8, parsed.value.type, "control_res")) {
        return .{ .control_res = try parseEnvelopePayload(ControlRes, cloneControlRes, allocator, bytes, "control_res") };
    }
    if (std.mem.eql(u8, parsed.value.type, "owner_control_req")) {
        return .{ .owner_control_req = try parseEnvelopePayload(OwnerControlReq, cloneOwnerControlReq, allocator, bytes, "owner_control_req") };
    }
    if (std.mem.eql(u8, parsed.value.type, "owner_control_res")) {
        return .{ .owner_control_res = try parseEnvelopePayload(OwnerControlRes, cloneOwnerControlRes, allocator, bytes, "owner_control_res") };
    }
    if (std.mem.eql(u8, parsed.value.type, "owner_ready")) {
        return .{ .owner_ready = try parseEnvelopePayload(OwnerReady, cloneOwnerReady, allocator, bytes, "owner_ready") };
    }
    if (std.mem.eql(u8, parsed.value.type, "owner_resize")) {
        return .{ .owner_resize = try parseEnvelopePayload(OwnerResize, cloneOwnerResize, allocator, bytes, "owner_resize") };
    }
    if (std.mem.eql(u8, parsed.value.type, "data")) {
        return .{ .data = try parseEnvelopePayload(DataMsg, cloneDataMsg, allocator, bytes, "data") };
    }
    if (std.mem.eql(u8, parsed.value.type, "event")) {
        return .{ .event = try parseEnvelopePayload(EventMsg, cloneEventMsg, allocator, bytes, "event") };
    }
    return error.BadMessageType;
}

fn encodeEnvelope(allocator: std.mem.Allocator, comptime type_name: []const u8, payload: anytype) ![]u8 {
    const env = .{ .type = type_name, .payload = payload };
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(env, .{})});
}

fn parseEnvelopePayload(comptime T: type, comptime cloneFn: fn (std.mem.Allocator, T) anyerror!T, allocator: std.mem.Allocator, bytes: []const u8, comptime expected_type: []const u8) !T {
    const Env = struct {
        type: []const u8,
        payload: T,
    };
    var parsed = try std.json.parseFromSlice(Env, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, expected_type)) return error.BadMessageType;
    return try cloneFn(allocator, parsed.value.payload);
}

fn cloneOwnerAction(allocator: std.mem.Allocator, action: OwnerAction) !OwnerAction {
    return .{
        .op = try allocator.dupe(u8, action.op),
        .path = if (action.path) |v| try allocator.dupe(u8, v) else null,
    };
}

fn cloneControlReq(allocator: std.mem.Allocator, req: ControlReq) !ControlReq {
    return .{
        .op = try allocator.dupe(u8, req.op),
        .path = if (req.path) |v| try allocator.dupe(u8, v) else null,
        .cols = req.cols,
        .rows = req.rows,
        .signal = if (req.signal) |v| try allocator.dupe(u8, v) else null,
        .mode = if (req.mode) |v| try allocator.dupe(u8, v) else null,
        .request_id = req.request_id,
        .action = if (req.action) |action| try cloneOwnerAction(allocator, action) else null,
    };
}

fn cloneControlRes(allocator: std.mem.Allocator, res: ControlRes) !ControlRes {
    var out: ControlRes = .{ .ok = res.ok, .value = null, .err = null };
    if (res.value) |v| {
        out.value = .{
            .exists = v.exists,
            .status = if (v.status) |s| try allocator.dupe(u8, s) else null,
            .code = v.code,
            .signal = if (v.signal) |s| try allocator.dupe(u8, s) else null,
        };
    }
    if (res.err) |e| {
        out.err = .{
            .code = try allocator.dupe(u8, e.code),
            .message = if (e.message) |m| try allocator.dupe(u8, m) else null,
        };
    }
    return out;
}

pub fn cloneControlResOwned(allocator: std.mem.Allocator, res: ControlRes) !ControlRes {
    return cloneControlRes(allocator, res);
}

fn cloneOwnerControlReq(allocator: std.mem.Allocator, req: OwnerControlReq) !OwnerControlReq {
    return .{
        .request_id = req.request_id,
        .action = try cloneOwnerAction(allocator, req.action),
    };
}

fn cloneOwnerControlRes(allocator: std.mem.Allocator, res: OwnerControlRes) !OwnerControlRes {
    return .{
        .request_id = res.request_id,
        .ok = res.ok,
        .err = if (res.err) |e| .{
            .code = try allocator.dupe(u8, e.code),
            .message = if (e.message) |m| try allocator.dupe(u8, m) else null,
        } else null,
    };
}

fn cloneOwnerReady(allocator: std.mem.Allocator, ready: OwnerReady) !OwnerReady {
    _ = allocator;
    return ready;
}

fn cloneOwnerResize(allocator: std.mem.Allocator, resize: OwnerResize) !OwnerResize {
    _ = allocator;
    return resize;
}

fn cloneDataMsg(allocator: std.mem.Allocator, msg: DataMsg) !DataMsg {
    return .{
        .stream = try allocator.dupe(u8, msg.stream),
        .bytes_b64 = try allocator.dupe(u8, msg.bytes_b64),
    };
}

fn cloneEventMsg(allocator: std.mem.Allocator, msg: EventMsg) !EventMsg {
    return .{
        .kind = try allocator.dupe(u8, msg.kind),
        .code = msg.code,
        .signal = if (msg.signal) |s| try allocator.dupe(u8, s) else null,
    };
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            const e = std.c.errno(-1);
            if (e == .INTR or e == .AGAIN) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn readExact(fd: c_int, dst: []u8) !void {
    var off: usize = 0;
    while (off < dst.len) {
        const n = c.read(fd, dst.ptr + off, dst.len - off);
        if (n < 0) {
            const e = std.c.errno(-1);
            if (e == .INTR or e == .AGAIN) continue;
            return error.ReadFailed;
        }
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

test "protocol encode/decode owner_forward control request" {
    const req = ControlReq{ .op = "owner_forward", .request_id = 42, .action = .{ .op = "attach", .path = "/tmp/target.msr" } };
    const payload = try encodeControlReq(std.testing.allocator, req);
    defer std.testing.allocator.free(payload);

    var out = try parseControlReq(std.testing.allocator, payload);
    defer freeControlReq(std.testing.allocator, &out);
    try std.testing.expectEqualStrings("owner_forward", out.op);
    try std.testing.expectEqual(@as(?u32, 42), out.request_id);
    try std.testing.expect(out.action != null);
    try std.testing.expectEqualStrings("attach", out.action.?.op);
    try std.testing.expect(out.action.?.path != null);
    try std.testing.expectEqualStrings("/tmp/target.msr", out.action.?.path.?);
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

test "protocol encode/decode owner control request" {
    const msg = OwnerControlReq{ .request_id = 7, .action = .{ .op = "detach" } };
    const payload = try encodeOwnerControlReq(std.testing.allocator, msg);
    defer std.testing.allocator.free(payload);

    var out = try parseOwnerControlReq(std.testing.allocator, payload);
    defer freeOwnerControlReq(std.testing.allocator, &out);
    try std.testing.expectEqual(@as(u32, 7), out.request_id);
    try std.testing.expectEqualStrings("detach", out.action.op);
}

test "protocol encode/decode owner control response" {
    const msg = OwnerControlRes{ .request_id = 7, .ok = false, .err = .{ .code = "attach_conflict", .message = "owner already attached" } };
    const payload = try encodeOwnerControlRes(std.testing.allocator, msg);
    defer std.testing.allocator.free(payload);

    var out = try parseOwnerControlRes(std.testing.allocator, payload);
    defer freeOwnerControlRes(std.testing.allocator, &out);
    try std.testing.expectEqual(@as(u32, 7), out.request_id);
    try std.testing.expect(!out.ok);
    try std.testing.expect(out.err != null);
    try std.testing.expectEqualStrings("attach_conflict", out.err.?.code);
    try std.testing.expectEqualStrings("owner already attached", out.err.?.message.?);
}

test "protocol encode/decode owner ready" {
    const payload = try encodeOwnerReady(std.testing.allocator);
    defer std.testing.allocator.free(payload);

    _ = try parseOwnerReady(std.testing.allocator, payload);
}

test "protocol parseMessage identifies unified message variants" {
    const payload = try encodeOwnerControlReq(std.testing.allocator, .{ .request_id = 9, .action = .{ .op = "detach" } });
    defer std.testing.allocator.free(payload);

    var msg = try parseMessage(std.testing.allocator, payload);
    defer msg.deinit(std.testing.allocator);
    switch (msg) {
        .owner_control_req => |req| {
            try std.testing.expectEqual(@as(u32, 9), req.request_id);
            try std.testing.expectEqualStrings("detach", req.action.op);
        },
        else => return error.TestUnexpectedResult,
    }
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

