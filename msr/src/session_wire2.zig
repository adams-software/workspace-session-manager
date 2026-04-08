const std = @import("std");
const core = @import("session_core2");
const c = @cImport({
    @cInclude("unistd.h");
});

pub const Error = error{
    BadFrame,
    BadMessageType,
    FrameTooLarge,
    InvalidEnumValue,
    InvalidPayload,
    ReadFailed,
    WriteFailed,
    UnexpectedEof,
};

pub const Kind = enum(u8) {
    control_req = 1,
    control_res = 2,
    owner_req = 3,
    owner_res = 4,
    owner_ready = 5,
    owner_resize = 6,
    stdin_bytes = 7,
    stdout_bytes = 8,
};

pub const SessionStatus = enum(u8) {
    starting = 1,
    running = 2,
    exited = 3,
    idle = 4,
    closed = 5,
};

pub const Signal = enum(u8) {
    term = 1,
    int = 2,
    kill = 3,
};

pub const ExitStatus = union(enum) {
    code: i32,
    signal_text: []u8,

    pub fn deinit(self: *ExitStatus, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .code => {},
            .signal_text => |s| allocator.free(s),
        }
    }
};

pub const ForwardRequest = struct {
    request_id: u32,
    action: core.ForwardAction,

    pub fn deinit(self: *ForwardRequest, allocator: std.mem.Allocator) void {
        self.action.deinit(allocator);
    }
};

pub const ControlReq = union(enum) {
    status,
    wait,
    terminate: Signal,
    attach: core.AttachMode,
    detach,
    resize: core.Size,
    owner_forward: ForwardRequest,

    pub fn deinit(self: *ControlReq, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .owner_forward => |*req| req.deinit(allocator),
            else => {},
        }
    }
};

pub const ControlRes = union(enum) {
    ok,
    status: SessionStatus,
    exit: ExitStatus,
    err: core.ErrorCode,

    pub fn deinit(self: *ControlRes, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exit => |*exit| exit.deinit(allocator),
            else => {},
        }
    }
};

pub const OwnerRes = struct {
    request_id: u32,
    ok: bool,
    code: ?core.ErrorCode = null,
};

pub const Message = union(enum) {
    control_req: ControlReq,
    control_res: ControlRes,
    owner_req: ForwardRequest,
    owner_res: OwnerRes,
    owner_ready,
    owner_resize: core.Size,
    stdin_bytes: []u8,
    stdout_bytes: []u8,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .control_req => |*msg| msg.deinit(allocator),
            .control_res => |*msg| msg.deinit(allocator),
            .owner_req => |*msg| msg.deinit(allocator),
            .owner_res => {},
            .owner_ready => {},
            .owner_resize => {},
            .stdin_bytes => |bytes| allocator.free(bytes),
            .stdout_bytes => |bytes| allocator.free(bytes),
        }
    }
};

pub const Frame = struct {
    kind: Kind,
    payload: []u8,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
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
        if (self.off >= self.bytes.len) return Error.InvalidPayload;
        const out = self.bytes[self.off];
        self.off += 1;
        return out;
    }

    pub fn readInt(self: *Reader, comptime T: type) !T {
        if (self.remaining() < @sizeOf(T)) return Error.InvalidPayload;
        const value = std.mem.readInt(T, self.bytes[self.off..][0..@sizeOf(T)], .little);
        self.off += @sizeOf(T);
        return value;
    }

    pub fn readLenBytes(self: *Reader) ![]const u8 {
        const n = try self.readInt(u32);
        if (self.remaining() < n) return Error.InvalidPayload;
        const out = self.bytes[self.off .. self.off + n];
        self.off += n;
        return out;
    }

    pub fn finish(self: *Reader) !void {
        if (self.off != self.bytes.len) return Error.InvalidPayload;
    }
};

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            const e = std.c.errno(-1);
            if (e == .INTR or e == .AGAIN) continue;
            return Error.WriteFailed;
        }
        if (n == 0) return Error.WriteFailed;
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
            return Error.ReadFailed;
        }
        if (n == 0) return Error.UnexpectedEof;
        off += @intCast(n);
    }
}

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
        else => Error.InvalidEnumValue,
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
        else => Error.InvalidEnumValue,
    };
}

fn encodeSignal(sig: Signal) u8 {
    return @intFromEnum(sig);
}

fn encodeSessionStatus(status: SessionStatus) u8 {
    return @intFromEnum(status);
}

