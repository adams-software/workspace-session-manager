const std = @import("std");
const DuplexLink = @import("duplex_link").DuplexLink;
const fd_stream = @import("fd_stream");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("poll.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

pub const AttachSpec = struct {
    data_path: []const u8,
    control_path: ?[]const u8,
};

pub const PumpResult = struct {
    stream_lost: bool,
    did_work: bool,
};

pub const Signal = enum {
    term,
    kill,
};

pub const SessionLink = struct {
    allocator: std.mem.Allocator,
    pump: DuplexLink,
    data_fd: ?c_int,
    control_fd: ?c_int,
    data_eof: bool = false,

    pub fn init(allocator: std.mem.Allocator) SessionLink {
        return .{
            .allocator = allocator,
            .pump = DuplexLink.init(allocator),
            .data_fd = null,
            .control_fd = null,
        };
    }

    pub fn deinit(self: *SessionLink) void {
        self.detach();
        self.pump.deinit();
    }

    pub fn attach(self: *SessionLink, spec: AttachSpec) !void {
        if (self.data_fd != null) return error.AlreadyAttached;

        const data_fd = try connectUnix(spec.data_path);
        errdefer _ = c.close(data_fd);

        var control_fd: ?c_int = null;
        errdefer {
            if (control_fd) |fd| _ = c.close(fd);
        }

        if (spec.control_path) |control_path| {
            control_fd = connectUnix(control_path) catch null;
        }

        self.data_fd = data_fd;
        self.data_eof = false;
        self.control_fd = control_fd;
        self.pump.clear();
        if (self.control_fd) |fd| drainControl(fd);
    }

    pub fn detach(self: *SessionLink) void {
        self.data_eof = false;
        if (self.data_fd) |fd| {
            _ = c.close(fd);
            self.data_fd = null;
        }
        if (self.control_fd) |fd| {
            _ = c.close(fd);
            self.control_fd = null;
        }
        self.pump.clear();
    }

    pub fn dataPollFd(self: *const SessionLink) ?c_int {
        return if (self.dataPollEvents() != 0) self.data_fd else null;
    }

    pub fn dataPollEvents(self: *const SessionLink) c_short {
        if (self.data_eof) return 0;
        var events: c_short = if (self.pump.canReadRight()) c.POLLIN else 0;
        if (!self.pump.left_to_right.isEmpty()) events |= c.POLLOUT;
        return events;
    }

    pub fn canAcceptInput(self: *const SessionLink, byte_count: usize) bool {
        return !self.data_eof and byte_count <= DuplexLink.input_queue_limit - self.pump.left_to_right.len();
    }

    pub fn hasPendingOutput(self: *const SessionLink) bool {
        return !self.pump.right_to_left.isEmpty();
    }

    pub fn writeInput(self: *SessionLink, bytes: []const u8) !void {
        try self.pump.pushLeft(bytes);
        if (self.data_fd) |fd| _ = try self.pump.flushLeftToRight(fd);
    }

    pub fn pumpDataToOutput(self: *SessionLink, output_fd: c_int) !PumpResult {
        const data_fd = self.data_fd orelse return .{ .stream_lost = false, .did_work = false };
        if (self.data_eof) {
            const did_work = try self.pump.flushRightToLeft(output_fd);
            return .{ .stream_lost = !self.hasPendingOutput(), .did_work = did_work };
        }
        const result = try self.pump.pump(output_fd, data_fd);
        self.data_eof = result.right_eof;
        return .{ .stream_lost = self.data_eof and !self.hasPendingOutput(), .did_work = result.did_work };
    }

    pub fn resize(self: *SessionLink, cols: u16, rows: u16) !void {
        const fd = self.control_fd orelse return;
        drainControl(fd);
        var buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "resize {d} {d}\n", .{ cols, rows });
        try writeControl(fd, msg);
        drainControl(fd);
    }

    pub fn signal(self: *SessionLink, sig: Signal) !void {
        const fd = self.control_fd orelse return error.NoControl;
        drainControl(fd);
        const msg = switch (sig) {
            .term => "signal term\n",
            .kill => "signal kill\n",
        };
        try writeControl(fd, msg);
        drainControl(fd);
    }
};

