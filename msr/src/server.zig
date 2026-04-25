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
        if (self.state != .created) return Error.InvalidState;
        try validateSocketPath(socket_path);

        const fd = try createListener(socket_path);
        errdefer _ = c.close(fd);

        self.listener_fd = fd;
        self.socket_path = try self.allocator.dupe(u8, socket_path);
        self.runtime = try host_runtime.HostRuntime.init(self.allocator, socket_path, null);
        self.runtime.?.onSocketListening();
        self.state = .listening;
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
            if (self.runtime) |*runtime| runtime.onClientDisconnected();
        }
        self.owner_rx.clear();
        self.owner_tx.clear();
        self.pty_tx.clear();
    }

    fn installOwner(self: *SessionServer, fd: c_int) Error!void {
        const had_owner = self.owner_fd != null;
        self.dropOwner();
        try fd_stream.setNonBlocking(fd);
        self.owner_fd = fd;
        if (self.runtime) |*runtime| {
            if (had_owner) runtime.onClientReplaced() else runtime.onClientConnected();
        }
    }

    fn acceptLatestConnection(self: *SessionServer) Error!bool {
        const listener_fd = self.listener_fd orelse return Error.InvalidState;
        var accepted_any = false;

        while (true) {
            var pfd = c.struct_pollfd{ .fd = listener_fd, .events = c.POLLIN, .revents = 0 };
            const pr = c.poll(&pfd, 1, 0);
            if (pr < 0) return Error.IoError;
            if (pr == 0) break;

            const fd = c.accept(listener_fd, null, null);
            if (fd < 0) return Error.IoError;
            try self.installOwner(fd);
            accepted_any = true;
        }

        return accepted_any;
    }

    fn pumpOwnerToPty(self: *SessionServer) Error!bool {
        const owner_fd = self.owner_fd orelse return false;
        const master_fd = self.session_host.masterFd() orelse return false;
        var progressed = false;

        const rd = fd_stream.readIntoQueue(self.allocator, owner_fd, &self.owner_rx, 64 * 1024) catch {
            self.dropOwner();
            return true;
        };
        switch (rd) {
            .progress => |n| progressed = progressed or (n > 0),
            .would_block => {},
            .eof => {
                self.dropOwner();
                return true;
            },
        }

        if (!self.owner_rx.isEmpty()) {
            try self.pty_tx.append(self.allocator, self.owner_rx.readableSlice());
            self.owner_rx.clear();
        }

        if (!self.pty_tx.isEmpty()) {
            const wr = fd_stream.writeFromQueue(master_fd, &self.pty_tx, 64 * 1024) catch {
                return Error.IoError;
            };
            switch (wr) {
                .progress => |n| progressed = progressed or (n > 0),
                .would_block => {},
            }
        }

        return progressed;
    }

    fn pumpPtyToOwner(self: *SessionServer) Error!bool {
        const master_fd = self.session_host.masterFd() orelse return false;
        const owner_fd = self.owner_fd;
        var progressed = false;

        const rd = fd_stream.readIntoQueue(self.allocator, master_fd, &self.owner_tx, 64 * 1024) catch {
            return false;
        };
        switch (rd) {
            .progress => |n| progressed = progressed or (n > 0),
            .would_block => {},
            .eof => return false,
        }

        if (owner_fd) |fd| {
            if (!self.owner_tx.isEmpty()) {
                const wr = fd_stream.writeFromQueue(fd, &self.owner_tx, 64 * 1024) catch {
                    self.dropOwner();
                    return true;
                };
                switch (wr) {
                    .progress => |n| progressed = progressed or (n > 0),
                    .would_block => {},
                }
            }
        } else {
            self.owner_tx.clear();
        }

        return progressed;
    }
};
