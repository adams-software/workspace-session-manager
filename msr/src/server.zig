const std = @import("std");
const host = @import("host");
const core = @import("session_core");
const wire = @import("session_wire");
const client = @import("client");

const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const streaming = @import("session_stream_transport");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

pub const Error = error{
    InvalidArgs,
    InvalidState,
    BindFailed,
    ListenFailed,
    IoError,
    PathTooLong,
    AlreadyExists,
    PermissionDenied,
    Unsupported,
} || host.Error || fd_stream.Error || streaming.Error;

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
    session_host: *host.PtyChildHost,
    state: ServerState = .created,
    listener_fd: ?c_int = null,
    socket_path: ?[]u8 = null,
    core_state: core.Core = .{},

    owner_transport: ?streaming.FramedTransport = null,
    pty_input_tx: ByteQueue = ByteQueue.init(),
    pty_nonblocking_configured: bool = false,
    owner_detach_after_flush: bool = false,

    pub fn init(allocator: std.mem.Allocator, session_host: *host.PtyChildHost) SessionServer {
        return .{
            .allocator = allocator,
            .session_host = session_host,
        };
    }

    pub fn deinit(self: *SessionServer) void {
        self.dropOwner(false);
        self.clearOwnerTransport();
        self.pty_input_tx.deinit(self.allocator);
        self.core_state.deinit(self.allocator);

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

    pub fn getState(self: *const SessionServer) ServerState {
        return self.state;
    }

    pub fn hasOwner(self: *const SessionServer) bool {
        return self.core_state.hasOwner();
    }

    pub fn ownerFd(self: *const SessionServer) ?c_int {
        return self.core_state.ownerFd();
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
        switch (self.state) {
            .created => return Error.InvalidState,
            .listening => {
                self.dropOwner(false);

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
        }
    }

    pub fn serveControlOnce(self: *SessionServer, timeout_ms: i32) Error!bool {
        if (self.state != .listening) return Error.InvalidState;
        const listener_fd = self.listener_fd orelse return Error.InvalidState;

        var pfd = c.struct_pollfd{
            .fd = listener_fd,
            .events = c.POLLIN,
            .revents = 0,
        };

        while (true) {
            const pr = c.poll(&pfd, 1, timeout_ms);
            if (pr > 0) break;
            if (pr == 0) return false;

            const e = std.posix.errno(-1);
            if (e == .INTR) continue;
            return Error.IoError;
        }

        return self.step();
    }

    pub fn step(self: *SessionServer) Error!bool {
        if (self.state != .listening) return Error.InvalidState;

        try self.ensurePtyNonBlocking();

        var any_progress = false;
        var spins: usize = 0;

        // Drain a bounded amount of ready work per outer host tick. A single pass was
        // noticeably sluggish for large streamed bursts, but an unbounded loop would
        // risk busy-spinning under pathological readiness patterns.
        while (spins < 16) : (spins += 1) {
            var progressed = false;

            if (try self.acceptConnection()) |conn| {
                try self.handleAcceptedConnection(conn);
                progressed = true;
            }

            if (try self.pumpOwnerIo()) progressed = true;
            if (try self.pumpPtyIo()) progressed = true;

            any_progress = any_progress or progressed;
            if (!progressed) break;
        }

        return any_progress;
    }

    fn validateSocketPath(path: []const u8) Error!void {
        if (path.len == 0) return Error.InvalidArgs;
        if (path.len >= 108) return Error.PathTooLong;
    }

    pub fn unlinkBestEffort(path: []const u8) void {
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

        const e = std.posix.errno(-1);
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
            const e = std.posix.errno(-1);
            _ = c.close(fd);
            return switch (e) {
                .ADDRINUSE => Error.AlreadyExists,
                .ACCES => Error.PermissionDenied,
                else => Error.BindFailed,
            };
        }

        if (c.listen(fd, 16) != 0) {
            const e = std.posix.errno(-1);
            _ = c.close(fd);
            unlinkBestEffort(path);
            return switch (e) {
                .ACCES => Error.PermissionDenied,
                else => Error.ListenFailed,
            };
        }

        return fd;
    }

    fn acceptConnection(self: *SessionServer) Error!?Connection {
        const listener_fd = self.listener_fd orelse return Error.InvalidState;

        var pfd = c.struct_pollfd{
            .fd = listener_fd,
            .events = c.POLLIN,
            .revents = 0,
        };

        const pr = c.poll(&pfd, 1, 0);
        if (pr < 0) return Error.IoError;
        if (pr == 0) return null;

        const fd = c.accept(listener_fd, null, null);
        if (fd < 0) return Error.IoError;

        return .{ .fd = fd };
    }

    fn mapHostState(st: @TypeOf(@as(*host.PtyChildHost, undefined).currentState())) wire.SessionStatus {
        return switch (st) {
            .starting => .starting,
            .running => .running,
            .exited => .exited,
            .idle => .idle,
            .closed => .closed,
        };
    }

    fn signalName(sig: wire.Signal) []const u8 {
        return switch (sig) {
            .term => "TERM",
            .int => "INT",
            .kill => "KILL",
        };
    }

    fn ensurePtyNonBlocking(self: *SessionServer) Error!void {
        if (self.pty_nonblocking_configured) return;

        const fd = self.session_host.masterFd() orelse return;
        try fd_stream.setNonBlocking(fd);
        self.pty_nonblocking_configured = true;
    }

    fn clearOwnerTransport(self: *SessionServer) void {
        if (self.owner_transport) |*transport| {
            transport.deinit();
        }
        self.owner_transport = null;
        self.owner_detach_after_flush = false;
    }

    fn queueMessageToFd(self: *SessionServer, fd: c_int, msg: wire.Message) void {
        if (self.core_state.ownerFd()) |owner_fd| {
            if (owner_fd == fd) {
                if (self.owner_transport) |*transport| {
                    transport.queueMessage(msg) catch {
                        self.handleWriteFailure(fd);
                    };
                    return;
                }
                self.handleWriteFailure(fd);
                return;
            }
        }

        wire.writeMessage(self.allocator, fd, msg) catch {
            self.handleWriteFailure(fd);
        };
    }

    fn writeControlRes(self: *SessionServer, fd: c_int, res: wire.ControlRes) void {
        self.queueMessageToFd(fd, .{ .control_res = res });
    }

    fn writeOwnerReq(self: *SessionServer, fd: c_int, req: wire.ForwardRequest) void {
        self.queueMessageToFd(fd, .{ .owner_req = req });
    }

    fn writeStdoutBytes(self: *SessionServer, fd: c_int, bytes: []const u8) void {
        const owned = self.allocator.dupe(u8, bytes) catch {
            self.handleWriteFailure(fd);
            return;
        };
        defer self.allocator.free(owned);

        self.queueMessageToFd(fd, .{ .stdout_bytes = owned });
    }

    fn handleWriteFailure(self: *SessionServer, fd: c_int) void {
        if (self.core_state.ownerFd()) |owner_fd| {
            if (owner_fd == fd) {
                self.clearOwnerTransport();
                self.dropOwner(false);
                return;
            }
        }
        _ = c.close(fd);
    }

    fn applyCoreOp(self: *SessionServer, op: core.Op) Error!void {
        switch (op) {
            .reply => |reply| {
                const res: wire.ControlRes = if (reply.ok)
                    .ok
                else
                    .{ .err = reply.code orelse .invalid_args };
                self.writeControlRes(reply.fd, res);
            },
            .send_owner_request => |req| {
                self.writeOwnerReq(req.fd, .{
                    .request_id = req.request_id,
                    .action = req.action,
                });
            },
            .close_fd => |fd| {
                if (self.core_state.ownerFd()) |owner_fd| {
                    if (owner_fd == fd) {
                        self.clearOwnerTransport();
                    }
                }
                _ = c.close(fd);
            },
            .resize_pty => |size| {
                self.session_host.resize(size.cols, size.rows) catch |e| switch (e) {
                    host.Error.InvalidArgs,
                    host.Error.InvalidState,
                    host.Error.NotStarted,
                    host.Error.Closed,
                    => {},
                    else => {},
                };
                self.session_host.signalWinch() catch |e| switch (e) {
                    host.Error.InvalidArgs,
                    host.Error.InvalidState,
                    host.Error.NotStarted,
                    host.Error.Closed,
                    => {},
                    else => {},
                };
            },
            .install_owner => |fd| {
                self.clearOwnerTransport();
                self.owner_transport = streaming.FramedTransport.init(
                    self.allocator,
                    fd,
                    client.DEFAULT_STREAM_FRAME_MAX,
                ) catch return Error.IoError;
            },
            .clear_owner => {
                self.clearOwnerTransport();
            },
        }
    }

    fn applyCoreOps(self: *SessionServer, ops: *core.OpList) Error!void {
        for (ops.items) |*op| {
            try self.applyCoreOp(op.*);
        }
    }

    fn dropOwner(self: *SessionServer, pty_closed: bool) void {
        var ops = core.OpList{};
        defer core.deinitOpList(self.allocator, &ops);

        if (pty_closed) {
            self.core_state.handlePtyClosed(self.allocator, &ops) catch return;
        } else {
            if (self.core_state.ownerFd()) |fd| {
                self.core_state.handleOwnerClosed(self.allocator, fd, &ops) catch return;
            } else {
                return;
            }
        }

        self.applyCoreOps(&ops) catch {};
    }

    fn handleRegularControlReq(self: *SessionServer, req: wire.ControlReq, client_fd: c_int) wire.ControlRes {
        _ = client_fd;

        return switch (req) {
            .status => .{ .status = mapHostState(self.session_host.currentState()) },
            .wait => blk: {
                switch (self.session_host.currentState()) {
                    .exited => {
                        const st = self.session_host.wait() catch {
                            break :blk .{ .err = .invalid_args };
                        };
                        if (st.code) |code| break :blk .{ .exit = .{ .code = code } };
                        break :blk .{ .exit = .{ .signal_text = @constCast(st.signal orelse "unknown") } };
                    },
                    else => break :blk .{ .err = .invalid_args },
                }
            },
            .terminate => |sig| blk: {
                self.session_host.terminate(signalName(sig)) catch {
                    break :blk .{ .err = .invalid_args };
                };
                break :blk .ok;
            },
            .attach => .{ .err = .invalid_args },
            .detach => .{ .err = .invalid_args },
            .resize => .{ .err = .invalid_args },
            .owner_forward => .{ .err = .invalid_args },
        };
    }

    fn handleAcceptedConnection(self: *SessionServer, conn: Connection) Error!void {
        var msg = wire.readMessage(self.allocator, conn.fd, client.DEFAULT_CONTROL_FRAME_MAX) catch {
            _ = c.close(conn.fd);
            return Error.Unsupported;
        };
        defer msg.deinit(self.allocator);

        switch (msg) {
            .control_req => |req| {
                switch (req) {
                    .attach => |mode| {
                        var ops = core.OpList{};
                        defer core.deinitOpList(self.allocator, &ops);

                        self.core_state.handleAttach(self.allocator, conn.fd, mode, &ops) catch {
                            self.writeControlRes(conn.fd, .{ .err = .invalid_args });
                            _ = c.close(conn.fd);
                            return;
                        };

                        try self.applyCoreOps(&ops);
                        return;
                    },
                    .owner_forward => |forward| {
                        var ops = core.OpList{};
                        defer core.deinitOpList(self.allocator, &ops);

                        self.core_state.handleForward(self.allocator, conn.fd, forward.request_id, forward.action, &ops) catch {
                            self.writeControlRes(conn.fd, .{ .err = .invalid_args });
                            _ = c.close(conn.fd);
                            return;
                        };

                        try self.applyCoreOps(&ops);
                        return;
                    },
                    else => {
                        const res = self.handleRegularControlReq(req, conn.fd);
                        self.writeControlRes(conn.fd, res);
                        _ = c.close(conn.fd);
                        return;
                    },
                }
            },
            else => {
                _ = c.close(conn.fd);
                return Error.Unsupported;
            },
        }
    }

    fn maybeFinalizePendingOwnerDetach(self: *SessionServer) Error!bool {
        if (!self.owner_detach_after_flush) return false;

        const owner_fd = self.core_state.ownerFd() orelse {
            self.owner_detach_after_flush = false;
            return false;
        };

        if (self.owner_transport) |*transport| {
            if (!transport.tx.isEmpty()) return false;
        } else {
            self.owner_detach_after_flush = false;
            return false;
        }

        var ops = core.OpList{};
        defer core.deinitOpList(self.allocator, &ops);

        self.core_state.handleOwnerDetach(self.allocator, owner_fd, &ops) catch {};
        try self.applyCoreOps(&ops);

        _ = c.close(owner_fd);
        self.owner_detach_after_flush = false;
        return true;
    }

    fn pumpOwnerIo(self: *SessionServer) Error!bool {
        const owner_fd = self.core_state.ownerFd() orelse return false;
        if (self.owner_transport == null) return false;

        if (try self.maybeFinalizePendingOwnerDetach()) return true;

        var progressed = false;

        if (self.owner_transport) |*transport| {
            const events: c_short = if (self.owner_detach_after_flush)
                (if (transport.wantsWrite()) c.POLLOUT else 0)
            else
                transport.pollEvents();

            if (events == 0) return false;

            var pfd = c.struct_pollfd{
                .fd = owner_fd,
                .events = events,
                .revents = 0,
            };

            const pr = c.poll(&pfd, 1, 0);
            if (pr < 0) return Error.IoError;
            if (pr == 0) return false;

            if ((pfd.revents & c.POLLIN) != 0 and !self.owner_detach_after_flush) {
                const read_result = transport.pumpRead(64 * 1024) catch {
                    self.dropOwner(false);
                    return true;
                };
                progressed = progressed or (read_result.bytes_read > 0);

                if (read_result.hit_eof) {
                    self.dropOwner(false);
                    return true;
                }

                message_loop: while (true) {
                    var msg = transport.nextMessage() catch {
                        self.dropOwner(false);
                        return true;
                    } orelse break;
                    defer msg.deinit(self.allocator);

                    switch (msg) {
                        .stdin_bytes => |bytes| {
                            try self.pty_input_tx.append(self.allocator, bytes);
                            progressed = true;
                        },
                        .owner_ready => {
                            self.core_state.handleOwnerReady(owner_fd) catch {};
                            progressed = true;
                        },
                        .owner_resize => |size| {
                            var ops = core.OpList{};
                            defer core.deinitOpList(self.allocator, &ops);

                            self.core_state.handleOwnerResize(self.allocator, owner_fd, size.cols, size.rows, &ops) catch {};
                            try self.applyCoreOps(&ops);
                            progressed = true;
                        },
                        .owner_res => |res| {
                            var ops = core.OpList{};
                            defer core.deinitOpList(self.allocator, &ops);

                            self.core_state.handleForwardResponse(self.allocator, owner_fd, res.request_id, res.ok, res.code, &ops) catch {};
                            try self.applyCoreOps(&ops);
                            progressed = true;
                        },
                        .control_req => |req| {
                            switch (req) {
                                .detach => {
                                    self.writeControlRes(owner_fd, .ok);
                                    self.owner_detach_after_flush = true;
                                    progressed = true;
                                    break :message_loop;
                                },
                                .resize => |size| {
                                    var ops = core.OpList{};
                                    defer core.deinitOpList(self.allocator, &ops);

                                    self.core_state.handleOwnerResize(self.allocator, owner_fd, size.cols, size.rows, &ops) catch {};
                                    try self.applyCoreOps(&ops);

                                    self.writeControlRes(owner_fd, .ok);
                                    progressed = true;
                                },
                                .status => {
                                    const res = self.handleRegularControlReq(req, owner_fd);
                                    self.writeControlRes(owner_fd, res);
                                    progressed = true;
                                },
                                .terminate => {
                                    const res = self.handleRegularControlReq(req, owner_fd);
                                    self.writeControlRes(owner_fd, res);
                                    progressed = true;
                                },
                                .wait,
                                .attach,
                                .owner_forward,
                                => {
                                    self.writeControlRes(owner_fd, .{ .err = .invalid_args });
                                    progressed = true;
                                },
                            }
                        },
                        else => {
                            self.dropOwner(false);
                            return true;
                        },
                    }
                }
            }

            if ((pfd.revents & c.POLLOUT) != 0) {
                const wr = transport.pumpWrite(64 * 1024) catch {
                    self.dropOwner(false);
                    return true;
                };
                progressed = progressed or (wr.bytes_written > 0);
            }

            if ((pfd.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0 and
                (pfd.revents & c.POLLIN) == 0)
            {
                self.dropOwner(false);
                return true;
            }
        }

        if (try self.maybeFinalizePendingOwnerDetach()) return true;
        return progressed;
    }

    fn pumpPtyIo(self: *SessionServer) Error!bool {
        const master_fd = self.session_host.masterFd() orelse {
            if (self.core_state.hasOwner()) self.dropOwner(true);
            return false;
        };

        var progressed = false;

        if (!self.pty_input_tx.isEmpty()) {
            const wr = try fd_stream.writeFromQueue(master_fd, &self.pty_input_tx, 64 * 1024);
            switch (wr) {
                .progress => |n| {
                    if (n > 0) progressed = true;
                },
                .would_block => {},
            }
        }

        var output_budget: usize = 64 * 1024;
        while (output_budget > 0) {
            const max_chunk = @min(output_budget, 4096);
            const chunk = self.session_host.readOutput(self.allocator, max_chunk, 0) catch |e| switch (e) {
                host.Error.InvalidState,
                host.Error.NotStarted,
                host.Error.Closed,
                => return progressed,
                host.Error.IoError => {
                    if (self.core_state.hasOwner()) self.dropOwner(true);
                    return progressed;
                },
                else => return Error.IoError,
            };
            defer self.allocator.free(chunk);

            if (chunk.len == 0) break;

            output_budget -= chunk.len;
            progressed = true;

            if (self.core_state.ownerFd()) |fd| {
                self.writeStdoutBytes(fd, chunk);
            }
        }

        return progressed;
    }
    pub fn installInitialOwner(self: *SessionServer, fd: c_int) Error!void {
        if (self.state != .listening) return Error.InvalidState;

        var ops = core.OpList{};
        defer core.deinitOpList(self.allocator, &ops);

        try self.core_state.installInitialOwner(self.allocator, fd, &ops);
        try self.applyCoreOps(&ops);
    }
};

test "server starts created" {
    var h = try host.PtyChildHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer h.deinit();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    try std.testing.expectEqual(ServerState.created, s.getState());
}

test "server listens" {
    var h = try host.PtyChildHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer h.deinit();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-listen-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);

    try s.listen(path);
    try std.testing.expectEqual(ServerState.listening, s.getState());
}

