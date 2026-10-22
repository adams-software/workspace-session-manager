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

// vpty forwards these child-owned modes to the outer terminal. Return them to a
// neutral baseline whenever vpty relinquishes that terminal to its caller.
const interaction_mode_reset =
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l" ++
    "\x1b[?1005l\x1b[?1006l\x1b[?1015l" ++
    "\x1b[?1004l\x1b[?2004l\x1b[?2005l\x1b[?2006l\x1b[?1l";

fn writeAllBestEffort(fd: c_int, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (written > 0) {
            offset += @intCast(written);
            continue;
        }
        if (written < 0 and std.c.errno(written) == .INTR) continue;
        return;
    }
}

pub const TerminalMode = struct {
    stdin_fd: c_int,
    stdout_fd: c_int,
    interactive: bool,
    raw_enabled: bool = false,
    alt_screen_enabled: bool = false,
    interaction_modes_owned: bool = false,
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
        self.interaction_modes_owned = true;
    }

    pub fn enterAltScreen(self: *TerminalMode) Error!void {
        if (!self.interactive or self.alt_screen_enabled) return;
        const bytes = "\x1b[?1049h";
        if (c.write(self.stdout_fd, bytes.ptr, bytes.len) < 0) return Error.IoError;
        self.alt_screen_enabled = true;
    }

    pub fn leaveAltScreen(self: *TerminalMode) void {
        if (!self.interactive or !self.alt_screen_enabled) return;
        const bytes = "\x1b[?1049l";
        _ = c.write(self.stdout_fd, bytes.ptr, bytes.len);
        self.alt_screen_enabled = false;
    }

    pub fn restore(self: *TerminalMode) void {
        if (self.interactive and self.interaction_modes_owned) {
            writeAllBestEffort(self.stdout_fd, interaction_mode_reset);
            self.interaction_modes_owned = false;
        }
        self.leaveAltScreen();
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
