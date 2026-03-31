const std = @import("std");
const host = @import("host");
const protocol = @import("protocol");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

pub const Error = error{
    InvalidArgs,
    InvalidState,
    BindFailed,
    ListenFailed,
    ProtocolError,
    IoError,
    OutOfMemory,
    Unsupported,
    PathTooLong,
    AlreadyExists,
    PermissionDenied,
} || host.Error;

pub const ServerState = enum {
    created,
    listening,
    stopped,
};

pub const ConnectionKind = enum {
    control,
    attached_owner,
};

pub const Connection = struct {
    fd: c_int,
    kind: ConnectionKind,
};

pub const PendingLane = struct {
    requester_fd: c_int,
    lane_id: []u8,
    lane_kind: []u8,
    seq: u32,
};

pub const CoordinatorState = struct {
    owner_fd: ?c_int = null,
    shutting_down: bool = false,
};

pub const SessionServer = struct {
    allocator: std.mem.Allocator,
    session_host: *host.SessionHost,
    state: ServerState,
    listener_fd: ?c_int,
    socket_path: ?[]u8,
    coordinator: CoordinatorState,
    pending_lane: ?PendingLane,

    pub fn init(allocator: std.mem.Allocator, session_host: *host.SessionHost) SessionServer {
        return .{
            .allocator = allocator,
            .session_host = session_host,
            .state = .created,
            .listener_fd = null,
            .socket_path = null,
            .coordinator = .{},
            .pending_lane = null,
        };
    }

    pub fn deinit(self: *SessionServer) void {
        if (self.pending_lane) |pl| {
            self.allocator.free(pl.lane_id);
            self.allocator.free(pl.lane_kind);
            self.pending_lane = null;
        }
        if (self.coordinator.owner_fd) |fd| {
            _ = c.close(fd);
            self.coordinator.owner_fd = null;
        }
        if (self.listener_fd) |fd| {
            _ = c.close(fd);
            self.listener_fd = null;
        }
        if (self.socket_path) |path| {
            unlinkBestEffort(path);
            self.allocator.free(path);
            self.socket_path = null;
        }
    }

    fn validateSocketPath(path: []const u8) Error!void {
        if (path.len == 0) return Error.InvalidArgs;
        if (path.len >= 108) return Error.PathTooLong;
    }

    fn unlinkBestEffort(path: []const u8) void {
        var buf: [108:0]u8 = [_:0]u8{0} ** 108;
        if (path.len >= 108) return;
        std.mem.copyForwards(u8, buf[0..path.len], path);
        _ = c.unlink(buf[0..path.len :0].ptr);
    }

    fn isStaleSocket(path: []const u8) Error!bool {
        var addr: c.struct_sockaddr_un = undefined;
        @memset(std.mem.asBytes(&addr), 0);
        addr.sun_family = c.AF_UNIX;
        std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
        addr.sun_path[path.len] = 0;

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return Error.IoError;
        defer _ = c.close(fd);

        const rc = c.connect(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un)));
        if (rc == 0) return false;

        const e = std.c.errno(-1);
        if (e == .CONNREFUSED or e == .NOENT) return true;
        if (e == .ACCES) return Error.PermissionDenied;
        return false;
    }

    fn createListener(path: []const u8) Error!c_int {
        var addr: c.struct_sockaddr_un = undefined;
        @memset(std.mem.asBytes(&addr), 0);
        addr.sun_family = c.AF_UNIX;
        std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
        addr.sun_path[path.len] = 0;

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return Error.IoError;

        if (try isStaleSocket(path)) unlinkBestEffort(path);

        if (c.bind(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) {
            const e = std.c.errno(-1);
            _ = c.close(fd);
            return switch (e) {
                .ADDRINUSE => Error.AlreadyExists,
                .ACCES => Error.PermissionDenied,
                else => Error.BindFailed,
            };
        }

        if (c.listen(fd, 16) != 0) {
            const e = std.c.errno(-1);
            _ = c.close(fd);
            unlinkBestEffort(path);
            return switch (e) {
                .ACCES => Error.PermissionDenied,
                else => Error.ListenFailed,
            };
        }

        return fd;
    }

    fn writeControlRes(allocator: std.mem.Allocator, client_fd: c_int, res: protocol.ControlRes) Error!void {
        const bytes = protocol.encodeControlRes(allocator, res) catch return Error.ProtocolError;
        defer allocator.free(bytes);
        protocol.writeFrame(client_fd, bytes) catch return Error.IoError;
    }

    fn writeData(allocator: std.mem.Allocator, client_fd: c_int, bytes_raw: []const u8) Error!void {
        const enc_len = std.base64.standard.Encoder.calcSize(bytes_raw.len);
        const b64 = allocator.alloc(u8, enc_len) catch return Error.OutOfMemory;
        defer allocator.free(b64);
        _ = std.base64.standard.Encoder.encode(b64, bytes_raw);

        const payload = protocol.encodeDataMsg(allocator, .{ .stream = "stdout", .bytes_b64 = b64 }) catch return Error.ProtocolError;
        defer allocator.free(payload);
        protocol.writeFrame(client_fd, payload) catch return Error.IoError;
    }

    fn writeLaneRes(allocator: std.mem.Allocator, client_fd: c_int, res: protocol.LaneResMsg) Error!void {
        const bytes = protocol.encodeLaneResMsg(allocator, res) catch return Error.ProtocolError;
        defer allocator.free(bytes);
        protocol.writeFrame(client_fd, bytes) catch return Error.IoError;
    }

    fn writeLaneReq(allocator: std.mem.Allocator, client_fd: c_int, req: protocol.LaneReqMsg) Error!void {
        const bytes = protocol.encodeLaneReqMsg(allocator, req) catch return Error.ProtocolError;
        defer allocator.free(bytes);
        protocol.writeFrame(client_fd, bytes) catch return Error.IoError;
    }

    fn acceptConnection(self: *SessionServer) Error!?Connection {
        const listener_fd = self.listener_fd orelse return Error.InvalidState;
        var pfd = c.struct_pollfd{ .fd = listener_fd, .events = c.POLLIN, .revents = 0 };
        const pr = c.poll(&pfd, 1, 0);
        if (pr < 0) return Error.IoError;
        if (pr == 0) return null;

        const fd = c.accept(listener_fd, null, null);
        if (fd < 0) return Error.IoError;
        return .{ .fd = fd, .kind = .control };
    }

    fn handleControlReq(self: *SessionServer, req: protocol.ControlReq, client_fd: c_int) protocol.ControlRes {
        if (std.mem.eql(u8, req.op, "status")) {
            const st = self.session_host.getState();
            return .{ .ok = true, .value = .{ .status = @tagName(st) } };
        }

        if (std.mem.eql(u8, req.op, "terminate")) {
            self.session_host.terminate(req.signal) catch |e| {
                return .{ .ok = false, .err = .{ .code = @errorName(e) } };
            };
            return .{ .ok = true, .value = .{} };
        }

        if (std.mem.eql(u8, req.op, "wait")) {
            const st = self.session_host.wait() catch |e| {
                return .{ .ok = false, .err = .{ .code = @errorName(e) } };
            };
            return .{ .ok = true, .value = .{ .code = st.code, .signal = st.signal } };
        }

        if (std.mem.eql(u8, req.op, "attach")) {
            const mode = req.mode orelse "exclusive";
            if (self.coordinator.owner_fd != null and std.mem.eql(u8, mode, "exclusive")) {
                return .{ .ok = false, .err = .{ .code = "attach_conflict" } };
            }
            if (self.coordinator.owner_fd != null and std.mem.eql(u8, mode, "takeover")) {
                const old_fd = self.coordinator.owner_fd.?;
                _ = c.shutdown(old_fd, c.SHUT_RDWR);
            }
            self.coordinator.owner_fd = client_fd;
            return .{ .ok = true, .value = .{} };
        }

        if (std.mem.eql(u8, req.op, "detach")) {
            if (self.coordinator.owner_fd == null or self.coordinator.owner_fd.? != client_fd) {
                return .{ .ok = false, .err = .{ .code = "permission_denied" } };
            }
            self.coordinator.owner_fd = null;
            return .{ .ok = true, .value = .{} };
        }

        if (std.mem.eql(u8, req.op, "resize")) {
            if (self.coordinator.owner_fd == null or self.coordinator.owner_fd.? != client_fd) {
                return .{ .ok = false, .err = .{ .code = "permission_denied" } };
            }
            const cols = req.cols orelse 0;
            const rows = req.rows orelse 0;
            self.session_host.resize(cols, rows) catch |e| {
                return .{ .ok = false, .err = .{ .code = @errorName(e) } };
            };
            return .{ .ok = true, .value = .{} };
        }

        if (std.mem.eql(u8, req.op, "owner_attach") or std.mem.eql(u8, req.op, "owner_detach")) {
            if (self.coordinator.owner_fd == null) {
                return .{ .ok = false, .err = .{ .code = "no_owner_client" } };
            }
            return .{ .ok = false, .err = .{ .code = "owner_control_unsupported" } };
        }

        return .{ .ok = false, .err = .{ .code = "unsupported" } };
    }

    fn handleAcceptedConnection(self: *SessionServer, conn: Connection) Error!void {
        const req_bytes = protocol.readFrame(self.allocator, conn.fd, 64 * 1024) catch {
            _ = c.close(conn.fd);
            return Error.ProtocolError;
        };
        defer self.allocator.free(req_bytes);

        const EnvType = struct { type: []const u8 };
        var parsed = std.json.parseFromSlice(EnvType, self.allocator, req_bytes, .{ .ignore_unknown_fields = true }) catch {
            _ = c.close(conn.fd);
            return Error.ProtocolError;
        };
        defer parsed.deinit();

        if (std.mem.eql(u8, parsed.value.type, "lane_req")) {
            var lane_req = protocol.parseLaneReqMsg(self.allocator, req_bytes) catch {
                _ = c.close(conn.fd);
                return Error.ProtocolError;
            };
            defer protocol.freeLaneReqMsg(self.allocator, &lane_req);

            if (std.mem.eql(u8, lane_req.lane_kind, "owner_control")) {
                if (self.coordinator.owner_fd == null) {
                    const lane_res = protocol.LaneResMsg{
                        .lane_id = lane_req.lane_id,
                        .res_type = "error",
                        .seq = lane_req.seq,
                        .error_json = "{\"code\":\"no_owner_client\"}",
                    };
                    const res_bytes = protocol.encodeLaneResMsg(self.allocator, lane_res) catch {
                        _ = c.close(conn.fd);
                        return Error.ProtocolError;
                    };
                    defer self.allocator.free(res_bytes);
                    protocol.writeFrame(conn.fd, res_bytes) catch {
                        _ = c.close(conn.fd);
                        return Error.IoError;
                    };
                    _ = c.close(conn.fd);
                    return;
                }

                if (self.pending_lane != null) {
                    const lane_res = protocol.LaneResMsg{
                        .lane_id = lane_req.lane_id,
                        .res_type = "error",
                        .seq = lane_req.seq,
                        .error_json = "{\"code\":\"lane_busy\"}",
                    };
                    const res_bytes = protocol.encodeLaneResMsg(self.allocator, lane_res) catch {
                        _ = c.close(conn.fd);
                        return Error.ProtocolError;
                    };
                    defer self.allocator.free(res_bytes);
                    protocol.writeFrame(conn.fd, res_bytes) catch {
                        _ = c.close(conn.fd);
                        return Error.IoError;
                    };
                    _ = c.close(conn.fd);
                    return;
                }

                std.debug.print("[lane] server accepted requester lane kind={s} id={s} seq={d}\n", .{ lane_req.lane_kind, lane_req.lane_id, lane_req.seq });
                self.pending_lane = .{
                    .requester_fd = conn.fd,
                    .lane_id = try self.allocator.dupe(u8, lane_req.lane_id),
                    .lane_kind = try self.allocator.dupe(u8, lane_req.lane_kind),
                    .seq = lane_req.seq,
                };

                const owner_fd = self.coordinator.owner_fd.?;
                std.debug.print("[lane] server forwarding lane to owner fd={d} id={s}\n", .{ owner_fd, lane_req.lane_id });
                try writeLaneReq(self.allocator, owner_fd, .{
                    .lane_id = lane_req.lane_id,
                    .lane_kind = lane_req.lane_kind,
                    .req_type = lane_req.req_type,
                    .seq = lane_req.seq,
                    .method = lane_req.method,
                    .args_json = lane_req.args_json,
                });
                return;
            }

            const lane_res = protocol.LaneResMsg{
                .lane_id = lane_req.lane_id,
                .res_type = "error",
                .seq = lane_req.seq,
                .error_json = "{\"code\":\"lane_unsupported\"}",
            };
            const res_bytes = protocol.encodeLaneResMsg(self.allocator, lane_res) catch {
                _ = c.close(conn.fd);
                return Error.ProtocolError;
            };
            defer self.allocator.free(res_bytes);
            protocol.writeFrame(conn.fd, res_bytes) catch {
                _ = c.close(conn.fd);
                return Error.IoError;
            };
            _ = c.close(conn.fd);
            return;
        }

        var req = protocol.parseControlReq(self.allocator, req_bytes) catch {
            _ = c.close(conn.fd);
            return Error.ProtocolError;
        };
        defer protocol.freeControlReq(self.allocator, &req);

        const res = self.handleControlReq(req, conn.fd);
        try writeControlRes(self.allocator, conn.fd, res);

        if (!(std.mem.eql(u8, req.op, "attach") and res.ok)) {
            _ = c.close(conn.fd);
        }
    }

    fn pumpOwnerIo(self: *SessionServer) Error!void {
        const owner_fd = self.coordinator.owner_fd orelse return;
        const master_fd = self.session_host.getMasterFd() orelse return;

        var pfds = [2]c.struct_pollfd{
            .{ .fd = owner_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = master_fd, .events = c.POLLIN, .revents = 0 },
        };
        const pr = c.poll(&pfds, 2, 0);
        if (pr < 0) return Error.IoError;
        if (pr == 0) return;

        if ((pfds[0].revents & c.POLLIN) != 0) {
            const frame = protocol.readFrame(self.allocator, owner_fd, 256 * 1024) catch return Error.ProtocolError;
            defer self.allocator.free(frame);

            const EnvType = struct { type: []const u8 };
            var parsed = std.json.parseFromSlice(EnvType, self.allocator, frame, .{ .ignore_unknown_fields = true }) catch return Error.ProtocolError;
            defer parsed.deinit();

            if (std.mem.eql(u8, parsed.value.type, "data")) {
                var msg = protocol.parseDataMsg(self.allocator, frame) catch return Error.ProtocolError;
                defer protocol.freeDataMsg(self.allocator, &msg);
                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(msg.bytes_b64) catch return Error.ProtocolError;
                const decoded = self.allocator.alloc(u8, decoded_len) catch return Error.OutOfMemory;
                defer self.allocator.free(decoded);
                std.base64.standard.Decoder.decode(decoded, msg.bytes_b64) catch return Error.ProtocolError;
                try self.session_host.pty.write(decoded);
            } else if (std.mem.eql(u8, parsed.value.type, "control_req")) {
                var req = protocol.parseControlReq(self.allocator, frame) catch return Error.ProtocolError;
                defer protocol.freeControlReq(self.allocator, &req);
                const res = self.handleControlReq(req, owner_fd);
                try writeControlRes(self.allocator, owner_fd, res);
                if (std.mem.eql(u8, req.op, "detach") and res.ok) {
                    _ = c.close(owner_fd);
                    self.coordinator.owner_fd = null;
                    return;
                }
            } else if (std.mem.eql(u8, parsed.value.type, "lane_res")) {
                std.debug.print("[lane] server received lane_res from owner\n", .{});
                var lane_res = protocol.parseLaneResMsg(self.allocator, frame) catch return Error.ProtocolError;
                defer protocol.freeLaneResMsg(self.allocator, &lane_res);

                if (self.pending_lane) |pl| {
                    if (std.mem.eql(u8, lane_res.lane_id, pl.lane_id)) {
                        std.debug.print("[lane] server relaying lane_res to requester fd={d} id={s}\n", .{ pl.requester_fd, pl.lane_id });
                        try writeLaneRes(self.allocator, pl.requester_fd, .{
                            .lane_id = pl.lane_id,
                            .res_type = lane_res.res_type,
                            .seq = lane_res.seq,
                            .value_json = lane_res.value_json,
                            .error_json = lane_res.error_json,
                            .meta_json = lane_res.meta_json,
                            .chunk_json = lane_res.chunk_json,
                        });
                        _ = c.close(pl.requester_fd);
                        self.allocator.free(pl.lane_id);
                        self.allocator.free(pl.lane_kind);
                        self.pending_lane = null;
                        return;
                    }
                }
                return Error.ProtocolError;
            } else {
                return Error.ProtocolError;
            }
        }

        if ((pfds[0].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            if (self.pending_lane != null and (pfds[0].revents & c.POLLIN) != 0) {
                // A pending lane response may still be readable; let the readable path win first.
            } else {
                _ = c.close(owner_fd);
                self.coordinator.owner_fd = null;
                return;
            }
        }

        if ((pfds[1].revents & c.POLLIN) != 0) {
            var buf: [4096]u8 = undefined;
            const n = c.read(master_fd, &buf, buf.len);
            if (n < 0) return Error.IoError;
            if (n == 0) {
                _ = c.close(owner_fd);
                self.coordinator.owner_fd = null;
                return;
            }
            try writeData(self.allocator, owner_fd, buf[0..@intCast(n)]);
        }

        if ((pfds[1].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            _ = c.close(owner_fd);
            self.coordinator.owner_fd = null;
            return;
        }
    }

    pub fn step(self: *SessionServer) Error!bool {
        if (self.state != .listening) return Error.InvalidState;
        if (try self.acceptConnection()) |conn| {
            try self.handleAcceptedConnection(conn);
            return true;
        }
        try self.pumpOwnerIo();
        return true;
    }

    pub fn serveControlOnce(self: *SessionServer, timeout_ms: i32) Error!bool {
        if (self.state != .listening) return Error.InvalidState;
        const listener_fd = self.listener_fd orelse return Error.InvalidState;
        var pfd = c.struct_pollfd{ .fd = listener_fd, .events = c.POLLIN, .revents = 0 };
        const pr = c.poll(&pfd, 1, timeout_ms);
        if (pr < 0) return Error.IoError;
        if (pr == 0) return false;
        return self.step();
    }

    pub fn listen(self: *SessionServer, socket_path: []const u8) Error!void {
        if (self.state != .created) return Error.InvalidState;
        try validateSocketPath(socket_path);
        const fd = try createListener(socket_path);
        errdefer _ = c.close(fd);

        self.listener_fd = fd;
        self.socket_path = try self.allocator.dupe(u8, socket_path);
        self.state = .listening;
    }

    pub fn stop(self: *SessionServer) Error!void {
        return switch (self.state) {
            .created => Error.InvalidState,
            .listening => {
                self.coordinator.shutting_down = true;
                if (self.coordinator.owner_fd) |fd| {
                    _ = c.close(fd);
                    self.coordinator.owner_fd = null;
                }
                if (self.listener_fd) |fd| {
                    _ = c.close(fd);
                    self.listener_fd = null;
                }
                if (self.socket_path) |path| {
                    unlinkBestEffort(path);
                }
                self.state = .stopped;
            },
            .stopped => {},
        };
    }

    pub fn getState(self: *const SessionServer) ServerState {
        return self.state;
    }
};

fn connectUnix(path: []const u8) !c_int {
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

test "server starts created" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer h.deinit();
    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();
    try std.testing.expectEqual(ServerState.created, s.getState());
}

test "server listen creates socket and enters listening" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer h.deinit();
    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-listen-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);

    try s.listen(path);
    try std.testing.expectEqual(ServerState.listening, s.getState());
}

