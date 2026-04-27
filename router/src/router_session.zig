const std = @import("std");
const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const enterRawMode = @import("ptyio_raw_mode").enterRawMode;
const getTtySize = @import("ptyio_tty_size").getTtySize;
const router_runtime = @import("router_runtime");

const c = @cImport({
    @cInclude("signal.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

pub const DataAttach = struct {
    data_fd: c_int,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    stdin_is_tty: bool,
    raw_guard: ?@import("ptyio_raw_mode").RawModeGuard,
    stdin_rx: ByteQueue,
    sock_tx: ByteQueue,
    sock_rx: ByteQueue,
    stdout_tx: ByteQueue,
    active: ?DataAttach,
    attached_control_fd: ?c_int,

    pub fn init(allocator: std.mem.Allocator, stdin_is_tty: bool) Session {
        return .{
            .allocator = allocator,
            .stdin_is_tty = stdin_is_tty,
            .raw_guard = null,
            .stdin_rx = ByteQueue.init(),
            .sock_tx = ByteQueue.init(),
            .sock_rx = ByteQueue.init(),
            .stdout_tx = ByteQueue.init(),
            .active = null,
            .attached_control_fd = null,
        };
    }

    pub fn deinit(self: *Session) void {
        self.restoreRaw();
        self.closeAttach();
        self.stdin_rx.deinit(self.allocator);
        self.sock_tx.deinit(self.allocator);
        self.sock_rx.deinit(self.allocator);
        self.stdout_tx.deinit(self.allocator);
    }

    pub fn attach(self: *Session, spec: router_runtime.AttachSpec) !void {
        if (self.active != null) return router_runtime.Error.AlreadyAttached;
        const next = try openAttachFromSpec(spec);
        errdefer {
            _ = c.close(next.data_fd);
        }
        self.clearQueues();
        self.active = next;
        self.attached_control_fd = try connectUnix(spec.control_path);
        errdefer self.closeAttachedControl();
        try self.ensureRaw();
        try self.sendInitialResize();
    }

    pub fn detach(self: *Session) void {
        self.closeAttach();
        self.closeAttachedControl();
        self.clearQueues();
        self.restoreRaw();
    }

    pub fn onStreamLost(self: *Session) void {
        self.detach();
    }

    pub fn stepDataPump(self: *Session) !bool {
        const a = self.active orelse return false;

        if (self.stdin_is_tty) {
            while (true) {
                const in_status = try fd_stream.readIntoQueue(self.allocator, c.STDIN_FILENO, &self.stdin_rx, 64 * 1024);
                switch (in_status) {
                    .progress => {},
                    .would_block => break,
                    .eof => break,
                }
            }
            if (!self.stdin_rx.isEmpty()) {
                try self.sock_tx.append(self.allocator, self.stdin_rx.readableSlice());
                self.stdin_rx.clear();
            }
        }

        while (true) {
            const write_status = try fd_stream.writeFromQueue(a.data_fd, &self.sock_tx, 64 * 1024);
            switch (write_status) {
                .progress => {
                    if (self.sock_tx.isEmpty()) break;
                },
                .would_block => break,
            }
        }

        while (true) {
            const sock_status = try fd_stream.readIntoQueue(self.allocator, a.data_fd, &self.sock_rx, 64 * 1024);
            switch (sock_status) {
                .progress => {},
                .would_block => break,
                .eof => return true,
            }
        }

        if (!self.sock_rx.isEmpty()) {
            try appendForDisplay(self.allocator, &self.stdout_tx, self.sock_rx.readableSlice());
            self.sock_rx.clear();
        }

        while (true) {
            const out_status = try fd_stream.writeFromQueue(c.STDOUT_FILENO, &self.stdout_tx, 64 * 1024);
            switch (out_status) {
                .progress => {
                    if (self.stdout_tx.isEmpty()) break;
                },
                .would_block => break,
            }
        }
        return false;
    }

    fn ensureRaw(self: *Session) !void {
        if (!self.stdin_is_tty) return;
        if (self.raw_guard == null) self.raw_guard = try enterRawMode(c.STDIN_FILENO);
    }

    fn restoreRaw(self: *Session) void {
        if (self.raw_guard) |*g| {
            g.restore();
            self.raw_guard = null;
        }
    }

    fn clearQueues(self: *Session) void {
        self.stdin_rx.clear();
        self.sock_tx.clear();
        self.sock_rx.clear();
        self.stdout_tx.clear();
    }

    fn closeAttach(self: *Session) void {
        if (self.active) |a| {
            _ = c.close(a.data_fd);
            self.active = null;
        }
    }

    fn closeAttachedControl(self: *Session) void {
        if (self.attached_control_fd) |fd| {
            _ = c.close(fd);
            self.attached_control_fd = null;
        }
    }

    fn sendInitialResize(self: *Session) !void {
        if (!self.stdin_is_tty) return;
        const fd = self.attached_control_fd orelse return;
        const size = getTtySize(c.STDIN_FILENO) catch return;
        var buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "resize {d} {d}\n", .{ size.cols, size.rows });
        var sent: usize = 0;
        while (sent < msg.len) {
            const n = c.write(fd, msg.ptr + sent, msg.len - sent);
            if (n > 0) {
                sent += @intCast(n);
                continue;
            }
            if (n == 0) return error.WriteFailed;
            const e = std.posix.errno(-1);
            if (e == .INTR) continue;
            return error.WriteFailed;
        }
    }
};

fn appendForDisplay(allocator: std.mem.Allocator, queue: *ByteQueue, bytes: []const u8) !void {
    var start: usize = 0;
    for (bytes, 0..) |b, i| {
        if (b == '\n') {
            if (i > start) try queue.append(allocator, bytes[start..i]);
            if (i == 0 or bytes[i - 1] != '\r') {
                try queue.append(allocator, "\r\n");
            } else {
                try queue.append(allocator, "\n");
            }
            start = i + 1;
        }
    }
    if (start < bytes.len) try queue.append(allocator, bytes[start..]);
}

fn connectUnix(path: []const u8) !c_int {
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);

    const max_path_len = addr.sun_path.len - 1;
    if (path.len == 0 or path.len > max_path_len) return error.InvalidArgs;

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

fn openAttachFromSpec(spec: router_runtime.AttachSpec) !DataAttach {
    _ = spec.control_path;
    const data_fd = try connectUnix(spec.data_path);
    errdefer _ = c.close(data_fd);

    try fd_stream.setNonBlocking(data_fd);
    return .{ .data_fd = data_fd };
}
