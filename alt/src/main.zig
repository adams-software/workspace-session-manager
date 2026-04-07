const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("pty.h");
    @cInclude("signal.h");
    @cInclude("stdbool.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

const Allocator = std.mem.Allocator;

const ALT_SCREEN_ENTER = "\x1b[?1049h\x1b[H";
const ALT_SCREEN_LEAVE = "\x1b[?1049l";
const DEFAULT_KEY = "ctrl-g";
const DEFAULT_RUN = "wsm_menu";

const Error = error{
    InvalidArgs,
    MissingChildCommand,
    UnsupportedKeySpec,
    OpenPtyFailed,
    ForkFailed,
    ExecFailed,
    TerminalUnavailable,
    TcGetAttrFailed,
    TcSetAttrFailed,
    IoctlFailed,
    FcntlFailed,
    PollFailed,
    ChildExited,
    HookSpawnFailed,
};

const Config = struct {
    allocator: Allocator,
    key_spec: []const u8,
    run_cmd: []const u8,
    child_argv: []const []const u8,

    fn parse(allocator: Allocator, args_src: std.process.Args) !Config {
        var args_it = std.process.Args.Iterator.init(args_src);

        var args = std.ArrayList([]const u8){};
        defer {
            for (args.items) |arg| allocator.free(arg);
            args.deinit(allocator);
        }
        while (args_it.next()) |arg| {
            try args.append(allocator, try allocator.dupe(u8, arg));
        }

        var key_spec: []const u8 = if (c.getenv("ALT_KEY")) |v| std.mem.span(v) else DEFAULT_KEY;
        var run_cmd: []const u8 = if (c.getenv("ALT_RUN")) |v| std.mem.span(v) else DEFAULT_RUN;

        var i: usize = 1;
        var child_start: ?usize = null;
        while (i < args.items.len) : (i += 1) {
            const arg = args.items[i];
            if (std.mem.eql(u8, arg, "--")) {
                child_start = i + 1;
                break;
            }
            if (std.mem.eql(u8, arg, "--key")) {
                i += 1;
                if (i >= args.items.len) return Error.InvalidArgs;
                key_spec = args.items[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--run")) {
                i += 1;
                if (i >= args.items.len) return Error.InvalidArgs;
                run_cmd = args.items[i];
                continue;
            }
            return Error.InvalidArgs;
        }

        const start = child_start orelse return Error.MissingChildCommand;
        if (start >= args.items.len) return Error.MissingChildCommand;

        const child_copy = try allocator.alloc([]const u8, args.items.len - start);
        for (args.items[start..], 0..) |arg, idx| child_copy[idx] = try allocator.dupe(u8, arg);

        return .{
            .allocator = allocator,
            .key_spec = try allocator.dupe(u8, key_spec),
            .run_cmd = try allocator.dupe(u8, run_cmd),
            .child_argv = child_copy,
        };
    }

    fn deinit(self: *Config) void {
        self.allocator.free(self.key_spec);
        self.allocator.free(self.run_cmd);
        for (self.child_argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.child_argv);
    }
};

const KeyBinding = struct {
    byte: u8,

    fn parse(spec: []const u8) !KeyBinding {
        if (std.ascii.eqlIgnoreCase(spec, "ctrl-g")) return .{ .byte = 0x07 };
        if (spec.len == 1) return .{ .byte = spec[0] };
        return Error.UnsupportedKeySpec;
    }
};

const TerminalState = struct {
    tty_fd: c_int,
    original: c.struct_termios,
    raw_enabled: bool = false,

    fn init() !TerminalState {
        const tty_fd = c.open("/dev/tty", c.O_RDWR | c.O_CLOEXEC);
        if (tty_fd < 0) return Error.TerminalUnavailable;

        var term: c.struct_termios = undefined;
        if (c.tcgetattr(tty_fd, &term) != 0) {
            _ = c.close(tty_fd);
            return Error.TcGetAttrFailed;
        }

        return .{
            .tty_fd = tty_fd,
            .original = term,
        };
    }

    fn deinit(self: *TerminalState) void {
        if (self.raw_enabled) self.restore() catch {};
        _ = c.close(self.tty_fd);
    }

    fn enableRaw(self: *TerminalState) !void {
        var raw = self.original;
        c.cfmakeraw(&raw);
        if (c.tcsetattr(self.tty_fd, c.TCSAFLUSH, &raw) != 0) return Error.TcSetAttrFailed;
        self.raw_enabled = true;
    }

    fn restore(self: *TerminalState) !void {
        if (c.tcsetattr(self.tty_fd, c.TCSAFLUSH, &self.original) != 0) return Error.TcSetAttrFailed;
        self.raw_enabled = false;
    }
};

const ChildSession = struct {
    master_fd: c_int,
    pid: c.pid_t,

    fn spawn(allocator: Allocator, argv: []const []const u8, tty_fd: c_int) !ChildSession {
        var win: c.struct_winsize = undefined;
        if (c.ioctl(tty_fd, c.TIOCGWINSZ, &win) != 0) return Error.IoctlFailed;

        var master_fd: c_int = -1;
        var slave_fd: c_int = -1;
        if (c.openpty(&master_fd, &slave_fd, null, null, &win) != 0) {
            return Error.OpenPtyFailed;
        }
        errdefer {
            if (master_fd >= 0) _ = c.close(master_fd);
            if (slave_fd >= 0) _ = c.close(slave_fd);
        }

        const pid = c.fork();
        if (pid < 0) return Error.ForkFailed;

        if (pid == 0) {
            _ = c.close(master_fd);

            _ = c.setsid();
            _ = c.ioctl(slave_fd, c.TIOCSCTTY, @as(c_ulong, 0));

            _ = c.dup2(slave_fd, c.STDIN_FILENO);
            _ = c.dup2(slave_fd, c.STDOUT_FILENO);
            _ = c.dup2(slave_fd, c.STDERR_FILENO);
            if (slave_fd > c.STDERR_FILENO) _ = c.close(slave_fd);

            const c_argv = allocator.alloc(?[*:0]const u8, argv.len + 1) catch c._exit(127);
            defer {
                for (argv, 0..) |_, idx| {
                    if (c_argv[idx]) |ptr| allocator.free(std.mem.span(ptr));
                }
                allocator.free(c_argv);
            }
            for (argv, 0..) |arg, idx| {
                c_argv[idx] = allocator.dupeZ(u8, arg) catch c._exit(127);
            }
            c_argv[argv.len] = null;

            _ = c.execvp(c_argv[0], @ptrCast(c_argv.ptr));
            c._exit(127);
        }

        _ = c.close(slave_fd);
        try setNonBlocking(master_fd);
        return .{ .master_fd = master_fd, .pid = pid };
    }

    fn deinit(self: *ChildSession) void {
        _ = c.close(self.master_fd);
    }
};

fn setNonBlocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return Error.FcntlFailed;
    if (c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return Error.FcntlFailed;
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err == .INTR) continue;
            return std.posix.unexpectedErrno(err);
        }
        offset += @intCast(rc);
    }
}

