const std = @import("std");
const ByteQueue = @import("byte_queue").ByteQueue;
const wire = @import("session_wire2");
const core = @import("session_core2");

pub const Error = wire.Error;

const Builder = struct {
    list: std.ArrayList(u8),

    pub fn init() Builder {
        return .{ .list = .{} };
    }

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    pub fn appendByte(self: *Builder, allocator: std.mem.Allocator, b: u8) !void {
        try self.list.append(allocator, b);
    }

    pub fn appendInt(self: *Builder, allocator: std.mem.Allocator, comptime T: type, value: T) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        try self.list.appendSlice(allocator, &buf);
    }

    pub fn appendBytes(self: *Builder, allocator: std.mem.Allocator, bytes: []const u8) !void {
        try self.list.appendSlice(allocator, bytes);
    }

    pub fn appendLenBytes(self: *Builder, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len > std.math.maxInt(u32)) return error.FrameTooLarge;
        try self.appendInt(allocator, u32, @intCast(bytes.len));
        try self.appendBytes(allocator, bytes);
    }

    pub fn toOwnedSlice(self: *Builder, allocator: std.mem.Allocator) ![]u8 {
        return try self.list.toOwnedSlice(allocator);
    }
};

const Reader = struct {
    bytes: []const u8,
    off: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes, .off = 0 };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.off;
    }

    pub fn readByte(self: *Reader) !u8 {
        if (self.off >= self.bytes.len) return error.InvalidPayload;
        const out = self.bytes[self.off];
        self.off += 1;
        return out;
    }

    pub fn readInt(self: *Reader, comptime T: type) !T {
        if (self.remaining() < @sizeOf(T)) return error.InvalidPayload;
        const value = std.mem.readInt(T, self.bytes[self.off..][0..@sizeOf(T)], .little);
        self.off += @sizeOf(T);
        return value;
    }

    pub fn readLenBytes(self: *Reader) ![]const u8 {
        const n = try self.readInt(u32);
        if (self.remaining() < n) return error.InvalidPayload;
        const out = self.bytes[self.off .. self.off + n];
        self.off += n;
        return out;
    }

    pub fn finish(self: *Reader) !void {
        if (self.off != self.bytes.len) return error.InvalidPayload;
    }
};

const ControlReqTag = enum(u8) {
    status = 1,
    wait = 2,
    terminate = 3,
    attach = 4,
    detach = 5,
    resize = 6,
    owner_forward = 7,
};

const ControlResTag = enum(u8) {
    ok = 1,
    status = 2,
    exit_code = 3,
    exit_signal_text = 4,
    err = 5,
};

const ForwardActionTag = enum(u8) {
    detach = 1,
    attach = 2,
};

const OwnerResTag = enum(u8) {
    ok = 1,
    err = 2,
};

fn encodeAttachMode(mode: core.AttachMode) u8 {
    return switch (mode) {
        .exclusive => 1,
        .takeover => 2,
    };
}

fn decodeAttachMode(v: u8) !core.AttachMode {
    return switch (v) {
        1 => .exclusive,
        2 => .takeover,
        else => error.InvalidEnumValue,
    };
}

fn encodeErrorCode(code: core.ErrorCode) u8 {
    return switch (code) {
        .invalid_args => 1,
        .attach_conflict => 2,
        .no_owner => 3,
        .owner_not_ready => 4,
        .owner_busy => 5,
        .owner_disconnected => 6,
        .owner_replaced => 7,
        .pty_closed => 8,
    };
}

fn decodeErrorCode(v: u8) !core.ErrorCode {
    return switch (v) {
        1 => .invalid_args,
        2 => .attach_conflict,
        3 => .no_owner,
        4 => .owner_not_ready,
        5 => .owner_busy,
        6 => .owner_disconnected,
        7 => .owner_replaced,
        8 => .pty_closed,
        else => error.InvalidEnumValue,
    };
}

fn encodeSignal(sig: wire.Signal) u8 {
    return @intFromEnum(sig);
}

fn decodeSignal(v: u8) !wire.Signal {
    return switch (v) {
        @intFromEnum(wire.Signal.term) => .term,
        @intFromEnum(wire.Signal.int) => .int,
        @intFromEnum(wire.Signal.kill) => .kill,
        else => error.InvalidEnumValue,
    };
}

