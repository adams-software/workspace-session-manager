const std = @import("std");
const protocol = @import("protocol");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("poll.h");
});

pub const Error = error{
    ConnectFailed,
    AttachRejected,
    IoError,
    ProtocolError,
    UnexpectedEof,
    OutOfMemory,
};

pub const AttachMode = enum {
    exclusive,
    takeover,
};

pub const RemoteStatus = struct {
    status: []const u8,
};

pub const ExitStatus = struct {
    code: ?i32 = null,
    signal: ?[]const u8 = null,
};

pub const SessionClient = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !SessionClient {
        return .{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_path),
        };
    }

    pub fn deinit(self: *SessionClient) void {
        self.allocator.free(self.socket_path);
    }

    pub fn status(self: *SessionClient) !RemoteStatus {
        var res = try rpcCall(self.allocator, self.socket_path, .{ .op = "status" });
        defer protocol.freeControlRes(self.allocator, &res);
        if (!res.ok) return Error.ProtocolError;
        return .{ .status = try self.allocator.dupe(u8, res.value.?.status orelse "unknown") };
    }

    pub fn wait(self: *SessionClient) !ExitStatus {
        var res = try rpcCall(self.allocator, self.socket_path, .{ .op = "wait" });
        defer protocol.freeControlRes(self.allocator, &res);
        if (!res.ok) return Error.ProtocolError;
        return .{ .code = if (res.value) |v| v.code else null, .signal = if (res.value) |v| if (v.signal) |s| try self.allocator.dupe(u8, s) else null else null };
    }

    pub fn terminate(self: *SessionClient, signal: ?[]const u8) !void {
        var res = try rpcCall(self.allocator, self.socket_path, .{ .op = "terminate", .signal = signal });
        defer protocol.freeControlRes(self.allocator, &res);
        if (!res.ok) return Error.ProtocolError;
    }

    pub fn attach(self: *SessionClient, mode: AttachMode) !SessionAttachment {
        const fd = try connectUnix(self.socket_path);
        errdefer _ = c.close(fd);

        const mode_str = switch (mode) {
            .exclusive => "exclusive",
            .takeover => "takeover",
        };
        const req = try protocol.encodeControlReq(self.allocator, .{ .op = "attach", .mode = mode_str });
        defer self.allocator.free(req);
        try protocol.writeFrame(fd, req);

        const res_bytes = try protocol.readFrame(self.allocator, fd, 64 * 1024);
        defer self.allocator.free(res_bytes);
        var res = try protocol.parseControlRes(self.allocator, res_bytes);
        defer protocol.freeControlRes(self.allocator, &res);
        if (!res.ok) return Error.AttachRejected;

        return .{ .allocator = self.allocator, .fd = fd };
    }
};

pub const SessionAttachment = struct {
    allocator: std.mem.Allocator,
    fd: c_int,

    pub fn close(self: *SessionAttachment) void {
        _ = c.close(self.fd);
    }

    pub fn readDataFrame(self: *SessionAttachment) ![]u8 {
        const frame = try self.readFrameOwned();
        errdefer self.allocator.free(frame);
        var msg = try protocol.parseDataMsg(self.allocator, frame);
        defer protocol.freeDataMsg(self.allocator, &msg);
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(msg.bytes_b64);
        const decoded = try self.allocator.alloc(u8, decoded_len);
        errdefer self.allocator.free(decoded);
        try std.base64.standard.Decoder.decode(decoded, msg.bytes_b64);
        self.allocator.free(frame);
        return decoded;
    }

    pub fn write(self: *SessionAttachment, data: []const u8) !void {
        const enc_len = std.base64.standard.Encoder.calcSize(data.len);
        const b64 = try self.allocator.alloc(u8, enc_len);
        defer self.allocator.free(b64);
        _ = std.base64.standard.Encoder.encode(b64, data);
        const payload = try protocol.encodeDataMsg(self.allocator, .{ .stream = "stdin", .bytes_b64 = b64 });
        defer self.allocator.free(payload);
        try protocol.writeFrame(self.fd, payload);
    }

    pub fn resize(self: *SessionAttachment, cols: u16, rows: u16) !void {
        const req = try protocol.encodeControlReq(self.allocator, .{ .op = "resize", .cols = cols, .rows = rows });
        defer self.allocator.free(req);
        try protocol.writeFrame(self.fd, req);
        const res_bytes = try protocol.readFrame(self.allocator, self.fd, 64 * 1024);
        defer self.allocator.free(res_bytes);
        var res = try protocol.parseControlRes(self.allocator, res_bytes);
        defer protocol.freeControlRes(self.allocator, &res);
        if (!res.ok) return Error.ProtocolError;
    }

    pub fn detach(self: *SessionAttachment) !void {
        const req = try protocol.encodeControlReq(self.allocator, .{ .op = "detach" });
        defer self.allocator.free(req);
        try protocol.writeFrame(self.fd, req);
        const res_bytes = try protocol.readFrame(self.allocator, self.fd, 64 * 1024);
        defer self.allocator.free(res_bytes);
        var res = try protocol.parseControlRes(self.allocator, res_bytes);
        defer protocol.freeControlRes(self.allocator, &res);
        if (!res.ok) return Error.ProtocolError;
    }

    pub fn readFrameOwned(self: *SessionAttachment) ![]u8 {
        return try protocol.readFrame(self.allocator, self.fd, 256 * 1024);
    }
};

pub fn connectUnix(path: []const u8) Error!c_int {
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.ConnectFailed;

    if (c.connect(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) {
        _ = c.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

pub fn rpcCall(allocator: std.mem.Allocator, path: []const u8, req_msg: protocol.ControlReq) Error!protocol.ControlRes {
    const fd = try connectUnix(path);
    defer _ = c.close(fd);

    const req = protocol.encodeControlReq(allocator, req_msg) catch return error.ProtocolError;
    defer allocator.free(req);
    protocol.writeFrame(fd, req) catch return error.IoError;

    const res_bytes = protocol.readFrame(allocator, fd, 64 * 1024) catch |e| switch (e) {
        error.UnexpectedEof => return error.UnexpectedEof,
        else => return error.ProtocolError,
    };
    defer allocator.free(res_bytes);

    return protocol.parseControlRes(allocator, res_bytes) catch return error.ProtocolError;
}

