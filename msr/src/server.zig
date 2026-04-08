const std = @import("std");
const host = @import("host");
const protocol = @import("protocol");
const server_model = @import("server_model");
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

pub const Connection = struct {
    fd: c_int,
};


pub const SessionServer = struct {
    allocator: std.mem.Allocator,
    session_host: *host.SessionHost,
    state: ServerState,
    listener_fd: ?c_int,
    socket_path: ?[]u8,
    model: server_model.Model,
    shutting_down: bool,

    pub fn init(allocator: std.mem.Allocator, session_host: *host.SessionHost) SessionServer {
        return .{
            .allocator = allocator,
            .session_host = session_host,
            .state = .created,
            .listener_fd = null,
            .socket_path = null,
            .model = .{},
            .shutting_down = false,
        };
    }

    pub fn deinit(self: *SessionServer) void {
        self.dropOwner(null);
        self.model.deinit(self.allocator);
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

    fn ownerFd(self: *const SessionServer) ?c_int {
        return switch (self.model.owner) {
            .none => null,
            .attached_unready => |owner| @intCast(owner.fd),
            .attached_ready => |owner| @intCast(owner.fd),
        };
    }

    pub fn hasOwner(self: *const SessionServer) bool {
        return self.ownerFd() != null;
    }

    fn ownerPending(self: *const SessionServer) ?server_model.ForwardedOwnerReq {
        return switch (self.model.owner) {
            .none => null,
            .attached_unready => null,
            .attached_ready => |owner| owner.pending,
        };
    }

    fn writeControlRes(allocator: std.mem.Allocator, client_fd: c_int, res: protocol.ControlRes) Error!void {
        const bytes = protocol.encodeControlRes(allocator, res) catch return Error.ProtocolError;
        defer allocator.free(bytes);
        protocol.writeFrame(client_fd, bytes) catch return Error.IoError;
    }

    fn writeOwnerControlReq(allocator: std.mem.Allocator, client_fd: c_int, req: protocol.OwnerControlReq) Error!void {
        const bytes = protocol.encodeOwnerControlReq(allocator, req) catch return Error.ProtocolError;
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

    fn applyModelAction(self: *SessionServer, action: server_model.Action) Error!void {
        switch (action) {
            .send_control_res => |payload| try writeControlRes(self.allocator, @intCast(payload.fd), payload.res),
            .send_owner_control_req => |payload| try writeOwnerControlReq(self.allocator, @intCast(payload.fd), payload.req),
            .close_fd => |fd| {
                _ = c.close(@intCast(fd));
            },
            .install_owner => {},
            .owner_ready => {},
            .session_size_changed => |size| {
                self.session_host.applySessionSize(.{ .cols = size.cols, .rows = size.rows }) catch |e| switch (e) {
                    host.Error.InvalidArgs, host.Error.InvalidState, host.Error.NotStarted, host.Error.Closed => {},
                    else => return Error.ProtocolError,
                };
            },
            .clear_owner => {},
        }
    }

    fn applyModelActions(self: *SessionServer, actions: *server_model.ActionList) Error!void {
        for (actions.items) |*action| {
            try self.applyModelAction(action.*);
        }
    }

    fn acceptConnection(self: *SessionServer) Error!?Connection {
        const listener_fd = self.listener_fd orelse return Error.InvalidState;
        var pfd = c.struct_pollfd{ .fd = listener_fd, .events = c.POLLIN, .revents = 0 };
        const pr = c.poll(&pfd, 1, 0);
        if (pr < 0) return Error.IoError;
        if (pr == 0) return null;

        const fd = c.accept(listener_fd, null, null);
        if (fd < 0) return Error.IoError;
        return .{ .fd = fd };
    }

    fn beginOwnerForward(self: *SessionServer, client_fd: c_int, req: protocol.ControlReq) Error!bool {
        var actions = server_model.ActionList.init(self.allocator);
        defer server_model.deinitActionList(self.allocator, &actions);

        try server_model.handleOwnerForward(&self.model, self.allocator, client_fd, req.request_id, req.action, &actions);
        self.applyModelActions(&actions) catch {
            self.dropOwner("owner_disconnected");
            return true;
        };

        for (actions.items) |action| {
            switch (action) {
                .send_control_res => |payload| if (payload.fd == client_fd) return true,
                .close_fd => |fd| if (fd == client_fd) return true,
                else => {},
            }
        }
        return false;
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

        if (std.mem.eql(u8, req.op, "detach")) {
            const owner_fd = self.ownerFd() orelse return .{ .ok = false, .err = .{ .code = "permission_denied" } };
            if (owner_fd != client_fd) {
                return .{ .ok = false, .err = .{ .code = "permission_denied" } };
            }
            self.model.owner = .none;
            return .{ .ok = true, .value = .{} };
        }

        if (std.mem.eql(u8, req.op, "resize")) {
            const owner_fd = self.ownerFd() orelse return .{ .ok = false, .err = .{ .code = "permission_denied" } };
            if (owner_fd != client_fd) {
                return .{ .ok = false, .err = .{ .code = "permission_denied" } };
            }
            const cols = req.cols orelse 0;
            const rows = req.rows orelse 0;
            self.session_host.resize(cols, rows) catch |e| {
                return .{ .ok = false, .err = .{ .code = @errorName(e) } };
            };
            return .{ .ok = true, .value = .{} };
        }

        if (std.mem.eql(u8, req.op, "owner_forward")) {
            _ = self.beginOwnerForward(client_fd, req) catch |e| return .{ .ok = false, .err = .{ .code = @errorName(e) } };
            return .{ .ok = true, .value = .{} };
        }

        return .{ .ok = false, .err = .{ .code = "unsupported" } };
    }

    fn handleAcceptedConnection(self: *SessionServer, conn: Connection) Error!void {
        const req_bytes = protocol.readFrame(self.allocator, conn.fd, 64 * 1024) catch {
            _ = c.close(conn.fd);
            return Error.ProtocolError;
        };
        defer self.allocator.free(req_bytes);

        var msg = protocol.parseMessage(self.allocator, req_bytes) catch {
            _ = c.close(conn.fd);
            return Error.ProtocolError;
        };
        defer msg.deinit(self.allocator);

        switch (msg) {
            .control_req => |req| {
                if (std.mem.eql(u8, req.op, "attach")) {
                    const mode = req.mode orelse "exclusive";
                    var actions = server_model.ActionList.init(self.allocator);
                    defer server_model.deinitActionList(self.allocator, &actions);

                    server_model.handleAttach(&self.model, self.allocator, conn.fd, mode, &actions) catch {
                        try writeControlRes(self.allocator, conn.fd, .{ .ok = false, .err = .{ .code = "invalid_args" } });
                        _ = c.close(conn.fd);
                        return;
                    };

                    try self.applyModelActions(&actions);
                    return;
                }

                if (std.mem.eql(u8, req.op, "owner_forward")) {
                    const closed = try self.beginOwnerForward(conn.fd, req);
                    if (!closed) return;
                    return;
                }

                const res = self.handleControlReq(req, conn.fd);
                try writeControlRes(self.allocator, conn.fd, res);

                if (!(std.mem.eql(u8, req.op, "attach") and res.ok)) {
                    _ = c.close(conn.fd);
                }
            },
            else => {
                _ = c.close(conn.fd);
                return Error.ProtocolError;
            },
        }
    }

    fn resolveOwnerControlRes(self: *SessionServer, owner_res: protocol.OwnerControlRes) Error!void {
        var actions = server_model.ActionList.init(self.allocator);
        defer server_model.deinitActionList(self.allocator, &actions);

        try server_model.handleOwnerControlRes(&self.model, self.allocator, owner_res, &actions);
        try self.applyModelActions(&actions);
    }

    fn resolveOwnerReady(self: *SessionServer) Error!void {
        var actions = server_model.ActionList.init(self.allocator);
        defer server_model.deinitActionList(self.allocator, &actions);

        try server_model.handleOwnerReady(&self.model, &actions);
        try self.applyModelActions(&actions);
    }

    fn dropOwner(self: *SessionServer, failure_code: ?[]const u8) void {
        var actions = server_model.ActionList.init(self.allocator);
        defer server_model.deinitActionList(self.allocator, &actions);

        if (failure_code) |code| {
            if (std.mem.eql(u8, code, "pty_closed")) {
                server_model.handlePtyClosed(&self.model, self.allocator, &actions) catch return;
            } else {
                server_model.handleOwnerClosed(&self.model, self.allocator, &actions) catch return;
            }
        } else {
            server_model.handleOwnerClosed(&self.model, self.allocator, &actions) catch return;
        }

        self.applyModelActions(&actions) catch return;
    }

    fn pumpPtyOutput(self: *SessionServer) Error!bool {
        const owner_fd = self.ownerFd();
        const master_fd = self.session_host.getMasterFd() orelse {
            if (owner_fd != null) self.dropOwner("pty_closed");
            return false;
        };

        var progressed = false;

        while (true) {
            var pfd = c.struct_pollfd{
                .fd = master_fd,
                .events = c.POLLIN,
                .revents = 0,
            };

            const pr = c.poll(&pfd, 1, 0);
            if (pr < 0) return Error.IoError;
            if (pr == 0) break;

            if ((pfd.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
                if (owner_fd != null) self.dropOwner("pty_closed");
                return progressed;
            }

            const drained = self.session_host.drainObservedPtyOutput() catch |e| switch (e) {
                host.Error.InvalidState, host.Error.NotStarted, host.Error.Closed => return progressed,
                host.Error.IoError => {
                    if (owner_fd != null) self.dropOwner("pty_closed");
                    return progressed;
                },
                else => return Error.IoError,
            };
            defer {
                for (drained) |chunk| self.allocator.free(chunk);
                self.allocator.free(drained);
            }

            if (drained.len == 0) break;
            progressed = true;

            if (owner_fd) |fd| {
                for (drained) |chunk| {
                    try writeData(self.allocator, fd, chunk);
                }
            }
        }

        return progressed;
    }

    fn drainReadablePtyForCheckpoint(self: *SessionServer) Error!void {
        const drained = self.session_host.drainObservedPtyOutput() catch |e| switch (e) {
            host.Error.InvalidState, host.Error.NotStarted, host.Error.Closed => return,
            host.Error.IoError => return,
            else => return Error.IoError,
        };
        defer {
            for (drained) |chunk| self.allocator.free(chunk);
            self.allocator.free(drained);
        }
    }
    fn pumpOwnerIo(self: *SessionServer) Error!bool {
        const owner_fd = self.ownerFd() orelse return false;
        var progressed = false;

        while (true) {
            var pfd = c.struct_pollfd{
                .fd = owner_fd,
                .events = c.POLLIN,
                .revents = 0,
            };

            const pr = c.poll(&pfd, 1, 0);
            if (pr < 0) return Error.IoError;
            if (pr == 0) break;

            if ((pfd.revents & c.POLLIN) != 0) {
                progressed = true;

                const frame = protocol.readFrame(self.allocator, owner_fd, 256 * 1024) catch |e| switch (e) {
                    error.UnexpectedEof => {
                        self.dropOwner(null);
                        return true;
                    },
                    else => return Error.ProtocolError,
                };
                defer self.allocator.free(frame);

                var msg = protocol.parseMessage(self.allocator, frame) catch return Error.ProtocolError;
                defer msg.deinit(self.allocator);

                switch (msg) {
                    .data => |data_msg| {
                        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_msg.bytes_b64) catch return Error.ProtocolError;
                        const decoded = self.allocator.alloc(u8, decoded_len) catch return Error.OutOfMemory;
                        defer self.allocator.free(decoded);
                        std.base64.standard.Decoder.decode(decoded, data_msg.bytes_b64) catch return Error.ProtocolError;
                        try self.session_host.pty.write(decoded);
                    },
                    .control_req => |req| {
                        const res = self.handleControlReq(req, owner_fd);
                        try writeControlRes(self.allocator, owner_fd, res);
                        if (std.mem.eql(u8, req.op, "detach") and res.ok) {
                            _ = c.close(owner_fd);
                            return true;
                        }
                    },
                    .owner_control_res => |owner_res| {
                        try self.resolveOwnerControlRes(owner_res);
                    },
                    .owner_ready => {
                        try self.resolveOwnerReady();
                    },
                    .owner_resize => |resize| {
                        self.session_host.resize(resize.cols, resize.rows) catch |e| switch (e) {
                            host.Error.InvalidArgs, host.Error.InvalidState, host.Error.NotStarted, host.Error.Closed => {},
                            else => return Error.ProtocolError,
                        };
                        self.session_host.signalWinch() catch |e| switch (e) {
                            host.Error.InvalidArgs, host.Error.InvalidState, host.Error.NotStarted, host.Error.Closed => {},
                            else => return Error.ProtocolError,
                        };
                    },
                    else => return Error.ProtocolError,
                }
            }

            if ((pfd.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
                if (self.ownerPending() != null and (pfd.revents & c.POLLIN) != 0) {
                    continue;
                }
                self.dropOwner("owner_disconnected");
                return true;
            }
        }

        return progressed;
    }


    pub fn step(self: *SessionServer) Error!bool {
        if (self.state != .listening) return Error.InvalidState;

        var progressed = false;

        if (try self.acceptConnection()) |conn| {
            try self.handleAcceptedConnection(conn);
            progressed = true;
        }

        if (try self.pumpOwnerIo()) progressed = true;
        if (try self.pumpPtyOutput()) progressed = true;

        return progressed;
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
                self.shutting_down = true;
                self.dropOwner("server_stopped");
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
    try std.testing.expect(s.ownerFd() != null);

    _ = c.shutdown(fd, c.SHUT_RDWR);
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
    try std.testing.expect(s.ownerFd() != null);

    const detach_req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "detach" });
    defer std.testing.allocator.free(detach_req);
    try protocol.writeFrame(fd, detach_req);
    _ = try s.step();
    const detach_res_bytes = try protocol.readFrame(std.testing.allocator, fd, 64 * 1024);
    defer std.testing.allocator.free(detach_res_bytes);
    var detach_res = try protocol.parseControlRes(std.testing.allocator, detach_res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &detach_res);
    try std.testing.expect(detach_res.ok);
    try std.testing.expect(s.ownerFd() == null);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server step owner_forward reports no owner when absent" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-owner-forward-no-owner-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "owner_forward", .request_id = 1, .action = .{ .op = "detach" } });
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

test "server step owner_forward sends owner_control_req to attached owner" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-owner-forward-to-owner-test.sock";
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

    const ready_bytes = try protocol.encodeOwnerReady(std.testing.allocator);
    defer std.testing.allocator.free(ready_bytes);
    try protocol.writeFrame(owner_fd, ready_bytes);
    _ = try s.step();

    const requester_fd = try connectUnix(path);
    defer _ = c.close(requester_fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "owner_forward", .request_id = 5, .action = .{ .op = "detach" } });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(requester_fd, req);

    _ = try s.step();

    const owner_frame = try protocol.readFrame(std.testing.allocator, owner_fd, 64 * 1024);
    defer std.testing.allocator.free(owner_frame);
    var owner_req = try protocol.parseOwnerControlReq(std.testing.allocator, owner_frame);
    defer protocol.freeOwnerControlReq(std.testing.allocator, &owner_req);
    try std.testing.expectEqual(@as(u32, 5), owner_req.request_id);
    try std.testing.expectEqualStrings("detach", owner_req.action.op);

    const owner_res_bytes = try protocol.encodeOwnerControlRes(std.testing.allocator, .{ .request_id = 5, .ok = true });
    defer std.testing.allocator.free(owner_res_bytes);
    try protocol.writeFrame(owner_fd, owner_res_bytes);

    _ = try s.step();

    const requester_res_bytes = try protocol.readFrame(std.testing.allocator, requester_fd, 64 * 1024);
    defer std.testing.allocator.free(requester_res_bytes);
    var requester_res = try protocol.parseControlRes(std.testing.allocator, requester_res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &requester_res);
    try std.testing.expect(requester_res.ok);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server step owner_forward reports owner_busy when pending exists" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-owner-forward-busy-test.sock";
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

    const ready_bytes = try protocol.encodeOwnerReady(std.testing.allocator);
    defer std.testing.allocator.free(ready_bytes);
    try protocol.writeFrame(owner_fd, ready_bytes);
    _ = try s.step();

    const requester1_fd = try connectUnix(path);
    defer _ = c.close(requester1_fd);
    const req1 = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "owner_forward", .request_id = 1, .action = .{ .op = "detach" } });
    defer std.testing.allocator.free(req1);
    try protocol.writeFrame(requester1_fd, req1);
    _ = try s.step();

    const owner_frame = try protocol.readFrame(std.testing.allocator, owner_fd, 64 * 1024);
    defer std.testing.allocator.free(owner_frame);
    var owner_req = try protocol.parseOwnerControlReq(std.testing.allocator, owner_frame);
    defer protocol.freeOwnerControlReq(std.testing.allocator, &owner_req);
    try std.testing.expectEqual(@as(u32, 1), owner_req.request_id);

    const requester2_fd = try connectUnix(path);
    defer _ = c.close(requester2_fd);
    const req2 = try protocol.encodeControlReq(std.testing.allocator, .{ .op = "owner_forward", .request_id = 2, .action = .{ .op = "detach" } });
    defer std.testing.allocator.free(req2);
    try protocol.writeFrame(requester2_fd, req2);
    _ = try s.step();

    const requester2_res_bytes = try protocol.readFrame(std.testing.allocator, requester2_fd, 64 * 1024);
    defer std.testing.allocator.free(requester2_res_bytes);
    var requester2_res = try protocol.parseControlRes(std.testing.allocator, requester2_res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &requester2_res);
    try std.testing.expect(!requester2_res.ok);
    try std.testing.expect(requester2_res.err != null);
    try std.testing.expectEqualStrings("owner_busy", requester2_res.err.?.code);

    const owner_res_bytes = try protocol.encodeOwnerControlRes(std.testing.allocator, .{ .request_id = 1, .ok = true });
    defer std.testing.allocator.free(owner_res_bytes);
    try protocol.writeFrame(owner_fd, owner_res_bytes);
    _ = try s.step();

    const requester1_res_bytes = try protocol.readFrame(std.testing.allocator, requester1_fd, 64 * 1024);
    defer std.testing.allocator.free(requester1_res_bytes);
    var requester1_res = try protocol.parseControlRes(std.testing.allocator, requester1_res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &requester1_res);
    try std.testing.expect(requester1_res.ok);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}


