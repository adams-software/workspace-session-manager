const std = @import("std");
const core = @import("session_core");
const wire = @import("session_wire");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("poll.h");
});

pub const Error = error{
    ConnectFailed,
    PathTooLong,
    AttachRejected,
    IoError,
    ProtocolError,
    UnexpectedEof,
    Timeout,
    OutOfMemory,

    InvalidArgs,
    AttachConflict,
    NoOwner,
    OwnerNotReady,
    OwnerBusy,
    OwnerDisconnected,
    OwnerReplaced,
    PtyClosed,
};

pub const AttachMode = core.AttachMode;
pub const Signal = wire.Signal;
pub const SessionStatus = wire.SessionStatus;
pub const ExitStatus = wire.ExitStatus;
pub const ForwardAction = core.ForwardAction;

pub const DEFAULT_RPC_TIMEOUT_MS: i32 = 3000;
pub const DEFAULT_CONTROL_FRAME_MAX: usize = 64 * 1024;
pub const DEFAULT_STREAM_FRAME_MAX: usize = 256 * 1024;

pub fn statusText(status: SessionStatus) []const u8 {
    return switch (status) {
        .starting => "starting",
        .running => "running",
        .exited => "exited",
        .idle => "idle",
        .closed => "closed",
    };
}

pub fn signalText(sig: Signal) []const u8 {
    return switch (sig) {
        .term => "TERM",
        .int => "INT",
        .kill => "KILL",
    };
}

fn mapWireError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,

        wire.Error.ReadFailed,
        wire.Error.WriteFailed,
        => Error.IoError,

        wire.Error.UnexpectedEof => Error.UnexpectedEof,

        wire.Error.BadFrame,
        wire.Error.BadMessageType,
        wire.Error.FrameTooLarge,
        wire.Error.InvalidEnumValue,
        wire.Error.InvalidPayload,
        => Error.ProtocolError,

        else => Error.ProtocolError,
    };
}

fn mapCodeToError(code: core.ErrorCode) Error {
    return switch (code) {
        .invalid_args => Error.InvalidArgs,
        .attach_conflict => Error.AttachConflict,
        .no_owner => Error.NoOwner,
        .owner_not_ready => Error.OwnerNotReady,
        .owner_busy => Error.OwnerBusy,
        .owner_disconnected => Error.OwnerDisconnected,
        .owner_replaced => Error.OwnerReplaced,
        .pty_closed => Error.PtyClosed,
    };
}