fn writeControl(fd: c_int, msg: []const u8) !void {
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

fn drainControl(fd: c_int) void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n > 0) continue;
        if (n == 0) return;
        const e = std.posix.errno(-1);
        if (e == .INTR) continue;
        return;
    }
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
    errdefer _ = c.close(fd);

    if (c.connect(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) {
        return error.ConnectFailed;
    }

    try fd_stream.setNonBlocking(fd);
    return fd;
}

test "session EOF waits for blocked terminal output to drain" {
    var data: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK, 0, &data));
    var link = SessionLink.init(std.testing.allocator);
    defer link.deinit();
    link.data_fd = data[1];
    const final_output = "final session output";
    const sent = c.write(data[0], final_output.ptr, final_output.len);
    _ = c.close(data[0]);
    try std.testing.expectEqual(@as(isize, final_output.len), sent);

    var output: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe2(&output, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer _ = c.close(output[0]);
    defer _ = c.close(output[1]);
    const padding: [4096]u8 = @splat('x');
    while (c.write(output[1], &padding, padding.len) > 0) {}
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(-1));

    const first = try link.pumpDataToOutput(output[1]);
    try std.testing.expect(first.did_work);
    try std.testing.expect(!first.stream_lost);
    try std.testing.expect(link.hasPendingOutput());
    try std.testing.expect(link.dataPollFd() == null);
    // Repeated pumping must retain bytes without repeatedly reading the EOF fd.
    for (0..10) |_| {
        const stalled = try link.pumpDataToOutput(output[1]);
        try std.testing.expect(!stalled.stream_lost and !stalled.did_work);
        try std.testing.expectEqualStrings(final_output, link.pump.right_to_left.readableSlice());
    }
    var drain: [4096]u8 = undefined;
    while (c.read(output[0], &drain, drain.len) > 0) {}
    const last = try link.pumpDataToOutput(output[1]);
    try std.testing.expect(last.did_work and last.stream_lost);
    try std.testing.expect(!link.hasPendingOutput());
    var received: [final_output.len]u8 = undefined;
    try std.testing.expectEqual(@as(isize, received.len), c.read(output[0], &received, received.len));
    try std.testing.expectEqualStrings(final_output, &received);
    link.detach();
    try std.testing.expect(!link.data_eof);
}

test "session EOF without pending output reports stream loss immediately" {
    var data: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK, 0, &data));
    var link = SessionLink.init(std.testing.allocator);
    defer link.deinit();
    link.data_fd = data[1];
    _ = c.close(data[0]);
    const result = try link.pumpDataToOutput(-1); // No output write is needed.
    try std.testing.expect(result.stream_lost);
    try std.testing.expect(!result.did_work);
    try std.testing.expect(link.dataPollFd() == null);
}

test "session output backpressure bounds reads and preserves final bytes through EOF" {
    var data: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK, 0, &data));
    var link = SessionLink.init(std.testing.allocator);
    defer link.deinit();
    link.data_fd = data[1];
    const tail = "0123456789";
    const sent = c.write(data[0], tail.ptr, tail.len);
    _ = c.close(data[0]);
    try std.testing.expectEqual(@as(isize, tail.len), sent);

    var output: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe2(&output, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer _ = c.close(output[0]);
    defer _ = c.close(output[1]);
    const padding: [4096]u8 = @splat('x');
    while (c.write(output[1], &padding, padding.len) > 0) {}
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(-1));

    // Leave less than one read chunk free; only three socket bytes may be read.
    const prefix = try std.testing.allocator.alloc(u8, 256 * 1024 - 3);
    defer std.testing.allocator.free(prefix);
    @memset(prefix, 'a');
    try link.pump.right_to_left.append(std.testing.allocator, prefix);
    try std.testing.expectEqual(@as(?c_int, data[1]), link.dataPollFd());
    const first = try link.pumpDataToOutput(output[1]);
    try std.testing.expect(first.did_work and !first.stream_lost);
    try std.testing.expectEqual(@as(usize, 256 * 1024), link.pump.right_to_left.len());
    try std.testing.expectEqual(@as(usize, 256 * 1024), link.pump.right_to_left.capacity());
    try std.testing.expectEqualStrings("012", link.pump.right_to_left.readableSlice()[prefix.len..]);
    try std.testing.expect(link.dataPollFd() == null);
    for (0..100) |_| {
        const stalled = try link.pumpDataToOutput(output[1]);
        try std.testing.expect(!stalled.did_work and !stalled.stream_lost);
        try std.testing.expectEqual(@as(usize, 256 * 1024), link.pump.right_to_left.capacity());
    }

    var bytes: [4096]u8 = undefined;
    while (c.read(output[0], &bytes, bytes.len) > 0) {} // Remove only the padding.
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(std.testing.allocator);
    var lost = false;
    var iterations: usize = 0;
    while (!lost and iterations < 200) : (iterations += 1) {
        const result = try link.pumpDataToOutput(output[1]);
        if (iterations == 0) try std.testing.expectEqual(@as(?c_int, data[1]), link.dataPollFd());
        lost = result.stream_lost;
        while (true) {
            const n = c.read(output[0], &bytes, bytes.len);
            if (n <= 0) break;
            try received.appendSlice(std.testing.allocator, bytes[0..@intCast(n)]);
        }
        try std.testing.expect(link.pump.right_to_left.capacity() <= 256 * 1024);
    }
    try std.testing.expect(lost);
    try std.testing.expectEqual(prefix.len + tail.len, received.items.len);
    try std.testing.expectEqualSlices(u8, prefix, received.items[0..prefix.len]);
    try std.testing.expectEqualStrings(tail, received.items[prefix.len..]);
    try std.testing.expect(!link.hasPendingOutput());
}