test "server stop after listen enters stopped" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer h.deinit();
    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-stop-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);

    try s.listen(path);
    try s.stop();
    try std.testing.expectEqual(ServerState.stopped, s.getState());
}

test "server rejects double listen" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer h.deinit();
    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-double-listen-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);

    try s.listen(path);
    try std.testing.expectError(Error.InvalidState, s.listen(path));
}

test "server step handles status request" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-status-step-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "status" });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);

    _ = try s.step();

    const res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseControlRes(std.testing.allocator, res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res);
    try std.testing.expect(res.ok);
    try std.testing.expect(res.value != null);
    try std.testing.expect(res.value.?.status != null);
    try std.testing.expectEqualStrings("running", res.value.?.status.?);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server step handles terminate request" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 5" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-terminate-step-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "terminate", .signal = "KILL" });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);

    _ = try s.step();

    const res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseControlRes(std.testing.allocator, res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res);
    try std.testing.expect(res.ok);

    _ = try h.wait();
    try h.close();
}

test "server step attach retains single owner" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-attach-step-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "attach", .mode = "exclusive" });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);

    _ = try s.step();

    const res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseControlRes(std.testing.allocator, res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res);
    try std.testing.expect(res.ok);
    try std.testing.expect(s.coordinator.owner_fd != null);

    _ = c.shutdown(fd, c.SHUT_RDWR);
    _ = try h.wait();
    try h.close();
}

