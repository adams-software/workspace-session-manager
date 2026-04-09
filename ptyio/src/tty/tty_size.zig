const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
});

pub const Error = error{
    IoError,
};

pub const TtySize = struct {
    cols: u16,
    rows: u16,
};

pub fn getTtySize(fd: c_int) Error!TtySize {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(fd, c.TIOCGWINSZ, &ws) != 0) return Error.IoError;
    return .{ .cols = ws.ws_col, .rows = ws.ws_row };
}