fn waitReadable(fd: c_int, timeout_ms: i32) Error!void {
    var pfd = c.struct_pollfd{
        .fd = fd,
        .events = c.POLLIN,
        .revents = 0,
    };

    while (true) {
        const pr = c.poll(&pfd, 1, timeout_ms);
        if (pr > 0) break;
        if (pr == 0) return Error.Timeout;

        const e = std.c.errno(-1);
        if (e == .INTR) continue;
        return Error.IoError;
    }

    if ((pfd.revents & c.POLLIN) != 0) return;

    if ((pfd.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
        return Error.UnexpectedEof;
    }

    return Error.IoError;
}

pub fn connectUnix(path: []const u8) Error!c_int {
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);

    const max_path_len = addr.sun_path.len - 1;
    if (path.len == 0 or path.len > max_path_len) return Error.PathTooLong;

    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return Error.ConnectFailed;

    if (c.connect(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) {
        _ = c.close(fd);
        return Error.ConnectFailed;
    }

    return fd;
}

fn readControlResOnFd(
    allocator: std.mem.Allocator,
    fd: c_int,
    timeout_ms: i32,
) Error!wire.ControlRes {
    try waitReadable(fd, timeout_ms);

    var msg = wire.readMessage(allocator, fd, DEFAULT_CONTROL_FRAME_MAX) catch |e| {
        return mapWireError(e);
    };
    errdefer msg.deinit(allocator);

    return switch (msg) {
        .control_res => |res| res,
        else => {
            msg.deinit(allocator);
            return Error.ProtocolError;
        },
    };
}

fn rpcCall(
    allocator: std.mem.Allocator,
    path: []const u8,
    req: wire.ControlReq,
    timeout_ms: i32,
) Error!wire.ControlRes {
    const fd = try connectUnix(path);
    defer _ = c.close(fd);

    wire.writeMessage(allocator, fd, .{ .control_req = req }) catch |e| {
        return mapWireError(e);
    };

    return try readControlResOnFd(allocator, fd, timeout_ms);
}

pub const SessionClient = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,
    next_request_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !SessionClient {
        return .{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_path),
            .next_request_id = 1,
        };
    }

    pub fn deinit(self: *SessionClient) void {
        self.allocator.free(self.socket_path);
    }

    fn takeRequestId(self: *SessionClient) u32 {
        const out = self.next_request_id;
        self.next_request_id +%= 1;
        if (self.next_request_id == 0) self.next_request_id = 1;
        return out;
    }

    pub fn status(self: *SessionClient) Error!SessionStatus {
        var res = try rpcCall(self.allocator, self.socket_path, .status, DEFAULT_RPC_TIMEOUT_MS);
        defer res.deinit(self.allocator);

        return switch (res) {
            .status => |st| st,
            .ok => Error.ProtocolError,
            .exit => Error.ProtocolError,
            .err => |code| mapCodeToError(code),
        };
    }

    pub fn wait(self: *SessionClient) Error!ExitStatus {
        var res = try rpcCall(self.allocator, self.socket_path, .wait, DEFAULT_RPC_TIMEOUT_MS);
        errdefer res.deinit(self.allocator);

        return switch (res) {
            .exit => |exit| exit,
            .ok => {
                res.deinit(self.allocator);
                return Error.ProtocolError;
            },
            .status => {
                res.deinit(self.allocator);
                return Error.ProtocolError;
            },
            .err => |code| {
                res.deinit(self.allocator);
                return mapCodeToError(code);
            },
        };
    }

    pub fn terminate(self: *SessionClient, sig: Signal) Error!void {
        var res = try rpcCall(self.allocator, self.socket_path, .{ .terminate = sig }, DEFAULT_RPC_TIMEOUT_MS);
        defer res.deinit(self.allocator);

        return switch (res) {
            .ok => {},
            .err => |code| mapCodeToError(code),
            else => Error.ProtocolError,
        };
    }

    pub fn ownerForward(self: *SessionClient, action: ForwardAction) Error!void {
        try action.validate();
        const request_id = self.takeRequestId();

        var res = try rpcCall(
            self.allocator,
            self.socket_path,
            .{
                .owner_forward = .{
                    .request_id = request_id,
                    .action = action,
                },
            },
            DEFAULT_RPC_TIMEOUT_MS,
        );
        defer res.deinit(self.allocator);

        return switch (res) {
            .ok => {},
            .err => |code| mapCodeToError(code),
            else => Error.ProtocolError,
        };
    }

    pub fn requestOwnerDetach(self: *SessionClient) Error!void {
        return self.ownerForward(.detach);
    }

    pub fn requestOwnerAttach(self: *SessionClient, target_socket_path: []const u8) Error!void {
        return self.ownerForward(.{ .attach = @constCast(target_socket_path) });
    }

    pub fn attach(self: *SessionClient, mode: AttachMode) Error!SessionAttachment {
        const fd = try connectUnix(self.socket_path);
        errdefer _ = c.close(fd);

        wire.writeMessage(self.allocator, fd, .{ .control_req = .{ .attach = mode } }) catch |e| {
            return mapWireError(e);
        };

        var res = try readControlResOnFd(self.allocator, fd, DEFAULT_RPC_TIMEOUT_MS);
        defer res.deinit(self.allocator);

        switch (res) {
            .ok => {},
            .err => |code| return switch (code) {
                .attach_conflict => Error.AttachConflict,
                else => Error.AttachRejected,
            },
            else => return Error.ProtocolError,
        }

        return .{
            .allocator = self.allocator,
            .fd = fd,
        };
    }
};