test "server step pumps PTY output to attached owner" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf hello; sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-stream-step-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "attach", .mode = "exclusive" });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);

    _ = try s.step();

    const res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseControlRes(std.testing.allocator, res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res);
    try std.testing.expect(res.ok);

    _ = c.usleep(20_000);
    _ = try s.step();

    const frame = try protocol.readFrame(std.testing.allocator, fd, 256 * 1024);
    defer std.testing.allocator.free(frame);
    var msg = try protocol.parseDataMsg(std.testing.allocator, frame);
    defer protocol.freeDataMsg(std.testing.allocator, &msg);
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(msg.bytes_b64);
    const decoded = try std.testing.allocator.alloc(u8, decoded_len);
    defer std.testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, msg.bytes_b64);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "hello") != null);

    _ = try h.wait();
    try h.close();
}

test "server step forwards owner input into PTY" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "read line; printf 'got:%s' \"$line\"; sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-input-step-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "attach", .mode = "exclusive" });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);

    _ = try s.step();

    const res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseControlRes(std.testing.allocator, res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res);
    try std.testing.expect(res.ok);

    const input = "hello from owner\n";
    const enc_len = std.base64.standard.Encoder.calcSize(input.len);
    const b64 = try std.testing.allocator.alloc(u8, enc_len);
    defer std.testing.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, input);
    const data_frame = try protocol.encodeDataMsg(std.testing.allocator, .{ .stream = "stdin", .bytes_b64 = b64 });
    defer std.testing.allocator.free(data_frame);
    try protocol.writeFrame(fd, data_frame);

    _ = c.usleep(20_000);
    _ = try s.step();
    _ = c.usleep(20_000);
    _ = try s.step();

    const frame = try protocol.readFrame(std.testing.allocator, fd, 256 * 1024);
    defer std.testing.allocator.free(frame);
    var msg = try protocol.parseDataMsg(std.testing.allocator, frame);
    defer protocol.freeDataMsg(std.testing.allocator, &msg);
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(msg.bytes_b64);
    const decoded = try std.testing.allocator.alloc(u8, decoded_len);
    defer std.testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, msg.bytes_b64);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "got:hello from owner") != null);

    _ = try h.wait();
    try h.close();
}