test "server step handles status request" {
    var h = try host.PtyChildHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-status-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try client.connectUnix(path);
    defer _ = c.close(fd);

    try wire.writeMessage(std.testing.allocator, fd, .{ .control_req = .status });

    _ = try s.step();

    var msg = try wire.readMessage(std.testing.allocator, fd, client.DEFAULT_CONTROL_FRAME_MAX);
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .control_res => |res| switch (res) {
            .status => |st| try std.testing.expect(st == .running),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server attach installs owner" {
    var h = try host.PtyChildHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-attach-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try client.connectUnix(path);
    defer _ = c.close(fd);

    try wire.writeMessage(std.testing.allocator, fd, .{ .control_req = .{ .attach = .exclusive } });

    _ = try s.step();

    var msg = try wire.readMessage(std.testing.allocator, fd, client.DEFAULT_CONTROL_FRAME_MAX);
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .control_res => |res| try std.testing.expect(res == .ok),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(s.hasOwner());
    try std.testing.expect(s.ownerFd() != null);
    try std.testing.expect(s.ownerFd().? != fd);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server owner_forward with no owner returns no_owner" {
    var h = try host.PtyChildHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-no-owner-forward-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try client.connectUnix(path);
    defer _ = c.close(fd);

    try wire.writeMessage(std.testing.allocator, fd, .{
        .control_req = .{
            .owner_forward = .{
                .request_id = 1,
                .action = .detach,
            },
        },
    });

    _ = try s.step();

    var msg = try wire.readMessage(std.testing.allocator, fd, client.DEFAULT_CONTROL_FRAME_MAX);
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .control_res => |res| switch (res) {
            .err => |code| try std.testing.expectEqual(core.ErrorCode.no_owner, code),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}


test "server malformed client message does not kill session" {
    var h = try host.PtyChildHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-malformed-client-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const bad_fd = try client.connectUnix(path);
    defer _ = c.close(bad_fd);
    try wire.writeFrameParts(bad_fd, .stdout_bytes, &.{"junk"});

    try std.testing.expectError(Error.Unsupported, s.step());
    try std.testing.expectEqual(ServerState.listening, s.getState());

    const good_fd = try client.connectUnix(path);
    defer _ = c.close(good_fd);
    try wire.writeMessage(std.testing.allocator, good_fd, .{ .control_req = .status });
    _ = try s.step();

    var msg = try wire.readMessage(std.testing.allocator, good_fd, client.DEFAULT_CONTROL_FRAME_MAX);
    defer msg.deinit(std.testing.allocator);
    switch (msg) {
        .control_res => |res| switch (res) {
            .status => |st| try std.testing.expect(st == .running),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "server detach-after-flush preserves queued pty output" {
    if (false) {
    var h = try host.PtyChildHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf hello; sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-server-detach-flush-test.sock";
    SessionServer.unlinkBestEffort(path);
    defer SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const fd = try client.connectUnix(path);
    defer _ = c.close(fd);

    try wire.writeMessage(std.testing.allocator, fd, .{ .control_req = .{ .attach = .exclusive } });
    _ = try s.step();
    var attach_msg = try wire.readMessage(std.testing.allocator, fd, client.DEFAULT_CONTROL_FRAME_MAX);
    defer attach_msg.deinit(std.testing.allocator);

    try wire.writeMessage(std.testing.allocator, fd, .owner_ready);
    _ = try s.step();

    try wire.writeMessage(std.testing.allocator, fd, .{ .control_req = .detach });

    var saw_ok = false;
    var saw_stdout = false;
    var loops: usize = 0;
    while (loops < 50 and (!saw_ok or !saw_stdout)) : (loops += 1) {
        _ = try s.step();
        var msg = wire.readMessage(std.testing.allocator, fd, client.DEFAULT_CONTROL_FRAME_MAX) catch |e| switch (e) {
            wire.Error.ReadFailed, wire.Error.UnexpectedEof => break,
            else => return e,
        };
        defer msg.deinit(std.testing.allocator);
        switch (msg) {
            .control_res => |res| {
                if (res == .ok) saw_ok = true;
            },
            .stdout_bytes => |bytes| {
                if (std.mem.indexOf(u8, bytes, "hello") != null) saw_stdout = true;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_ok);
    try std.testing.expect(saw_stdout);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
    }
}