pub const SessionAttachment = struct {
    allocator: std.mem.Allocator,
    fd: c_int,

    pub fn close(self: *SessionAttachment) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn readMessage(self: *SessionAttachment) Error!wire.Message {
        return wire.readMessage(self.allocator, self.fd, DEFAULT_STREAM_FRAME_MAX) catch |e| {
            return mapWireError(e);
        };
    }

    pub fn readStdout(self: *SessionAttachment) Error![]u8 {
        var msg = try self.readMessage();
        errdefer msg.deinit(self.allocator);

        return switch (msg) {
            .stdout_bytes => |bytes| bytes,
            else => {
                msg.deinit(self.allocator);
                return Error.ProtocolError;
            },
        };
    }

    pub fn readOwnerRequest(self: *SessionAttachment) Error!wire.ForwardRequest {
        var msg = try self.readMessage();
        errdefer msg.deinit(self.allocator);

        return switch (msg) {
            .owner_req => |req| req,
            else => {
                msg.deinit(self.allocator);
                return Error.ProtocolError;
            },
        };
    }

    pub fn replyOwnerRequest(self: *SessionAttachment, request_id: u32, ok: bool, code: ?core.ErrorCode) Error!void {
        wire.writeMessage(self.allocator, self.fd, .{
            .owner_res = .{
                .request_id = request_id,
                .ok = ok,
                .code = if (ok) null else (code orelse .invalid_args),
            },
        }) catch |e| {
            return mapWireError(e);
        };
    }

    pub fn sendOwnerReady(self: *SessionAttachment) Error!void {
        wire.writeMessage(self.allocator, self.fd, .owner_ready) catch |e| {
            return mapWireError(e);
        };
    }

    pub fn sendOwnerResize(self: *SessionAttachment, cols: u16, rows: u16) Error!void {
        wire.writeMessage(self.allocator, self.fd, .{
            .owner_resize = .{ .cols = cols, .rows = rows },
        }) catch |e| {
            return mapWireError(e);
        };
    }

    pub fn write(self: *SessionAttachment, data: []const u8) Error!void {
        wire.writeStdinBytes(self.fd, data) catch |e| {
            return mapWireError(e);
        };
    }

    fn controlCall(self: *SessionAttachment, req: wire.ControlReq) Error!wire.ControlRes {
        wire.writeMessage(self.allocator, self.fd, .{ .control_req = req }) catch |e| {
            return mapWireError(e);
        };
        return try readControlResOnFd(self.allocator, self.fd, DEFAULT_RPC_TIMEOUT_MS);
    }

    pub fn resize(self: *SessionAttachment, cols: u16, rows: u16) Error!void {
        var res = try self.controlCall(.{ .resize = .{ .cols = cols, .rows = rows } });
        defer res.deinit(self.allocator);

        return switch (res) {
            .ok => {},
            .err => |code| mapCodeToError(code),
            else => Error.ProtocolError,
        };
    }

    pub fn detach(self: *SessionAttachment) Error!void {
        var res = try self.controlCall(.detach);
        defer res.deinit(self.allocator);

        switch (res) {
            .ok => self.close(),
            .err => |code| return mapCodeToError(code),
            else => return Error.ProtocolError,
        }
    }
};

test "client2 attachment write emits stdin_bytes frame" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    var att = SessionAttachment{
        .allocator = std.testing.allocator,
        .fd = fds[1],
    };

    try att.write("hello");

    var msg = try wire.readMessage(std.testing.allocator, fds[0], DEFAULT_STREAM_FRAME_MAX);
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .stdin_bytes => |bytes| try std.testing.expectEqualStrings("hello", bytes),
        else => return error.TestUnexpectedResult,
    }
}

test "client2 attachment readStdout reads raw stdout bytes" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    try wire.writeStdoutBytes(fds[1], "world");

    var att = SessionAttachment{
        .allocator = std.testing.allocator,
        .fd = fds[0],
    };

    const out = try att.readStdout();
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings("world", out);
}

test "client2 replyOwnerRequest emits owner_res" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    var att = SessionAttachment{
        .allocator = std.testing.allocator,
        .fd = fds[1],
    };

    try att.replyOwnerRequest(7, false, .owner_busy);

    var msg = try wire.readMessage(std.testing.allocator, fds[0], DEFAULT_CONTROL_FRAME_MAX);
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

test "client2 statusText returns stable strings" {
    try std.testing.expectEqualStrings("running", statusText(.running));
    try std.testing.expectEqualStrings("closed", statusText(.closed));
}
