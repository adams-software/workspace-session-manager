const std = @import("std");
const host = @import("host");
const host_runtime = @import("host_runtime");
const fd_stream = @import("fd_stream");
const ByteQueue = @import("byte_queue").ByteQueue;

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("pty.h");
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
} || host.Error || fd_stream.Error;

pub const ServerState = enum {
    created,
    listening,
    stopped,
};

pub const SessionServer = struct {
    const io_chunk_size = 64 * 1024;
    const input_limit = 256 * 1024;

    allocator: std.mem.Allocator,
    session_host: *host.PtyChildHost,
    state: ServerState = .created,
    listener_fd: ?c_int = null,
    socket_path: ?[]u8 = null,
    runtime: ?host_runtime.HostRuntime = null,
    owner_fd: ?c_int = null,
    owner_rx: ByteQueue = ByteQueue.init(),
    owner_tx: ByteQueue = ByteQueue.init(),
    pty_tx: ByteQueue = ByteQueue.init(),
    pty_nonblocking_configured: bool = false,
    pty_read_open: bool = true,

    pub fn init(allocator: std.mem.Allocator, session_host: *host.PtyChildHost) SessionServer {
        return .{
            .allocator = allocator,
            .session_host = session_host,
        };
    }

    pub fn deinit(self: *SessionServer) void {
        self.dropOwner();
        self.owner_rx.deinit(self.allocator);
        self.owner_tx.deinit(self.allocator);
        self.pty_tx.deinit(self.allocator);

        if (self.listener_fd) |fd| {
            _ = c.close(fd);
            self.listener_fd = null;
        }

        if (self.runtime) |*runtime| {
            runtime.deinit();
            self.runtime = null;
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

    pub fn listen(self: *SessionServer, socket_path: []const u8) Error!void {
        return self.listenWithEventSink(socket_path, null);
    }

    pub fn listenWithEventSink(
        self: *SessionServer,
        socket_path: []const u8,
        event_sink: ?host_runtime.EventSink,
    ) Error!void {
        if (self.state != .created) return Error.InvalidState;
        try validateSocketPath(socket_path);

        const fd = try createListener(socket_path);
        errdefer _ = c.close(fd);

        self.listener_fd = fd;
        self.socket_path = try self.allocator.dupe(u8, socket_path);
        self.runtime = try host_runtime.HostRuntime.init(self.allocator, socket_path, event_sink);
        self.state = .listening;
    }

    pub fn markReady(self: *SessionServer) Error!void {
        if (self.state != .listening) return Error.InvalidState;
        if (self.runtime) |*runtime| runtime.onSocketListening();
    }

    pub fn stop(self: *SessionServer) Error!void {
        switch (self.state) {
            .created => return Error.InvalidState,
            .listening => {
                self.dropOwner();
                if (self.listener_fd) |fd| {
                    _ = c.close(fd);
                    self.listener_fd = null;
                }
                if (self.socket_path) |path| unlinkBestEffort(path);
                self.state = .stopped;
            },
            .stopped => {},
        }
    }

    pub fn step(self: *SessionServer) Error!bool {
        if (self.state != .listening) return Error.InvalidState;
        try self.ensurePtyNonBlocking();

        var progressed = false;
        if (try self.acceptLatestConnection()) progressed = true;
        if (try self.pumpOwnerToPty()) progressed = true;
        if (try self.pumpPtyToOwner()) progressed = true;
        return progressed;
    }

    pub fn ownerPollEvents(self: *const SessionServer) c_short {
        if (self.owner_fd == null) return 0;
        var events: c_short = if (self.pty_tx.len() < input_limit) c.POLLIN else 0;
        if (!self.owner_tx.isEmpty()) events |= c.POLLOUT;
        return events;
    }

    pub fn masterPollEvents(self: *const SessionServer) c_short {
        var events: c_short = 0;
        // Match pumpPtyToOwner: unread output cannot make progress until
        // an owner is attached and its pending output has drained.
        if (self.pty_read_open and self.owner_fd != null and self.owner_tx.isEmpty()) events |= c.POLLIN;
        if (!self.pty_tx.isEmpty()) events |= c.POLLOUT;
        return events;
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

    fn ensurePtyNonBlocking(self: *SessionServer) Error!void {
        if (self.pty_nonblocking_configured) return;
        const fd = self.session_host.masterFd() orelse return;
        try fd_stream.setNonBlocking(fd);
        self.pty_nonblocking_configured = true;
    }

    fn dropOwner(self: *SessionServer) void {
        if (self.owner_fd) |fd| {
            _ = c.shutdown(fd, c.SHUT_RDWR);
            _ = c.close(fd);
            self.owner_fd = null;
            self.notifyClientDisconnected();
        }
        self.owner_tx.clear();
    }

    fn installOwner(self: *SessionServer, fd: c_int) Error!void {
        const had_owner = self.owner_fd != null;
        self.dropOwner();
        try fd_stream.setNonBlocking(fd);
        self.owner_fd = fd;
        self.notifyClientAttached(had_owner);
    }

    fn acceptLatestConnection(self: *SessionServer) Error!bool {
        const listener_fd = self.listener_fd orelse return Error.InvalidState;
        var accepted_any = false;

        while (true) {
            var pfd = c.struct_pollfd{ .fd = listener_fd, .events = c.POLLIN, .revents = 0 };
            const pr = std.c.poll(@ptrCast(&pfd), 1, 0);
            if (pr < 0) return Error.IoError;
            if (pr == 0) break;

            const fd = c.accept(listener_fd, null, null);
            if (fd < 0) return Error.IoError;
            try self.installOwner(fd);
            accepted_any = true;
        }

        return accepted_any;
    }

    fn commitOwnerRx(self: *SessionServer) Error!void {
        if (!self.owner_rx.isEmpty()) {
            try self.pty_tx.append(self.allocator, self.owner_rx.readableSlice());
            self.owner_rx.clear();
        }
    }

    fn pumpOwnerToPty(self: *SessionServer) Error!bool {
        const master_fd = self.session_host.masterFd() orelse return false;
        var progressed = false;

        if (self.owner_fd) |owner_fd| {
            const room = input_limit - self.pty_tx.len();
            if (room == 0) return try self.flushPtyWrites(master_fd, progressed);
            const rd = fd_stream.readIntoQueue(self.allocator, owner_fd, &self.owner_rx, @min(room, io_chunk_size)) catch {
                try self.commitOwnerRx();
                self.dropOwner();
                progressed = true;
                return try self.flushPtyWrites(master_fd, progressed);
            };
            switch (rd) {
                .progress => |n| progressed = progressed or (n > 0),
                .would_block => {},
                .eof => {
                    try self.commitOwnerRx();
                    self.dropOwner();
                    progressed = true;
                },
            }

            try self.commitOwnerRx();
        }

        return try self.flushPtyWrites(master_fd, progressed);
    }

    fn pumpPtyToOwner(self: *SessionServer) Error!bool {
        const master_fd = self.session_host.masterFd() orelse return false;
        var progressed = false;

        if (self.owner_fd) |owner_fd| {
            progressed = try self.flushOwnerWrites(owner_fd, progressed);
            if (self.owner_fd == null) return progressed;
            if (!self.owner_tx.isEmpty()) return progressed;
        } else {
            self.owner_tx.clear();
            return false;
        }

        if (!self.pty_read_open) return progressed;
        const rd = fd_stream.readIntoQueue(self.allocator, master_fd, &self.owner_tx, io_chunk_size) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.pty_read_open = false;
            return progressed;
        };
        switch (rd) {
            .progress => |n| progressed = progressed or (n > 0),
            .would_block => {},
            .eof => {
                self.pty_read_open = false;
                return progressed;
            },
        }

        if (self.owner_fd) |fd| {
            return try self.flushOwnerWrites(fd, progressed);
        }
        self.owner_tx.clear();
        return progressed;
    }

    fn notifyClientDisconnected(self: *SessionServer) void {
        if (self.runtime) |*runtime| runtime.onClientDisconnected();
    }

    fn notifyClientAttached(self: *SessionServer, had_owner: bool) void {
        if (self.runtime) |*runtime| {
            if (had_owner) runtime.onClientReplaced() else runtime.onClientConnected();
        }
    }

    fn flushPtyWrites(self: *SessionServer, master_fd: c_int, progressed: bool) Error!bool {
        var did_progress = progressed;
        if (!self.pty_tx.isEmpty()) {
            const wr = fd_stream.writeFromQueue(master_fd, &self.pty_tx, io_chunk_size) catch {
                return Error.IoError;
            };
            switch (wr) {
                .progress => |n| did_progress = did_progress or (n > 0),
                .would_block => {},
            }
        }
        return did_progress;
    }

    fn flushOwnerWrites(self: *SessionServer, owner_fd: c_int, progressed: bool) Error!bool {
        var did_progress = progressed;
        if (!self.owner_tx.isEmpty()) {
            const wr = fd_stream.writeFromQueue(owner_fd, &self.owner_tx, io_chunk_size) catch {
                if (ownerSocketDisconnected(owner_fd)) {
                    self.dropOwner();
                    return true;
                }
                return did_progress;
            };
            switch (wr) {
                .progress => |n| did_progress = did_progress or (n > 0),
                .would_block => {},
            }
        }
        return did_progress;
    }

    fn ownerSocketDisconnected(fd: c_int) bool {
        var pfd = c.struct_pollfd{
            .fd = fd,
            .events = c.POLLIN | c.POLLOUT,
            .revents = 0,
        };

        const pr = std.c.poll(@ptrCast(&pfd), 1, 0);
        if (pr < 0) return false;
        return (pfd.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0;
    }
};

test "PTY EOF disables reads after pending owner output drains" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
    var child = try host.PtyChildHost.init(std.testing.allocator, .{ .argv = &.{"unused"} });
    child.master_fd = fds[0];
    defer child.deinit();
    var writer_open = true;
    defer if (writer_open) {
        _ = c.close(fds[1]);
    };
    var owner: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK, 0, &owner));
    defer _ = c.close(owner[1]);
    var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var server = SessionServer.init(allocations.allocator(), &child);
    defer server.deinit();
    server.owner_fd = owner[0];

    allocations.fail_index = allocations.alloc_index;
    try std.testing.expectError(error.OutOfMemory, server.pumpPtyToOwner());
    try std.testing.expect(server.pty_read_open);
    allocations.fail_index = std.math.maxInt(usize);
    try std.testing.expect(!try server.pumpPtyToOwner()); // EAGAIN is not EOF.
    try std.testing.expect((server.masterPollEvents() & c.POLLIN) != 0);
    try server.owner_tx.append(allocations.allocator(), "tail");
    _ = c.close(fds[1]);
    writer_open = false;
    try std.testing.expect(try server.pumpPtyToOwner());
    var tail: [4]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 4), c.read(owner[1], &tail, tail.len));
    try std.testing.expectEqualStrings("tail", &tail);
    try std.testing.expect(!server.pty_read_open);
    try std.testing.expectEqual(@as(c_short, 0), server.masterPollEvents());
    for (0..100) |_| try std.testing.expect(!try server.pumpPtyToOwner());
}

test "closed PTY slave read error disables further read polling" {
    var master: c_int = -1;
    var slave: c_int = -1;
    try std.testing.expectEqual(@as(c_int, 0), c.openpty(&master, &slave, null, null, null));
    _ = c.close(slave);
    var child = try host.PtyChildHost.init(std.testing.allocator, .{ .argv = &.{"unused"} });
    child.master_fd = master;
    defer child.deinit();
    try fd_stream.setNonBlocking(master);
    var owner: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK, 0, &owner));
    defer _ = c.close(owner[1]);
    var server = SessionServer.init(std.testing.allocator, &child);
    defer server.deinit();
    server.owner_fd = owner[0];
    try std.testing.expect(!try server.pumpPtyToOwner());
    try std.testing.expect(!server.pty_read_open);
    try std.testing.expectEqual(@as(c_short, 0), server.masterPollEvents());
    for (0..100) |_| try std.testing.expect(!try server.pumpPtyToOwner());
}