fn encodeSessionStatus(status: wire.SessionStatus) u8 {
    return @intFromEnum(status);
}

fn decodeSessionStatus(v: u8) !wire.SessionStatus {
    return switch (v) {
        @intFromEnum(wire.SessionStatus.starting) => .starting,
        @intFromEnum(wire.SessionStatus.running) => .running,
        @intFromEnum(wire.SessionStatus.exited) => .exited,
        @intFromEnum(wire.SessionStatus.idle) => .idle,
        @intFromEnum(wire.SessionStatus.closed) => .closed,
        else => error.InvalidEnumValue,
    };
}

fn appendForwardAction(builder: *Builder, allocator: std.mem.Allocator, action: core.ForwardAction) !void {
    switch (action) {
        .detach => try builder.appendByte(allocator, @intFromEnum(ForwardActionTag.detach)),
        .attach => |path| {
            try builder.appendByte(allocator, @intFromEnum(ForwardActionTag.attach));
            try builder.appendLenBytes(allocator, path);
        },
    }
}

fn parseForwardAction(allocator: std.mem.Allocator, reader: *Reader) !core.ForwardAction {
    const tag = try reader.readByte();
    return switch (tag) {
        @intFromEnum(ForwardActionTag.detach) => .detach,
        @intFromEnum(ForwardActionTag.attach) => blk: {
            const path = try reader.readLenBytes();
            break :blk .{ .attach = try allocator.dupe(u8, path) };
        },
        else => error.InvalidEnumValue,
    };
}

fn encodeControlReqPayload(allocator: std.mem.Allocator, req: wire.ControlReq) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(allocator);

    switch (req) {
        .status => try builder.appendByte(allocator, @intFromEnum(ControlReqTag.status)),
        .wait => try builder.appendByte(allocator, @intFromEnum(ControlReqTag.wait)),
        .terminate => |sig| {
            try builder.appendByte(allocator, @intFromEnum(ControlReqTag.terminate));
            try builder.appendByte(allocator, encodeSignal(sig));
        },
        .attach => |mode| {
            try builder.appendByte(allocator, @intFromEnum(ControlReqTag.attach));
            try builder.appendByte(allocator, encodeAttachMode(mode));
        },
        .detach => try builder.appendByte(allocator, @intFromEnum(ControlReqTag.detach)),
        .resize => |size| {
            try builder.appendByte(allocator, @intFromEnum(ControlReqTag.resize));
            try builder.appendInt(allocator, u16, size.cols);
            try builder.appendInt(allocator, u16, size.rows);
        },
        .owner_forward => |forward| {
            try builder.appendByte(allocator, @intFromEnum(ControlReqTag.owner_forward));
            try builder.appendInt(allocator, u32, forward.request_id);
            try appendForwardAction(&builder, allocator, forward.action);
        },
    }

    return try builder.toOwnedSlice(allocator);
}

fn parseControlReqPayload(allocator: std.mem.Allocator, payload: []const u8) !wire.ControlReq {
    var reader = Reader.init(payload);
    const tag = try reader.readByte();

    const req: wire.ControlReq = switch (tag) {
        @intFromEnum(ControlReqTag.status) => .status,
        @intFromEnum(ControlReqTag.wait) => .wait,
        @intFromEnum(ControlReqTag.terminate) => .{ .terminate = try decodeSignal(try reader.readByte()) },
        @intFromEnum(ControlReqTag.attach) => .{ .attach = try decodeAttachMode(try reader.readByte()) },
        @intFromEnum(ControlReqTag.detach) => .detach,
        @intFromEnum(ControlReqTag.resize) => .{ .resize = .{
            .cols = try reader.readInt(u16),
            .rows = try reader.readInt(u16),
        } },
        @intFromEnum(ControlReqTag.owner_forward) => .{ .owner_forward = .{
            .request_id = try reader.readInt(u32),
            .action = try parseForwardAction(allocator, &reader),
        } },
        else => return error.InvalidEnumValue,
    };

    try reader.finish();
    return req;
}

