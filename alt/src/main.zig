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

const Error = error{
    InvalidArgs,
    MissingHookCommand,
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

const HookResult = union(enum) {
    ok,
    exec_failed,
    exited: u8,
    signaled: c_int,
};

const ResizeState = struct {
    var pending: bool = false;
};

fn handleSigwinch(_: c_int) callconv(.c) void {
    ResizeState.pending = true;
}

fn installSigwinchHandler() void {
    _ = c.signal(c.SIGWINCH, handleSigwinch);
}

fn syncWindowSize(tty_fd: c_int, pty_fd: c_int, child_pid: c.pid_t) !void {
    var win: c.struct_winsize = undefined;
    if (c.ioctl(tty_fd, c.TIOCGWINSZ, &win) != 0) return Error.IoctlFailed;
    if (c.ioctl(pty_fd, c.TIOCSWINSZ, &win) != 0) return Error.IoctlFailed;
    _ = c.kill(-child_pid, c.SIGWINCH);
}

const Config = struct {
    allocator: Allocator,
    key_spec: []const u8,
    hook_path: []const u8,
    debug_keys: bool,
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
        var hook_path: ?[]const u8 = if (c.getenv("ALT_RUN")) |v| std.mem.span(v) else null;

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
                hook_path = args.items[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                return Error.InvalidArgs;
            }
            return Error.InvalidArgs;
        }

        const resolved_hook_path = hook_path orelse return Error.MissingHookCommand;
        const start = child_start orelse return Error.MissingChildCommand;
        if (start >= args.items.len) return Error.MissingChildCommand;

        const child_copy = try allocator.alloc([]const u8, args.items.len - start);
        for (args.items[start..], 0..) |arg, idx| child_copy[idx] = try allocator.dupe(u8, arg);

        return .{
            .allocator = allocator,
            .key_spec = try allocator.dupe(u8, key_spec),
            .hook_path = try allocator.dupe(u8, resolved_hook_path),
            .debug_keys = if (c.getenv("ALT_DEBUG_KEYS")) |v| v[0] != 0 and v[0] != '0' else false,
            .child_argv = child_copy,
        };
    }

    fn deinit(self: *Config) void {
        self.allocator.free(self.key_spec);
        self.allocator.free(self.hook_path);
        for (self.child_argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.child_argv);
    }
};

const Modifiers = packed struct(u8) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    _pad: u5 = 0,
};

const KeyKind = enum {
    char,
};

const KeySpec = struct {
    kind: KeyKind,
    ch: u8,
    mods: Modifiers = .{},
};

const KeyBinding = struct {
    spec: KeySpec,

    fn parse(spec: []const u8) !KeyBinding {
        if (spec.len == 6 and std.ascii.startsWithIgnoreCase(spec, "ctrl-")) {
            const tail = std.ascii.toLower(spec[5]);
            if (tail >= 'a' and tail <= 'z') {
                return .{ .spec = .{ .kind = .char, .ch = tail, .mods = .{ .ctrl = true } } };
            }
        }
        if (spec.len == 1) return .{ .spec = .{ .kind = .char, .ch = spec[0] } };
        if (spec.len == 3 and spec[0] == '\'' and spec[2] == '\'') return .{ .spec = .{ .kind = .char, .ch = spec[1] } };
        return Error.UnsupportedKeySpec;
    }
};

const KeyEvent = struct {
    spec: KeySpec,
    bytes_len: usize,
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
            switch (err) {
                .INTR => continue,
                .AGAIN => {
                    var pfd = c.struct_pollfd{
                        .fd = fd,
                        .events = c.POLLOUT,
                        .revents = 0,
                    };
                    while (true) {
                        const prc = c.poll(&pfd, 1, -1);
                        if (prc < 0) {
                            if (std.c.errno(prc) == .INTR) continue;
                            return Error.PollFailed;
                        }
                        break;
                    }
                    continue;
                },
                else => return std.posix.unexpectedErrno(err),
            }
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
            if (err == .IO) return Error.ChildExited;
            return std.posix.unexpectedErrno(err);
        }
        try writeAll(tty_fd, buf[0..@intCast(rc)]);
    }
}

fn debugBytes(prefix: []const u8, bytes: []const u8) void {
    std.debug.print("{s}", .{prefix});
    for (bytes, 0..) |b, idx| {
        if (idx != 0) std.debug.print(" ", .{});
        std.debug.print("0x{X:0>2}", .{b});
    }
    std.debug.print("\n", .{});
}

