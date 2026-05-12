const std = @import("std");
const DuplexLink = @import("duplex_link").DuplexLink;
const fd_stream = @import("fd_stream");

const c = @cImport({
    @cInclude("sys/socket.h");
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
        self.control_fd = control_fd;
        self.pump.clear();
    }

    pub fn detach(self: *SessionLink) void {
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
        return self.data_fd;
    }

    pub fn writeInput(self: *SessionLink, bytes: []const u8) !void {
        try self.pump.pushLeft(bytes);
        if (self.data_fd) |fd| _ = try self.pump.flushLeftToRight(fd);
    }

    pub fn pumpDataToOutput(self: *SessionLink, output_fd: c_int) !PumpResult {
        const data_fd = self.data_fd orelse return .{ .stream_lost = false, .did_work = false };
        const result = try self.pump.pump(output_fd, data_fd);
        return .{ .stream_lost = result.right_eof, .did_work = result.did_work };
    }

    pub fn resize(self: *SessionLink, cols: u16, rows: u16) !void {
        const fd = self.control_fd orelse return;
        var buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "resize {d} {d}\n", .{ cols, rows });
        try writeControl(fd, msg);
    }

    pub fn signal(self: *SessionLink, sig: Signal) !void {
        const fd = self.control_fd orelse return error.NoControl;
        const msg = switch (sig) {
            .term => "signal term\n",
            .kill => "signal kill\n",
        };
        try writeControl(fd, msg);
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