fn encodeControlResPayload(allocator: std.mem.Allocator, res: wire.ControlRes) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(allocator);

    switch (res) {
        .ok => try builder.appendByte(allocator, @intFromEnum(ControlResTag.ok)),
        .status => |status| {
            try builder.appendByte(allocator, @intFromEnum(ControlResTag.status));
            try builder.appendByte(allocator, encodeSessionStatus(status));
        },
        .exit => |exit| switch (exit) {
            .code => |code| {
                try builder.appendByte(allocator, @intFromEnum(ControlResTag.exit_code));
                try builder.appendInt(allocator, i32, code);
            },
            .signal_text => |sig| {
                try builder.appendByte(allocator, @intFromEnum(ControlResTag.exit_signal_text));
                try builder.appendLenBytes(allocator, sig);
            },
        },
        .err => |code| {
            try builder.appendByte(allocator, @intFromEnum(ControlResTag.err));
            try builder.appendByte(allocator, encodeErrorCode(code));
        },
    }

    return try builder.toOwnedSlice(allocator);
}

fn parseControlResPayload(allocator: std.mem.Allocator, payload: []const u8) !wire.ControlRes {
    var reader = Reader.init(payload);
    const tag = try reader.readByte();

    const res: wire.ControlRes = switch (tag) {
        @intFromEnum(ControlResTag.ok) => .ok,
        @intFromEnum(ControlResTag.status) => .{ .status = try decodeSessionStatus(try reader.readByte()) },
        @intFromEnum(ControlResTag.exit_code) => .{ .exit = .{ .code = try reader.readInt(i32) } },
        @intFromEnum(ControlResTag.exit_signal_text) => blk: {
            const text = try reader.readLenBytes();
            break :blk .{ .exit = .{ .signal_text = try allocator.dupe(u8, text) } };
        },
        @intFromEnum(ControlResTag.err) => .{ .err = try decodeErrorCode(try reader.readByte()) },
        else => return error.InvalidEnumValue,
    };

    try reader.finish();
    return res;
}

fn encodeOwnerReqPayload(allocator: std.mem.Allocator, req: wire.ForwardRequest) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(allocator);

    try builder.appendInt(allocator, u32, req.request_id);
    try appendForwardAction(&builder, allocator, req.action);
    return try builder.toOwnedSlice(allocator);
}

fn parseOwnerReqPayload(allocator: std.mem.Allocator, payload: []const u8) !wire.ForwardRequest {
    var reader = Reader.init(payload);

    const req = wire.ForwardRequest{
        .request_id = try reader.readInt(u32),
        .action = try parseForwardAction(allocator, &reader),
    };
    try reader.finish();
    return req;
}

fn encodeOwnerResPayload(allocator: std.mem.Allocator, res: wire.OwnerRes) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(allocator);

    try builder.appendInt(allocator, u32, res.request_id);
    if (res.ok) {
        try builder.appendByte(allocator, @intFromEnum(OwnerResTag.ok));
    } else {
        try builder.appendByte(allocator, @intFromEnum(OwnerResTag.err));
        try builder.appendByte(allocator, encodeErrorCode(res.code orelse .invalid_args));
    }

    return try builder.toOwnedSlice(allocator);
}

fn parseOwnerResPayload(payload: []const u8) !wire.OwnerRes {
    var reader = Reader.init(payload);

    const request_id = try reader.readInt(u32);
    const tag = try reader.readByte();

    const res = switch (tag) {
        @intFromEnum(OwnerResTag.ok) => wire.OwnerRes{
            .request_id = request_id,
            .ok = true,
            .code = null,
        },
        @intFromEnum(OwnerResTag.err) => wire.OwnerRes{
            .request_id = request_id,
            .ok = false,
            .code = try decodeErrorCode(try reader.readByte()),
        },
        else => return error.InvalidEnumValue,
    };

    try reader.finish();
    return res;
}

fn encodeResizePayload(allocator: std.mem.Allocator, size: core.Size) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(allocator);

    try builder.appendInt(allocator, u16, size.cols);
    try builder.appendInt(allocator, u16, size.rows);
    return try builder.toOwnedSlice(allocator);
}

fn parseResizePayload(payload: []const u8) !core.Size {
    var reader = Reader.init(payload);
    const size = core.Size{
        .cols = try reader.readInt(u16),
        .rows = try reader.readInt(u16),
    };
    try reader.finish();
    return size;
}