test "server step takeover replaces owner" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf hello; sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-takeover-step-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd1 = try connectUnix(path);
    defer _ = c.close(fd1);
    const req1 = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "attach", .mode = "exclusive" });
    defer std.testing.allocator.free(req1);
    try protocol.writeFrame(fd1, req1);
    _ = try s.step();
    const res1_bytes = try protocol.readFrame(std.testing.allocator, fd1, 64 * 1024);
    defer std.testing.allocator.free(res1_bytes);
    var res1 = try protocol.parseControlRes(std.testing.allocator, res1_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res1);
    try std.testing.expect(res1.ok);
    const owner1 = s.coordinator.owner_fd orelse return error.TestUnexpectedResult;
    try std.testing.expect(owner1 >= 0);

    const fd2 = try connectUnix(path);
    defer _ = c.close(fd2);
    const req2 = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "attach", .mode = "takeover" });
    defer std.testing.allocator.free(req2);
    try protocol.writeFrame(fd2, req2);
    _ = try s.step();
    const res2_bytes = try protocol.readFrame(std.testing.allocator, fd2, 64 * 1024);
    defer std.testing.allocator.free(res2_bytes);
    var res2 = try protocol.parseControlRes(std.testing.allocator, res2_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res2);
    try std.testing.expect(res2.ok);
    const owner2 = s.coordinator.owner_fd orelse return error.TestUnexpectedResult;
    try std.testing.expect(owner2 >= 0);
    try std.testing.expect(owner2 != owner1);

    var pfd = c.struct_pollfd{ .fd = fd1, .events = 0, .revents = 0 };
    const pr = c.poll(&pfd, 1, 1000);
    try std.testing.expect(pr > 0);
    try std.testing.expect((pfd.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0);

    _ = c.usleep(20_000);
    _ = try s.step();
    const frame2 = try protocol.readFrame(std.testing.allocator, fd2, 256 * 1024);
    defer std.testing.allocator.free(frame2);
    var msg2 = try protocol.parseDataMsg(std.testing.allocator, frame2);
    defer protocol.freeDataMsg(std.testing.allocator, &msg2);
    const decoded_len2 = try std.base64.standard.Decoder.calcSizeForSlice(msg2.bytes_b64);
    const decoded2 = try std.testing.allocator.alloc(u8, decoded_len2);
    defer std.testing.allocator.free(decoded2);
    try std.base64.standard.Decoder.decode(decoded2, msg2.bytes_b64);
    try std.testing.expect(std.mem.indexOf(u8, decoded2, "hello") != null);

    _ = try h.wait();
    try h.close();
}