fn debugKeySpec(prefix: []const u8, spec: KeySpec) void {
    std.debug.print("{s}kind={s} ch=0x{X:0>2} mods(ctrl={}, alt={}, shift={})\n", .{
        prefix,
        @tagName(spec.kind),
        spec.ch,
        spec.mods.ctrl,
        spec.mods.alt,
        spec.mods.shift,
    });
}

fn parseDecimal(bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;
    var value: u32 = 0;
    for (bytes) |b| {
        if (b < '0' or b > '9') return null;
        value = value * 10 + (b - '0');
    }
    return value;
}

fn decodeCsiU(seq: []const u8) ?KeyEvent {
    if (seq.len < 6) return null;
    if (!(seq[0] == 0x1b and seq[1] == '[' and seq[seq.len - 1] == '~')) return null;

    var parts_it = std.mem.splitScalar(u8, seq[2 .. seq.len - 1], ';');
    const p1 = parts_it.next() orelse return null;
    const p2 = parts_it.next() orelse return null;
    const p3 = parts_it.next() orelse return null;
    if (parts_it.next() != null) return null;
    if (!std.mem.eql(u8, p1, "27")) return null;
    if (!std.mem.eql(u8, p2, "5")) return null;

    const key_code = parseDecimal(p3) orelse return null;
    if (key_code < 1 or key_code > 255) return null;
    var ch: u8 = @intCast(key_code);
    var mods: Modifiers = .{ .ctrl = true };

    if (ch >= 'A' and ch <= 'Z') {
        ch = std.ascii.toLower(ch);
        mods.shift = true;
    }

    return .{ .spec = .{ .kind = .char, .ch = ch, .mods = mods }, .bytes_len = seq.len };
}

fn decodeInputEvent(bytes: []const u8) ?KeyEvent {
    if (bytes.len == 0) return null;

    if (decodeCsiU(bytes)) |event| return event;

    const b = bytes[0];
    if (b >= 0x01 and b <= 0x1a) {
        return .{ .spec = .{ .kind = .char, .ch = 'a' + (b - 1), .mods = .{ .ctrl = true } }, .bytes_len = 1 };
    }

    if (b >= 'A' and b <= 'Z') {
        return .{ .spec = .{ .kind = .char, .ch = std.ascii.toLower(b), .mods = .{ .shift = true } }, .bytes_len = 1 };
    }

    return .{ .spec = .{ .kind = .char, .ch = b }, .bytes_len = 1 };
}

fn keySpecEq(a: KeySpec, b: KeySpec) bool {
    return a.kind == b.kind and a.ch == b.ch and a.mods.ctrl == b.mods.ctrl and a.mods.alt == b.mods.alt and a.mods.shift == b.mods.shift;
}