fn decodeSignal(v: u8) !Signal {
    return switch (v) {
        @intFromEnum(Signal.term) => .term,
        @intFromEnum(Signal.int) => .int,
        @intFromEnum(Signal.kill) => .kill,
        else => Error.InvalidEnumValue,
    };
}

fn decodeSessionStatus(v: u8) !SessionStatus {
    return switch (v) {
        @intFromEnum(SessionStatus.starting) => .starting,
        @intFromEnum(SessionStatus.running) => .running,
        @intFromEnum(SessionStatus.exited) => .exited,
        @intFromEnum(SessionStatus.idle) => .idle,
        @intFromEnum(SessionStatus.closed) => .closed,
        else => Error.InvalidEnumValue,
    };
}

fn appendForwardAction(
    builder: *Builder,
    allocator: std.mem.Allocator,
    action: core.ForwardAction,
) !void {
    switch (action) {
        .detach => {
            try builder.appendByte(allocator, @intFromEnum(ForwardActionTag.detach));
        },
        .attach => |path| {
            try builder.appendByte(allocator, @intFromEnum(ForwardActionTag.attach));
            try builder.appendLenBytes(allocator, path);
        },
    }
}

fn parseForwardAction(
    allocator: std.mem.Allocator,
    reader: *Reader,
) !core.ForwardAction {
    const tag = try reader.readByte();
    return switch (tag) {
        @intFromEnum(ForwardActionTag.detach) => .detach,
        @intFromEnum(ForwardActionTag.attach) => blk: {
            const path = try reader.readLenBytes();
            break :blk .{ .attach = try allocator.dupe(u8, path) };
        },
        else => Error.InvalidEnumValue,
    };
}

