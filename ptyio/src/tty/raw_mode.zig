const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

pub const Error = error{
    IoError,
};

pub const RawModeGuard = struct {
    fd: c_int,
    saved: c.struct_termios,
    active: bool = false,

    pub fn restore(self: *RawModeGuard) void {
        if (!self.active) return;
        _ = c.tcsetattr(self.fd, c.TCSANOW, &self.saved);
        self.active = false;
    }
};

pub fn enterRawMode(fd: c_int) Error!RawModeGuard {
    var saved: c.struct_termios = undefined;
    if (c.tcgetattr(fd, &saved) != 0) return Error.IoError;

    var raw = saved;
    c.cfmakeraw(&raw);
    if (c.tcsetattr(fd, c.TCSANOW, &raw) != 0) return Error.IoError;

    return .{
        .fd = fd,
        .saved = saved,
        .active = true,
    };
}