fn forwardInput(tty_fd: c_int, pty_fd: c_int, hotkey: KeyBinding, debug_keys: bool) !bool {
    var buf: [256]u8 = undefined;
    const rc = c.read(tty_fd, &buf, buf.len);
    if (rc == 0) return false;
    if (rc < 0) {
        const err = std.c.errno(rc);
        if (err == .INTR or err == .AGAIN) return false;
        return std.posix.unexpectedErrno(err);
    }

    const n: usize = @intCast(rc);
    if (debug_keys) {
        debugBytes("alt debug: tty bytes=", buf[0..n]);
        debugKeySpec("alt debug: hotkey=", hotkey.spec);
    }

    if (decodeInputEvent(buf[0..n])) |event| {
        if (debug_keys) debugKeySpec("alt debug: decoded=", event.spec);
        if (keySpecEq(event.spec, hotkey.spec)) {
            if (debug_keys) std.debug.print("alt debug: hotkey matched\n", .{});
            if (event.bytes_len < n) try writeAll(pty_fd, buf[event.bytes_len..n]);
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

fn usage() void {
    std.debug.print(
        "Usage: alt [--key <spec>] --run <path> -- <child-command...>\n\n" ++
            "Options:\n" ++
            "  --key <spec>   Local hotkey (default: ctrl-g or ALT_KEY)\n" ++
            "  --run <path>   Hook executable to run in alternate screen (or ALT_RUN)\n" ++
            "  -h, --help     Show this help\n" ++
            "\nEnvironment:\n" ++
            "  ALT_DEBUG_KEYS=1  Print raw tty bytes read for hotkey debugging\n",
        .{},
    );
}

fn waitForAnyKey(tty_fd: c_int) void {
    var buf: [32]u8 = undefined;
    while (true) {
        const rc = c.read(tty_fd, &buf, buf.len);
        if (rc > 0) return;
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err == .INTR or err == .AGAIN) continue;
            return;
        }
    }
}

fn showHookError(tty_fd: c_int, hook_path: []const u8, result: HookResult) void {
    switch (result) {
        .exec_failed => {
            std.debug.print("\r\nalt: hook executable not found or not executable: {s}\r\n", .{hook_path});
        },
        .exited => return,
        .signaled => |sig| {
            std.debug.print("\r\nalt: hook terminated by signal {d}: {s}\r\n", .{ sig, hook_path });
        },
        .ok => return,
    }
    std.debug.print("alt: press any key to return\r\n", .{});
    waitForAnyKey(tty_fd);
}

fn runHook(allocator: Allocator, tty_fd: c_int, hook_path: []const u8) !void {
    const pid = c.fork();
    if (pid < 0) return Error.HookSpawnFailed;

    if (pid == 0) {
        const hook_z = allocator.dupeZ(u8, hook_path) catch c._exit(127);
        const argv = allocator.alloc(?[*:0]const u8, 2) catch c._exit(127);
        argv[0] = hook_z;
        argv[1] = null;
        _ = c.execvp(argv[0], @ptrCast(argv.ptr));
        c._exit(127);
    }

    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, 0);
        if (rc < 0) {
            if (std.c.errno(rc) == .INTR) continue;
            return Error.HookSpawnFailed;
        }
        break;
    }

    const result: HookResult = if (c.WIFEXITED(status)) blk: {
        const code = c.WEXITSTATUS(status);
        if (code == 0) break :blk .ok;
        if (code == 127) break :blk .exec_failed;
        break :blk .{ .exited = @intCast(code) };
    } else if (c.WIFSIGNALED(status)) .{ .signaled = c.WTERMSIG(status) } else .exec_failed;

    showHookError(tty_fd, hook_path, result);
}

fn childStillRunning(pid: c.pid_t) bool {
    var status: c_int = 0;
    const rc = c.waitpid(pid, &status, c.WNOHANG);
    return rc == 0;
}

fn passthroughLoop(allocator: Allocator, term: *TerminalState, session: *ChildSession, key: KeyBinding, hook_path: []const u8, debug_keys: bool) !void {
    try setNonBlocking(term.tty_fd);
    installSigwinchHandler();

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
        if (rc == 0) {
            if (ResizeState.pending) {
                ResizeState.pending = false;
                try syncWindowSize(term.tty_fd, session.master_fd, session.pid);
            }
            continue;
        }

        if (ResizeState.pending) {
            ResizeState.pending = false;
            try syncWindowSize(term.tty_fd, session.master_fd, session.pid);
        }

        if ((pollfds[1].revents & c.POLLIN) != 0) {
            try pumpPtyToTty(session.master_fd, term.tty_fd);
        }
        if ((pollfds[1].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            return Error.ChildExited;
        }

        if ((pollfds[0].revents & c.POLLIN) != 0) {
            const intercepted = try forwardInput(term.tty_fd, session.master_fd, key, debug_keys);
            if (intercepted) {
                try term.restore();
                defer term.enableRaw() catch {};

                try enterAltScreen(term.tty_fd);
                defer leaveAltScreen(term.tty_fd) catch {};

                try runHook(allocator, term.tty_fd, hook_path);
                try syncWindowSize(term.tty_fd, session.master_fd, session.pid);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    var argc: usize = 0;
    while (args_it.next()) |_| argc += 1;
    if (argc <= 1) {
        usage();
        return;
    }

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var cfg = Config.parse(gpa, init.minimal.args) catch |err| switch (err) {
        Error.InvalidArgs => {
            usage();
            return err;
        },
        Error.MissingHookCommand, Error.MissingChildCommand => {
            usage();
            return err;
        },
        else => return err,
    };
    defer cfg.deinit();

    const key = try KeyBinding.parse(cfg.key_spec);

    var term = try TerminalState.init();
    defer term.deinit();
    try term.enableRaw();

    var session = try ChildSession.spawn(gpa, cfg.child_argv, term.tty_fd);
    defer session.deinit();

    passthroughLoop(gpa, &term, &session, key, cfg.hook_path, cfg.debug_keys) catch |err| switch (err) {
        Error.ChildExited => {},
        else => return err,
    };
}