fn encodeControlReqPayload(
    allocator: std.mem.Allocator,
    req: ControlReq,
) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(allocator);

    switch (req) {
        .status => {
            try builder.appendByte(allocator, @intFromEnum(ControlReqTag.status));
        },
        .wait => {
            try builder.appendByte(allocator, @intFromEnum(ControlReqTag.wait));
        },
        .terminate => |sig| {
            try builder.appendByte(allocator, @intFromEnum(ControlReqTag.terminate));
            try builder.appendByte(allocator, encodeSignal(sig));
        },
        .attach => |mode| {
            try builder.appendByte(allocator, @intFromEnum(ControlReqTag.attach));
            try builder.appendByte(allocator, encodeAttachMode(mode));
        },
        .detach => {
            try builder.appendByte(allocator, @intFromEnum(ControlReqTag.detach));
        },
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

fn parseControlReqPayload(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !ControlReq {
    var reader = Reader.init(payload);
    const tag = try reader.readByte();

    const req: ControlReq = switch (tag) {
        @intFromEnum(ControlReqTag.status) => .status,
        @intFromEnum(ControlReqTag.wait) => .wait,
        @intFromEnum(ControlReqTag.terminate) => .{ .terminate = try decodeSignal(try reader.readByte()) },
        @intFromEnum(ControlReqTag.attach) => .{ .attach = try decodeAttachMode(try reader.readByte()) },
        @intFromEnum(ControlReqTag.detach) => .detach,
        @intFromEnum(ControlReqTag.resize) => .{
            .resize = .{
                .cols = try reader.readInt(u16),
                .rows = try reader.readInt(u16),
            },
        },
        @intFromEnum(ControlReqTag.owner_forward) => .{
            .owner_forward = .{
                .request_id = try reader.readInt(u32),
                .action = try parseForwardAction(allocator, &reader),
            },
        },
        else => return Error.InvalidEnumValue,
    };

    try reader.finish();
    return req;
}

fn encodeControlResPayload(
    allocator: std.mem.Allocator,
    res: ControlRes,
) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(allocator);

    switch (res) {
        .ok => {
            try builder.appendByte(allocator, @intFromEnum(ControlResTag.ok));
        },
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

fn parseControlResPayload(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !ControlRes {
    var reader = Reader.init(payload);
    const tag = try reader.readByte();

    const res: ControlRes = switch (tag) {
        @intFromEnum(ControlResTag.ok) => .ok,
        @intFromEnum(ControlResTag.status) => .{ .status = try decodeSessionStatus(try reader.readByte()) },
        @intFromEnum(ControlResTag.exit_code) => .{ .exit = .{ .code = try reader.readInt(i32) } },
        @intFromEnum(ControlResTag.exit_signal_text) => blk: {
            const text = try reader.readLenBytes();
            break :blk .{ .exit = .{ .signal_text = try allocator.dupe(u8, text) } };
        },
        @intFromEnum(ControlResTag.err) => .{ .err = try decodeErrorCode(try reader.readByte()) },
        else => return Error.InvalidEnumValue,
    };

    try reader.finish();
    return res;
}

fn encodeOwnerReqPayload(
    allocator: std.mem.Allocator,
    req: ForwardRequest,
) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(allocator);

    try builder.appendInt(allocator, u32, req.request_id);
    try appendForwardAction(&builder, allocator, req.action);

    return try builder.toOwnedSlice(allocator);
}

fn parseOwnerReqPayload(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !ForwardRequest {
    var reader = Reader.init(payload);

    const req = ForwardRequest{
        .request_id = try reader.readInt(u32),
        .action = try parseForwardAction(allocator, &reader),
    };

    try reader.finish();
    return req;
}

fn encodeOwnerResPayload(
    allocator: std.mem.Allocator,
    res: OwnerRes,
) ![]u8 {
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

fn parseOwnerResPayload(payload: []const u8) !OwnerRes {
    var reader = Reader.init(payload);

    const request_id = try reader.readInt(u32);
    const tag = try reader.readByte();

    const res = switch (tag) {
        @intFromEnum(OwnerResTag.ok) => OwnerRes{
            .request_id = request_id,
            .ok = true,
            .code = null,
        },
        @intFromEnum(OwnerResTag.err) => OwnerRes{
            .request_id = request_id,
            .ok = false,
            .code = try decodeErrorCode(try reader.readByte()),
        },
        else => return Error.InvalidEnumValue,
    };

    try reader.finish();
    return res;
}

fn encodeResizePayload(
    allocator: std.mem.Allocator,
    size: core.Size,
) ![]u8 {
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

pub fn writeFrameParts(
    fd: c_int,
    kind: Kind,
    parts: []const []const u8,
) !void {
    var total_len: usize = 1;
    for (parts) |part| total_len += part.len;
    if (total_len > std.math.maxInt(u32)) return Error.FrameTooLarge;

    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(total_len), .little);

    const kind_byte = [1]u8{@intFromEnum(kind)};

    try writeAll(fd, &hdr);
    try writeAll(fd, &kind_byte);
    for (parts) |part| {
        try writeAll(fd, part);
    }
}

pub fn readFrameOwned(
    allocator: std.mem.Allocator,
    fd: c_int,
    max_len: usize,
) !Frame {
    var hdr: [4]u8 = undefined;
    try readExact(fd, &hdr);

    const total_len = std.mem.readInt(u32, &hdr, .little);
    if (total_len == 0) return Error.BadFrame;
    if (total_len > max_len) return Error.FrameTooLarge;

    var kind_buf: [1]u8 = undefined;
    try readExact(fd, &kind_buf);

    const kind: Kind = switch (kind_buf[0]) {
    @intFromEnum(Kind.control_req) => .control_req,
    @intFromEnum(Kind.control_res) => .control_res,
    @intFromEnum(Kind.owner_req) => .owner_req,
    @intFromEnum(Kind.owner_res) => .owner_res,
    @intFromEnum(Kind.owner_ready) => .owner_ready,
    @intFromEnum(Kind.owner_resize) => .owner_resize,
    @intFromEnum(Kind.stdin_bytes) => .stdin_bytes,
    @intFromEnum(Kind.stdout_bytes) => .stdout_bytes,
    else => return Error.BadMessageType,
};
    const payload_len: usize = total_len - 1;

    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try readExact(fd, payload);

    return .{
        .kind = kind,
        .payload = payload,
    };
}

pub fn writeMessage(
    allocator: std.mem.Allocator,
    fd: c_int,
    msg: Message,
) !void {
    switch (msg) {
        .stdin_bytes => |bytes| return writeFrameParts(fd, .stdin_bytes, &.{bytes}),
        .stdout_bytes => |bytes| return writeFrameParts(fd, .stdout_bytes, &.{bytes}),
        .owner_ready => return writeFrameParts(fd, .owner_ready, &.{}),
        .owner_resize => |size| {
            const payload = try encodeResizePayload(allocator, size);
            defer allocator.free(payload);
            return writeFrameParts(fd, .owner_resize, &.{payload});
        },
        .control_req => |req| {
            const payload = try encodeControlReqPayload(allocator, req);
            defer allocator.free(payload);
            return writeFrameParts(fd, .control_req, &.{payload});
        },
        .control_res => |res| {
            const payload = try encodeControlResPayload(allocator, res);
            defer allocator.free(payload);
            return writeFrameParts(fd, .control_res, &.{payload});
        },
        .owner_req => |req| {
            const payload = try encodeOwnerReqPayload(allocator, req);
            defer allocator.free(payload);
            return writeFrameParts(fd, .owner_req, &.{payload});
        },
        .owner_res => |res| {
            const payload = try encodeOwnerResPayload(allocator, res);
            defer allocator.free(payload);
            return writeFrameParts(fd, .owner_res, &.{payload});
        },
    }
}

pub fn readMessage(
    allocator: std.mem.Allocator,
    fd: c_int,
    max_len: usize,
) !Message {
    var frame = try readFrameOwned(allocator, fd, max_len);
    errdefer frame.deinit(allocator);

    return switch (frame.kind) {
        .stdin_bytes => .{ .stdin_bytes = frame.payload },
        .stdout_bytes => .{ .stdout_bytes = frame.payload },
        .owner_ready => blk: {
            allocator.free(frame.payload);
            break :blk .owner_ready;
        },
        .owner_resize => blk: {
            defer allocator.free(frame.payload);
            break :blk .{ .owner_resize = try parseResizePayload(frame.payload) };
        },
        .control_req => blk: {
            defer allocator.free(frame.payload);
            break :blk .{ .control_req = try parseControlReqPayload(allocator, frame.payload) };
        },
        .control_res => blk: {
            defer allocator.free(frame.payload);
            break :blk .{ .control_res = try parseControlResPayload(allocator, frame.payload) };
        },
        .owner_req => blk: {
            defer allocator.free(frame.payload);
            break :blk .{ .owner_req = try parseOwnerReqPayload(allocator, frame.payload) };
        },
        .owner_res => blk: {
            defer allocator.free(frame.payload);
            break :blk .{ .owner_res = try parseOwnerResPayload(frame.payload) };
        },
    };
}

pub fn writeStdinBytes(fd: c_int, bytes: []const u8) !void {
    return writeFrameParts(fd, .stdin_bytes, &.{bytes});
}

pub fn writeStdoutBytes(fd: c_int, bytes: []const u8) !void {
    return writeFrameParts(fd, .stdout_bytes, &.{bytes});
}

test "wire2 raw stdout bytes roundtrip" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    try writeStdoutBytes(fds[1], "hello");

    var msg = try readMessage(std.testing.allocator, fds[0], 1024);
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .stdout_bytes => |bytes| try std.testing.expectEqualStrings("hello", bytes),
        else => return error.TestUnexpectedResult,
    }
}

test "wire2 control attach roundtrip" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    try writeMessage(
        std.testing.allocator,
        fds[1],
        .{ .control_req = .{ .attach = .takeover } },
    );

    var msg = try readMessage(std.testing.allocator, fds[0], 1024);
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .control_req => |req| switch (req) {
            .attach => |mode| try std.testing.expect(mode == .takeover),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "wire2 owner req attach path roundtrip" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    var msg_out = Message{
        .owner_req = .{
            .request_id = 42,
            .action = .{ .attach = try std.testing.allocator.dupe(u8, "/tmp/next.sock") },
        },
    };
    defer msg_out.deinit(std.testing.allocator);

    try writeMessage(std.testing.allocator, fds[1], msg_out);

    var msg = try readMessage(std.testing.allocator, fds[0], 4096);
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .owner_req => |req| {
            try std.testing.expectEqual(@as(u32, 42), req.request_id);
            switch (req.action) {
                .attach => |path| try std.testing.expectEqualStrings("/tmp/next.sock", path),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "wire2 control exit signal text roundtrip" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    var msg_out = Message{
        .control_res = .{
            .exit = .{ .signal_text = try std.testing.allocator.dupe(u8, "SEGV") },
        },
    };
    defer msg_out.deinit(std.testing.allocator);

    try writeMessage(std.testing.allocator, fds[1], msg_out);

    var msg = try readMessage(std.testing.allocator, fds[0], 4096);
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .control_res => |res| switch (res) {
            .exit => |exit| switch (exit) {
                .signal_text => |text| try std.testing.expectEqualStrings("SEGV", text),
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "wire2 owner error response roundtrip" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    try writeMessage(
        std.testing.allocator,
        fds[1],
        .{
            .owner_res = .{
                .request_id = 7,
                .ok = false,
                .code = .owner_busy,
            },
        },
    );

    var msg = try readMessage(std.testing.allocator, fds[0], 1024);
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .owner_res => |res| {
            try std.testing.expectEqual(@as(u32, 7), res.request_id);
            try std.testing.expect(!res.ok);
            try std.testing.expectEqual(core.ErrorCode.owner_busy, res.code.?);
        },
        else => return error.TestUnexpectedResult,
    }
}
