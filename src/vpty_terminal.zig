const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

pub const Error = error{
    IoError,
    InvalidState,
};

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const TerminalMode = struct {
    stdin_fd: c_int,
    stdout_fd: c_int,
    interactive: bool,
    raw_enabled: bool = false,
    saved_termios: c.struct_termios = undefined,

    pub fn init(stdin_fd: c_int, stdout_fd: c_int) TerminalMode {
        return .{
            .stdin_fd = stdin_fd,
            .stdout_fd = stdout_fd,
            .interactive = c.isatty(stdin_fd) == 1 and c.isatty(stdout_fd) == 1,
        };
    }

    pub fn enterRaw(self: *TerminalMode) Error!void {
        if (!self.interactive) return;
        if (self.raw_enabled) return;
        if (c.tcgetattr(self.stdin_fd, &self.saved_termios) != 0) return Error.IoError;
        var raw = self.saved_termios;
        c.cfmakeraw(&raw);
        if (c.tcsetattr(self.stdin_fd, c.TCSANOW, &raw) != 0) return Error.IoError;
        self.raw_enabled = true;
    }

    pub fn restore(self: *TerminalMode) void {
        if (!self.interactive or !self.raw_enabled) return;
        _ = c.tcsetattr(self.stdin_fd, c.TCSANOW, &self.saved_termios);
        self.raw_enabled = false;
    }

    pub fn currentSize(self: *const TerminalMode) Error!Size {
        var ws: c.struct_winsize = undefined;
        if (c.ioctl(self.stdout_fd, c.TIOCGWINSZ, &ws) != 0) return Error.IoError;
        const rows: u16 = if (ws.ws_row == 0) 24 else @intCast(ws.ws_row);
        const cols: u16 = if (ws.ws_col == 0) 80 else @intCast(ws.ws_col);
        return .{ .rows = rows, .cols = cols };
    }
};