fn pumpPtyToTty(pty_fd: c_int, tty_fd: c_int) !void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const rc = c.read(pty_fd, &buf, buf.len);
        if (rc == 0) return Error.ChildExited;
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err == .INTR) continue;
            if (err == .AGAIN) return;
            return std.posix.unexpectedErrno(err);
        }
        try writeAll(tty_fd, buf[0..@intCast(rc)]);
    }
}

fn forwardInput(tty_fd: c_int, pty_fd: c_int, hotkey: u8) !bool {
    var buf: [256]u8 = undefined;
    const rc = c.read(tty_fd, &buf, buf.len);
    if (rc == 0) return false;
    if (rc < 0) {
        const err = std.c.errno(rc);
        if (err == .INTR or err == .AGAIN) return false;
        return std.posix.unexpectedErrno(err);
    }

    const n: usize = @intCast(rc);
    const start: usize = 0;
    for (buf[0..n], 0..) |b, idx| {
        if (b == hotkey) {
            if (idx > start) try writeAll(pty_fd, buf[start..idx]);
            if (idx + 1 < n) try writeAll(pty_fd, buf[idx + 1 .. n]);
            return true;
        }
    }

    try writeAll(pty_fd, buf[0..n]);
    return false;
}

fn enterAltScreen(tty_fd: c_int) !void {
    try writeAll(tty_fd, ALT_SCREEN_ENTER);
}

fn leaveAltScreen(tty_fd: c_int) !void {
    try writeAll(tty_fd, ALT_SCREEN_LEAVE);
}

fn runHook(allocator: Allocator, tty_fd: c_int, hook_cmd: []const u8) !void {
    _ = allocator;
    const cmd_z = try std.heap.c_allocator.dupeZ(u8, hook_cmd);
    defer std.heap.c_allocator.free(cmd_z);

    const rc = c.system(cmd_z.ptr);
    if (rc != 0) return Error.HookSpawnFailed;

    // Best effort flush so the caller returns to a clean screen state.
    _ = tty_fd;
}

fn childStillRunning(pid: c.pid_t) bool {
    var status: c_int = 0;
    const rc = c.waitpid(pid, &status, c.WNOHANG);
    return rc == 0;
}

fn passthroughLoop(allocator: Allocator, term: *TerminalState, session: *ChildSession, key: KeyBinding, hook_cmd: []const u8) !void {
    try setNonBlocking(term.tty_fd);

    var pollfds = [_]c.struct_pollfd{
        .{ .fd = term.tty_fd, .events = c.POLLIN, .revents = 0 },
        .{ .fd = session.master_fd, .events = c.POLLIN, .revents = 0 },
    };

    while (true) {
        if (!childStillRunning(session.pid)) return Error.ChildExited;

        const rc = c.poll(&pollfds, pollfds.len, 250);
        if (rc < 0) {
            if (std.c.errno(rc) == .INTR) continue;
            return Error.PollFailed;
        }
        if (rc == 0) continue;

        if ((pollfds[1].revents & c.POLLIN) != 0) {
            try pumpPtyToTty(session.master_fd, term.tty_fd);
        }
        if ((pollfds[1].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            return Error.ChildExited;
        }

        if ((pollfds[0].revents & c.POLLIN) != 0) {
            const intercepted = try forwardInput(term.tty_fd, session.master_fd, key.byte);
            if (intercepted) {
                try term.restore();
                defer term.enableRaw() catch {};

                try enterAltScreen(term.tty_fd);
                defer leaveAltScreen(term.tty_fd) catch {};

                try runHook(allocator, term.tty_fd, hook_cmd);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var cfg = try Config.parse(gpa, init.minimal.args);
    defer cfg.deinit();

    const key = try KeyBinding.parse(cfg.key_spec);

    var term = try TerminalState.init();
    defer term.deinit();
    try term.enableRaw();

    var session = try ChildSession.spawn(gpa, cfg.child_argv, term.tty_fd);
    defer session.deinit();

    passthroughLoop(gpa, &term, &session, key, cfg.run_cmd) catch |err| switch (err) {
        Error.ChildExited => {},
        else => return err,
    };
}