test "server step detach clears owner" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-detach-step-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const attach_req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "attach", .mode = "exclusive" });
    defer std.testing.allocator.free(attach_req);
    try protocol.writeFrame(fd, attach_req);
    _ = try s.step();
    const attach_res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(attach_res_bytes);
    var attach_res = try protocol.parseControlRes(std.testing.allocator, attach_res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &attach_res);
    try std.testing.expect(attach_res.ok);
    try std.testing.expect(s.coordinator.owner_fd != null);

    const detach_req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "detach" });
    defer std.testing.allocator.free(detach_req);
    try protocol.writeFrame(fd, detach_req);
    _ = try s.step();
    const detach_res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(detach_res_bytes);
    var detach_res = try protocol.parseControlRes(std.testing.allocator, detach_res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &detach_res);
    try std.testing.expect(detach_res.ok);
    try std.testing.expect(s.coordinator.owner_fd == null);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server step owner passthrough ops fail when no owner exists" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-owner-route-no-owner-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "owner_attach", .path = "/tmp/target.msr" });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);
    _ = try s.step();

    const res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseControlRes(std.testing.allocator, res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res);
    try std.testing.expect(!res.ok);
    try std.testing.expect(res.err != null);
    try std.testing.expectEqualStrings("no_owner_client", res.err.?.code);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server step owner passthrough ops report unsupported when owner exists" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-owner-route-unsupported-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const owner_fd = try connectUnix(path);
    defer _ = c.close(owner_fd);
    const attach_req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "attach", .mode = "exclusive" });
    defer std.testing.allocator.free(attach_req);
    try protocol.writeFrame(owner_fd, attach_req);
    _ = try s.step();
    const attach_res_bytes = try protocol.readFrame(std.testing.allocator, owner_fd, 64 * 1024);
    defer std.testing.allocator.free(attach_res_bytes);
    var attach_res = try protocol.parseControlRes(std.testing.allocator, attach_res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &attach_res);
    try std.testing.expect(attach_res.ok);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "owner_detach" });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);
    _ = try s.step();

    const res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseControlRes(std.testing.allocator, res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res);
    try std.testing.expect(!res.ok);
    try std.testing.expect(res.err != null);
    try std.testing.expectEqualStrings("owner_control_unsupported", res.err.?.code);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server step owner_control lane reports no owner when absent" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-owner-control-no-owner-lane-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeLaneReqMsg(std.testing.allocator, .{
        .lane_id = "lane-1",
        .lane_kind = "owner_control",
        .req_type = "call",
        .seq = 1,
        .method = "attach",
        .args_json = "{\"path\":\"/tmp/target.msr\"}",
    });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);

    _ = try s.step();

    const res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseLaneResMsg(std.testing.allocator, res_bytes);
    defer protocol.freeLaneResMsg(std.testing.allocator, &res);
    try std.testing.expectEqualStrings("lane-1", res.lane_id);
    try std.testing.expectEqualStrings("error", res.res_type);
    try std.testing.expect(res.error_json != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_json.?, "no_owner_client") != null);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server step owner_control lane detach succeeds when owner exists" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-owner-control-unsupported-lane-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const owner_fd = try connectUnix(path);
    defer _ = c.close(owner_fd);
    const attach_req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "attach", .mode = "exclusive" });
    defer std.testing.allocator.free(attach_req);
    try protocol.writeFrame(owner_fd, attach_req);
    _ = try s.step();
    const attach_res_bytes = try protocol.readFrame(std.testing.allocator, owner_fd, 64 * 1024);
    defer std.testing.allocator.free(attach_res_bytes);
    var attach_res = try protocol.parseControlRes(std.testing.allocator, attach_res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &attach_res);
    try std.testing.expect(attach_res.ok);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeLaneReqMsg(std.testing.allocator, .{
        .lane_id = "lane-2",
        .lane_kind = "owner_control",
        .req_type = "call",
        .seq = 1,
        .method = "detach",
    });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);

    _ = try s.step();

    const res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseLaneResMsg(std.testing.allocator, res_bytes);
    defer protocol.freeLaneResMsg(std.testing.allocator, &res);
    try std.testing.expectEqualStrings("lane-2", res.lane_id);
    try std.testing.expectEqualStrings("return", res.res_type);
    try std.testing.expect(res.value_json != null);
    try std.testing.expectEqualStrings("{}", res.value_json.?);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server step rejects unsupported lane request cleanly" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-lane-unsupported-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeLaneReqMsg(std.testing.allocator, .{
        .lane_id = "lane-1",
        .lane_kind = "bogus_lane",
        .req_type = "call",
        .seq = 1,
        .method = "attach",
        .args_json = "{\"path\":\"/tmp/target.msr\"}",
    });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);

    _ = try s.step();

    const res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseLaneResMsg(std.testing.allocator, res_bytes);
    defer protocol.freeLaneResMsg(std.testing.allocator, &res);
    try std.testing.expectEqualStrings("lane-1", res.lane_id);
    try std.testing.expectEqualStrings("error", res.res_type);
    try std.testing.expectEqual(@as(u32, 1), res.seq);
    try std.testing.expect(res.error_json != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_json.?, "lane_unsupported") != null);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server step resize is owner-only" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" }, .cols = 80, .rows = 24 });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-resize-owner-step-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd1 = try connectUnix(path);
    defer _ = c.close(fd1);
    const resize_req1 = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "resize", .cols = 100, .rows = 30 });
    defer std.testing.allocator.free(resize_req1);
    try protocol.writeFrame(fd1, resize_req1);
    _ = try s.step();
    const resize_res1_bytes = try protocol.readFrame(std.testing.allocator, fd1, 64 * 1024);
    defer std.testing.allocator.free(resize_res1_bytes);
    var resize_res1 = try protocol.parseControlRes(std.testing.allocator, resize_res1_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &resize_res1);
    try std.testing.expect(!resize_res1.ok);
    try std.testing.expect(resize_res1.err != null);
    try std.testing.expectEqualStrings("permission_denied", resize_res1.err.?.code);

    const fd2 = try connectUnix(path);
    defer _ = c.close(fd2);
    const attach_req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "attach", .mode = "exclusive" });
    defer std.testing.allocator.free(attach_req);
    try protocol.writeFrame(fd2, attach_req);
    _ = try s.step();
    const attach_res_bytes = try protocol.readFrame(std.testing.allocator, fd2, 64 * 1024);
    defer std.testing.allocator.free(attach_res_bytes);
    var attach_res = try protocol.parseControlRes(std.testing.allocator, attach_res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &attach_res);
    try std.testing.expect(attach_res.ok);

    const resize_req2 = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "resize", .cols = 100, .rows = 30 });
    defer std.testing.allocator.free(resize_req2);
    try protocol.writeFrame(fd2, resize_req2);
    _ = try s.step();
    const resize_res2_bytes = try protocol.readFrame(std.testing.allocator, fd2, 64 * 1024);
    defer std.testing.allocator.free(resize_res2_bytes);
    var resize_res2 = try protocol.parseControlRes(std.testing.allocator, resize_res2_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &resize_res2);
    try std.testing.expect(resize_res2.ok);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}