test "session input is bounded and resumes on socket write readiness" {
    var data: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK, 0, &data));
    defer _ = c.close(data[0]);
    var link = SessionLink.init(std.testing.allocator);
    defer link.deinit();
    link.data_fd = data[1];
    const padding: [4096]u8 = @splat('x');
    while (c.write(data[1], &padding, padding.len) > 0) {}
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(-1));

    const prefix = try std.testing.allocator.alloc(u8, 256 * 1024 - 1);
    defer std.testing.allocator.free(prefix);
    @memset(prefix, 'a');
    try std.testing.expect(link.canAcceptInput(256));
    try link.writeInput(prefix);
    try std.testing.expect(!link.canAcceptInput(256));
    try std.testing.expect(link.canAcceptInput(1));
    try link.writeInput("z");
    try std.testing.expect(!link.canAcceptInput(1));
    try std.testing.expectError(error.InputQueueFull, link.writeInput("overflow"));
    try std.testing.expectEqual(@as(usize, 256 * 1024), link.pump.left_to_right.len());
    try std.testing.expectEqual(@as(usize, 256 * 1024), link.pump.left_to_right.capacity());
    try std.testing.expect((link.dataPollEvents() & c.POLLOUT) != 0);

    // A full output queue must not suppress socket writes needed for recovery.
    try link.pump.right_to_left.append(std.testing.allocator, prefix);
    try link.pump.right_to_left.appendByte(std.testing.allocator, 'x');
    try std.testing.expectEqual(@as(c_short, c.POLLOUT), link.dataPollEvents());
    try std.testing.expectEqual(@as(?c_int, data[1]), link.dataPollFd());
    link.pump.right_to_left.clear();
    var bytes: [4096]u8 = undefined;
    while (c.read(data[0], &bytes, bytes.len) > 0) {} // Remove the socket padding.
    var ready = [_]std.c.pollfd{.{ .fd = link.dataPollFd().?, .events = link.dataPollEvents(), .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&ready, 1, 0));
    try std.testing.expect((ready[0].revents & c.POLLOUT) != 0);

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(std.testing.allocator);
    var iterations: usize = 0;
    while (received.items.len < prefix.len + 1 and iterations < 100) : (iterations += 1) {
        // The peer sends no output: socket write readiness alone must recover.
        const result = try link.pumpDataToOutput(-1);
        try std.testing.expect(!result.stream_lost);
        while (true) {
            const n = c.read(data[0], &bytes, bytes.len);
            if (n <= 0) break;
            try received.appendSlice(std.testing.allocator, bytes[0..@intCast(n)]);
        }
    }
    try std.testing.expectEqual(prefix.len + 1, received.items.len);
    try std.testing.expectEqualSlices(u8, prefix, received.items[0..prefix.len]);
    try std.testing.expectEqual(@as(u8, 'z'), received.items[prefix.len]);
    try std.testing.expect(link.canAcceptInput(256));
    try std.testing.expectEqual(@as(usize, 0), link.pump.left_to_right.len());
    try std.testing.expectEqual(@as(usize, 256 * 1024), link.pump.left_to_right.capacity());
    try std.testing.expectEqual(@as(c_short, c.POLLIN), link.dataPollEvents());
}