fn kindFromByte(v: u8) !wire.Kind {
    return switch (v) {
        @intFromEnum(wire.Kind.control_req) => .control_req,
        @intFromEnum(wire.Kind.control_res) => .control_res,
        @intFromEnum(wire.Kind.owner_req) => .owner_req,
        @intFromEnum(wire.Kind.owner_res) => .owner_res,
        @intFromEnum(wire.Kind.owner_ready) => .owner_ready,
        @intFromEnum(wire.Kind.owner_resize) => .owner_resize,
        @intFromEnum(wire.Kind.stdin_bytes) => .stdin_bytes,
        @intFromEnum(wire.Kind.stdout_bytes) => .stdout_bytes,
        else => error.BadMessageType,
    };
}

pub fn encodeMessage(allocator: std.mem.Allocator, msg: wire.Message) ![]u8 {
    const kind: wire.Kind, const payload: []u8 = switch (msg) {
        .stdin_bytes => |bytes| .{ .stdin_bytes, try allocator.dupe(u8, bytes) },
        .stdout_bytes => |bytes| .{ .stdout_bytes, try allocator.dupe(u8, bytes) },
        .owner_ready => .{ .owner_ready, try allocator.alloc(u8, 0) },
        .owner_resize => |size| .{ .owner_resize, try encodeResizePayload(allocator, size) },
        .control_req => |req| .{ .control_req, try encodeControlReqPayload(allocator, req) },
        .control_res => |res| .{ .control_res, try encodeControlResPayload(allocator, res) },
        .owner_req => |req| .{ .owner_req, try encodeOwnerReqPayload(allocator, req) },
        .owner_res => |res| .{ .owner_res, try encodeOwnerResPayload(allocator, res) },
    };
    defer allocator.free(payload);

    const total_len = 1 + payload.len;
    if (total_len > std.math.maxInt(u32)) return error.FrameTooLarge;

    const out = try allocator.alloc(u8, 4 + total_len);
    errdefer allocator.free(out);

    std.mem.writeInt(u32, out[0..4], @intCast(total_len), .little);
    out[4] = @intFromEnum(kind);
    if (payload.len > 0) {
        std.mem.copyForwards(u8, out[5 .. 5 + payload.len], payload);
    }

    return out;
}

pub fn tryDecodeMessage(
    allocator: std.mem.Allocator,
    queue: *ByteQueue,
    max_frame_len: usize,
) !?wire.Message {
    const prefix = queue.readableSlice();
    if (prefix.len < 4) return null;

    const prefix_arr: *const [4]u8 = @ptrCast(prefix.ptr);
    const total_len = std.mem.readInt(u32, prefix_arr, .little);
    if (total_len == 0) return error.BadFrame;
    if (total_len > max_frame_len) return error.FrameTooLarge;

    const full_len: usize = 4 + total_len;
    if (queue.len() < full_len) return null;

    const frame = queue.readableSlice()[4..full_len];
    const kind = try kindFromByte(frame[0]);
    const payload = frame[1..];

    const msg: wire.Message = switch (kind) {
        .stdin_bytes => .{ .stdin_bytes = try allocator.dupe(u8, payload) },
        .stdout_bytes => .{ .stdout_bytes = try allocator.dupe(u8, payload) },
        .owner_ready => .owner_ready,
        .owner_resize => .{ .owner_resize = try parseResizePayload(payload) },
        .control_req => .{ .control_req = try parseControlReqPayload(allocator, payload) },
        .control_res => .{ .control_res = try parseControlResPayload(allocator, payload) },
        .owner_req => .{ .owner_req = try parseOwnerReqPayload(allocator, payload) },
        .owner_res => .{ .owner_res = try parseOwnerResPayload(payload) },
    };

    queue.discard(full_len);
    return msg;
}

test "incremental codec decodes only when full frame is present" {
    var q = ByteQueue.init();
    defer q.deinit(std.testing.allocator);

    const hello = try std.testing.allocator.dupe(u8, "hello");
    defer std.testing.allocator.free(hello);

    const encoded = try encodeMessage(std.testing.allocator, .{ .stdout_bytes = hello });
    defer std.testing.allocator.free(encoded);

    try q.append(std.testing.allocator, encoded[0..3]);
    try std.testing.expect((try tryDecodeMessage(std.testing.allocator, &q, 1024)) == null);

    try q.append(std.testing.allocator, encoded[3..]);
    var msg = (try tryDecodeMessage(std.testing.allocator, &q, 1024)).?;
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .stdout_bytes => |bytes| try std.testing.expectEqualStrings("hello", bytes),
        else => return error.TestUnexpectedResult,
    }
}
