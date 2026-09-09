const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
});

pub const WakePipe = struct {
    fds: [2]c_int = .{ -1, -1 },

    pub fn init() !WakePipe {
        var pipe_fds: [2]c_int = .{ -1, -1 };
        // A full pipe already guarantees a wakeup; notifications must not block.
        if (std.c.pipe2(&pipe_fds, .{ .NONBLOCK = true, .CLOEXEC = true }) != 0) return error.IoError;
        return .{ .fds = pipe_fds };
    }

    pub fn deinit(self: *WakePipe) void {
        if (self.fds[0] >= 0) _ = c.close(self.fds[0]);
        if (self.fds[1] >= 0) _ = c.close(self.fds[1]);
        self.fds = .{ -1, -1 };
    }

    pub fn readFd(self: *const WakePipe) c_int {
        return self.fds[0];
    }

    pub fn writeFd(self: *const WakePipe) c_int {
        return self.fds[1];
    }

    pub fn notify(self: *const WakePipe) void {
        const saved_errno = std.c._errno().*;
        defer std.c._errno().* = saved_errno;
        if (self.fds[1] >= 0) {
            const b: u8 = 1;
            while (c.write(self.fds[1], &b, 1) < 0) {
                if (std.posix.errno(-1) != .INTR) break;
            }
        }
    }

    pub fn drain(self: *const WakePipe) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = c.read(self.fds[0], &buf, buf.len);
            if (n < 0 and std.posix.errno(-1) == .INTR) continue;
            if (n <= 0) break;
        }
    }
};

test "wake pipe never blocks and coalesced notifications preserve errno" {
    var pipe = try WakePipe.init();
    defer pipe.deinit();
    for (pipe.fds) |fd| {
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        try std.testing.expect(flags >= 0);
        const options: std.c.O = @bitCast(@as(u32, @intCast(flags)));
        // Check before exercising empty/full states so a regression fails, not hangs.
        try std.testing.expect(options.NONBLOCK);
        const fd_flags = std.c.fcntl(fd, std.c.F.GETFD);
        try std.testing.expect(fd_flags >= 0);
        try std.testing.expect((fd_flags & std.c.FD_CLOEXEC) != 0);
    }
    pipe.drain();
    for (0..64) |_| pipe.notify();
    pipe.drain(); // Previously blocked on the next read after an exact-size batch.
    pipe.drain();

    const capacity = std.c.fcntl(pipe.writeFd(), std.c.F.GETPIPE_SZ);
    try std.testing.expect(capacity > 0);
    for (0..@as(usize, @intCast(capacity))) |_| pipe.notify();
    const sentinel = @intFromEnum(std.posix.E.INVAL);
    std.c._errno().* = sentinel;
    pipe.notify(); // Full pipe: coalesce this notification and preserve caller errno.
    try std.testing.expectEqual(sentinel, std.c._errno().*);
    pipe.drain();

    // A subsequent notification must still wake the reader.
    std.c._errno().* = sentinel;
    pipe.notify();
    try std.testing.expectEqual(sentinel, std.c._errno().*);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), c.read(pipe.readFd(), &byte, 1));
    try std.testing.expectEqual(@as(u8, 1), byte[0]);
    try std.testing.expectEqual(@as(isize, -1), c.read(pipe.readFd(), &byte, 1));
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(-1));
}
