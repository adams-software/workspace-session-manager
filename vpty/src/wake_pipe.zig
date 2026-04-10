const c = @cImport({
    @cInclude("unistd.h");
});

pub const WakePipe = struct {
    fds: [2]c_int = .{ -1, -1 },

    pub fn init() !WakePipe {
        var pipe_fds: [2]c_int = .{ -1, -1 };
        if (c.pipe(&pipe_fds) != 0) return error.IoError;
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
        if (self.fds[1] >= 0) {
            const b: u8 = 1;
            _ = c.write(self.fds[1], &b, 1);
        }
    }

    pub fn drain(self: *const WakePipe) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = c.read(self.fds[0], &buf, buf.len);
            if (n <= 0 or n < buf.len) break;
        }
    }
};
