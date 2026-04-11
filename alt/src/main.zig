const pty_host = @import("host");
const PtyChildHost = pty_host.PtyChildHost;
const SpawnOptions = pty_host.SpawnOptions;
const Size = pty_host.Size;
const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const getTtySize = @import("ptyio_tty_size").getTtySize;
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

const SWITCH_BOUNDARY_RESET = "\x1b[0m\x1b[?25h\x1b[2J\x1b[H";
const DEFAULT_KEY = "ctrl-g";

const Error = error{
    InvalidArgs,
    MissingAlternateCommand,
    MissingPrimaryCommand,
    UnsupportedKeySpec,
    TerminalUnavailable,
    TcGetAttrFailed,
    TcSetAttrFailed,
    IoctlFailed,
    FcntlFailed,
    PollFailed,
    ChildExited,
};

const ActiveSide = enum {
    primary,
    alternate,

    fn toggled(self: ActiveSide) ActiveSide {
        return switch (self) {
            .primary => .alternate,
            .alternate => .primary,
        };
    }
};

const SwitchMode = enum {
    explicit,
    fallback,
};

const LoopDecision = union(enum) {
    stay: ActiveSide,
    switch_to: struct {
        side: ActiveSide,
        mode: SwitchMode,
    },
    exit,
};

const SideConfig = struct {
    allocator: Allocator,
    spawn: SpawnOptions,
};

const SideRuntime = struct {
    config: SideConfig,
    session: PtyChildHost,
    desired_size: ?Size = null,
    input_tx: ByteQueue = ByteQueue.init(),
    output_tx: ByteQueue = ByteQueue.init(),

    fn init(config: SideConfig) !SideRuntime {
        return .{
            .config = config,
            .session = try PtyChildHost.init(config.allocator, config.spawn),
        };
    }

    fn deinit(self: *SideRuntime, allocator: Allocator) void {
        self.input_tx.deinit(allocator);
        self.output_tx.deinit(allocator);
        self.session.deinit();
    }

    fn rebuildSession(self: *SideRuntime) !void {
        self.session.deinit();
        var spawn = self.config.spawn;
        if (self.desired_size) |size| {
            spawn.cols = size.cols;
            spawn.rows = size.rows;
        }
        self.session = try PtyChildHost.init(self.config.allocator, spawn);
    }

    fn restart(self: *SideRuntime, tty_fd: c_int) !void {
        try self.captureDesiredSize(tty_fd);
        try self.rebuildSession();
        self.input_tx.clear();
        self.output_tx.clear();
        try self.session.start();
        try setNonBlockingIfPresent(self.session.masterFd());
    }

    fn masterFd(self: *SideRuntime) Error!c_int {
        return self.session.masterFd() orelse Error.ChildExited;
    }

    fn refreshState(self: *SideRuntime) void {
        self.session.refresh() catch {};
    }

    fn currentState(self: *const SideRuntime) @TypeOf(self.session.currentState()) {
        return self.session.currentState();
    }

    fn isRunning(self: *const SideRuntime) bool {
        return self.currentState() == .running;
    }

    fn captureDesiredSize(self: *SideRuntime, tty_fd: c_int) !void {
        const tty_size = getTtySize(tty_fd) catch return Error.IoctlFailed;
        self.desired_size = .{ .cols = tty_size.cols, .rows = tty_size.rows };
    }

    fn ensureLive(self: *SideRuntime, tty_fd: c_int) !void {
        self.refreshState();
        switch (self.currentState()) {
            .idle => {
                try self.captureDesiredSize(tty_fd);
                try self.rebuildSession();
                try self.session.start();
                try setNonBlockingIfPresent(self.session.masterFd());
            },
            .starting, .running => {},
            .exited, .closed => try self.restart(tty_fd),
        }
    }

    fn syncActivation(self: *SideRuntime, tty_fd: c_int) !void {
        if (!self.isRunning()) return;
        try syncSideWindowSize(tty_fd, self);
    }
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

fn syncWindowSize(tty_fd: c_int, session: *PtyChildHost) !void {
    const size = getTtySize(tty_fd) catch return Error.IoctlFailed;
    try session.resize(size.cols, size.rows);
    try session.signalWinch();
}

const Config = struct {
    allocator: Allocator,
    key_spec: []const u8,
    alternate_path: []const u8,
    signal_1: ?c_int,
    signal_2: ?c_int,
    debug_keys: bool,
    primary_argv: []const []const u8,

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
        var alternate_path: ?[]const u8 = if (c.getenv("ALT_RUN")) |v| std.mem.span(v) else null;
        var signal_1: ?c_int = null;
        var signal_2: ?c_int = null;

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
                alternate_path = args.items[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--signal-1")) {
                i += 1;
                if (i >= args.items.len) return Error.InvalidArgs;
                signal_1 = parseSignalSpec(args.items[i]) orelse return Error.InvalidArgs;
                continue;
            }
            if (std.mem.eql(u8, arg, "--signal-2")) {
                i += 1;
                if (i >= args.items.len) return Error.InvalidArgs;
                signal_2 = parseSignalSpec(args.items[i]) orelse return Error.InvalidArgs;
                continue;
            }
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                return Error.InvalidArgs;
            }
            return Error.InvalidArgs;
        }

        const resolved_alternate_path = alternate_path orelse return Error.MissingAlternateCommand;
        const start = child_start orelse return Error.MissingPrimaryCommand;
        if (start >= args.items.len) return Error.MissingPrimaryCommand;

        const primary_copy = try allocator.alloc([]const u8, args.items.len - start);
        for (args.items[start..], 0..) |arg, idx| primary_copy[idx] = try allocator.dupe(u8, arg);

        return .{
            .allocator = allocator,
            .key_spec = try allocator.dupe(u8, key_spec),
            .alternate_path = try allocator.dupe(u8, resolved_alternate_path),
            .signal_1 = signal_1,
            .signal_2 = signal_2,
            .debug_keys = if (c.getenv("ALT_DEBUG_KEYS")) |v| v[0] != 0 and v[0] != '0' else false,
            .primary_argv = primary_copy,
        };
    }

    fn deinit(self: *Config) void {
        self.allocator.free(self.key_spec);
        self.allocator.free(self.alternate_path);
        for (self.primary_argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.primary_argv);
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

fn setNonBlockingIfPresent(fd: ?c_int) !void {
    if (fd) |real_fd| try setNonBlocking(real_fd);
}

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

fn pumpPtyToQueue(allocator: Allocator, pty_fd: c_int, queue: *ByteQueue) !void {
    while (true) {
        const status = fd_stream.readIntoQueue(allocator, pty_fd, queue, 8192) catch |e| switch (e) {
            fd_stream.Error.IoError => return Error.ChildExited,
            else => return e,
        };
        switch (status) {
            .progress => |n| {
                if (n == 0) return;
                if (n < 8192) return;
            },
            .would_block => return,
            .eof => return Error.ChildExited,
        }
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

const HotkeyAction = union(enum) {
    none,
    signal_active_side,
    switch_to_other_side: struct {
        tail: []u8,
    },

    fn deinit(self: *HotkeyAction, allocator: Allocator) void {
        switch (self.*) {
            .switch_to_other_side => |payload| if (payload.tail.len != 0) allocator.free(payload.tail),
            else => {},
        }
        self.* = .none;
    }
};

const QueueInputResult = struct {
    action: HotkeyAction = .none,

    fn deinit(self: *QueueInputResult, allocator: Allocator) void {
        self.action.deinit(allocator);
        self.* = .{};
    }
};

fn handleInputBytes(allocator: Allocator, bytes: []const u8, queue: *ByteQueue, hotkey: KeyBinding, hotkey_action: HotkeyAction, debug_keys: bool) !QueueInputResult {
    if (bytes.len == 0) return .{};

    if (debug_keys) {
        debugBytes("alt debug: tty bytes=", bytes);
        debugKeySpec("alt debug: hotkey=", hotkey.spec);
    }

    if (decodeInputEvent(bytes)) |event| {
        if (debug_keys) debugKeySpec("alt debug: decoded=", event.spec);
        if (keySpecEq(event.spec, hotkey.spec)) {
            if (debug_keys) std.debug.print("alt debug: hotkey matched\n", .{});
            return .{
                .action = switch (hotkey_action) {
                    .none => .none,
                    .signal_active_side => .signal_active_side,
                    .switch_to_other_side => .{ .switch_to_other_side = .{ .tail = try allocator.dupe(u8, bytes[event.bytes_len..]) } },
                },
            };
        }
    }

    try queue.append(allocator, bytes);
    return .{};
}

fn queueInput(allocator: Allocator, tty_fd: c_int, queue: *ByteQueue, hotkey: KeyBinding, hotkey_action: HotkeyAction, debug_keys: bool) !QueueInputResult {
    var buf: [256]u8 = undefined;
    const rc = c.read(tty_fd, &buf, buf.len);
    if (rc == 0) return .{};
    if (rc < 0) {
        const err = std.c.errno(rc);
        if (err == .INTR or err == .AGAIN) return .{};
        return std.posix.unexpectedErrno(err);
    }

    return handleInputBytes(allocator, buf[0..@intCast(rc)], queue, hotkey, hotkey_action, debug_keys);
}

fn emitSwitchBoundaryReset(tty_fd: c_int) !void {
    try writeAll(tty_fd, SWITCH_BOUNDARY_RESET);
}

fn usage() void {
    std.debug.print(
        "Usage: alt [--key <spec>] --run <path> [--signal-1 <sig>] [--signal-2 <sig>] -- <primary-command...>\n\n" ++
            "Options:\n" ++
            "  --key <spec>   Local hotkey (default: ctrl-g or ALT_KEY)\n" ++
            "  --run <path>   Alternate-side executable to run on its own PTY (or ALT_RUN)\n" ++
            "  --signal-1 <sig>  Signal root child of side 1 when switching away from it\n" ++
            "  --signal-2 <sig>  Signal root child of side 2 when switching away from it\n" ++
            "  -h, --help     Show this help\n" ++
            "\nEnvironment:\n" ++
            "  ALT_DEBUG_KEYS=1  Print raw tty bytes read for hotkey debugging\n",
        .{},
    );
}

fn signalForSide(active: ActiveSide, cfg: Config) ?c_int {
    return switch (active) {
        .primary => cfg.signal_1,
        .alternate => cfg.signal_2,
    };
}

fn maybeSignalSwitchAway(side: *SideRuntime, signal: ?c_int) !void {
    const sig = signal orelse return;
    side.refreshState();
    if (!side.isRunning()) return;
    try side.session.sendSignal(sig);
}

fn refreshSide(side: *SideRuntime) Error!void {
    side.session.refresh() catch return Error.ChildExited;
    if (side.session.currentState() == .exited or side.session.currentState() == .closed) return Error.ChildExited;
}

fn syncSideWindowSize(tty_fd: c_int, side: *SideRuntime) !void {
    try syncWindowSize(tty_fd, &side.session);
}

fn handleResizeIfPending(tty_fd: c_int, primary: *SideRuntime, alternate: *SideRuntime) !void {
    if (!ResizeState.pending) return;
    ResizeState.pending = false;
    try primary.captureDesiredSize(tty_fd);
    try alternate.captureDesiredSize(tty_fd);
    if (primary.isRunning()) try syncSideWindowSize(tty_fd, primary);
    if (alternate.isRunning()) try syncSideWindowSize(tty_fd, alternate);
}

fn activeSidePtr(active: ActiveSide, primary: *SideRuntime, alternate: *SideRuntime) *SideRuntime {
    return switch (active) {
        .primary => primary,
        .alternate => alternate,
    };
}

fn flushActiveOutput(term: *TerminalState, active: *SideRuntime) !void {
    if (active.output_tx.isEmpty()) return;
    _ = fd_stream.writeFromQueue(term.tty_fd, &active.output_tx, 64 * 1024) catch |e| switch (e) {
        fd_stream.Error.IoError => return Error.ChildExited,
        else => return e,
    };
}

fn flushSideInput(side: *SideRuntime) !void {
    if (side.input_tx.isEmpty()) return;
    _ = fd_stream.writeFromQueue(try side.masterFd(), &side.input_tx, 64 * 1024) catch |e| switch (e) {
        fd_stream.Error.IoError => return Error.ChildExited,
        else => return e,
    };
}

fn readSideOutput(allocator: Allocator, side: *SideRuntime) !void {
    try pumpPtyToQueue(allocator, try side.masterFd(), &side.output_tx);
}

fn discardInactiveOutput(side: *SideRuntime) void {
    side.output_tx.clear();
}

fn activateSide(term: *TerminalState, cfg: Config, next: ActiveSide, active: *ActiveSide, primary: *SideRuntime, alternate: *SideRuntime, mode: SwitchMode) !bool {
    const previous_side = activeSidePtr(active.*, primary, alternate);
    const next_side = activeSidePtr(next, primary, alternate);
    try maybeSignalSwitchAway(previous_side, signalForSide(active.*, cfg));
    previous_side.output_tx.clear();
    if (mode == .explicit) {
        try next_side.ensureLive(term.tty_fd);
    } else {
        next_side.refreshState();
        if (!next_side.isRunning()) return false;
    }
    try next_side.syncActivation(term.tty_fd);
    try emitSwitchBoundaryReset(term.tty_fd);
    active.* = next;
    next_side.output_tx.clear();
    return true;
}

fn decideLoopState(active: ActiveSide, primary_running: bool, alternate_running: bool, requested: ?ActiveSide) LoopDecision {
    if (requested) |target| {
        if (target == active) return .{ .stay = active };
        return .{ .switch_to = .{ .side = target, .mode = .explicit } };
    }

    const active_running = switch (active) {
        .primary => primary_running,
        .alternate => alternate_running,
    };
    if (active_running) return .{ .stay = active };

    const fallback = active.toggled();
    const fallback_running = switch (fallback) {
        .primary => primary_running,
        .alternate => alternate_running,
    };
    if (fallback_running) return .{ .switch_to = .{ .side = fallback, .mode = .fallback } };
    return .exit;
}

fn applyLoopDecision(term: *TerminalState, cfg: Config, active: *ActiveSide, primary: *SideRuntime, alternate: *SideRuntime, decision: LoopDecision) !bool {
    switch (decision) {
        .stay => return false,
        .switch_to => |switch_to| {
            const switched = try activateSide(term, cfg, switch_to.side, active, primary, alternate, switch_to.mode);
            return !switched and switch_to.mode == .fallback;
        },
        .exit => return true,
    }
}

fn refreshLoopState(term: *TerminalState, cfg: Config, active: *ActiveSide, primary: *SideRuntime, alternate: *SideRuntime) !bool {
    refreshSide(primary) catch |err| switch (err) {
        Error.ChildExited => {},
        else => return err,
    };
    refreshSide(alternate) catch |err| switch (err) {
        Error.ChildExited => {},
        else => return err,
    };
    return applyLoopDecision(term, cfg, active, primary, alternate, decideLoopState(active.*, primary.isRunning(), alternate.isRunning(), null));
}

fn passthroughLoop(allocator: Allocator, term: *TerminalState, cfg: Config, primary: *SideRuntime, alternate: *SideRuntime, key: KeyBinding, debug_keys: bool) !void {
    try setNonBlocking(term.tty_fd);
    try setNonBlockingIfPresent(primary.session.masterFd());
    try setNonBlockingIfPresent(alternate.session.masterFd());
    installSigwinchHandler();

    var active: ActiveSide = .primary;
    var pollfds = [_]c.struct_pollfd{
        .{ .fd = term.tty_fd, .events = 0, .revents = 0 },
        .{ .fd = -1, .events = 0, .revents = 0 },
        .{ .fd = -1, .events = 0, .revents = 0 },
    };

    while (true) {
        if (try refreshLoopState(term, cfg, &active, primary, alternate)) return;
        try handleResizeIfPending(term.tty_fd, primary, alternate);

        const poll_active = activeSidePtr(active, primary, alternate);

        pollfds[0] = .{ .fd = term.tty_fd, .events = c.POLLIN, .revents = 0 };
        if (!poll_active.output_tx.isEmpty()) pollfds[0].events |= c.POLLOUT;

        pollfds[1] = .{ .fd = if (primary.isRunning()) try primary.masterFd() else -1, .events = 0, .revents = 0 };
        if (primary.isRunning()) {
            pollfds[1].events = c.POLLIN;
            if (!primary.input_tx.isEmpty()) pollfds[1].events |= c.POLLOUT;
        }

        pollfds[2] = .{ .fd = if (alternate.isRunning()) try alternate.masterFd() else -1, .events = 0, .revents = 0 };
        if (alternate.isRunning()) {
            pollfds[2].events = c.POLLIN;
            if (!alternate.input_tx.isEmpty()) pollfds[2].events |= c.POLLOUT;
        }

        const rc = c.poll(&pollfds, pollfds.len, 250);
        if (rc < 0) {
            if (std.c.errno(rc) == .INTR) continue;
            return Error.PollFailed;
        }
        if (rc == 0) continue;

        try handleResizeIfPending(term.tty_fd, primary, alternate);

        if ((pollfds[1].revents & c.POLLIN) != 0) {
            try readSideOutput(allocator, primary);
            if (active != .primary) discardInactiveOutput(primary);
        }
        if ((pollfds[2].revents & c.POLLIN) != 0) {
            try readSideOutput(allocator, alternate);
            if (active != .alternate) discardInactiveOutput(alternate);
        }
        if ((pollfds[1].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            refreshSide(primary) catch |err| switch (err) {
                Error.ChildExited => {},
                else => return err,
            };
        }
        if ((pollfds[2].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            refreshSide(alternate) catch |err| switch (err) {
                Error.ChildExited => {},
                else => return err,
            };
        }

        if ((pollfds[0].revents & c.POLLIN) != 0) {
            const current_side = activeSidePtr(active, primary, alternate);
            const hotkey_action: HotkeyAction = if (signalForSide(active, cfg) != null)
                .signal_active_side
            else
                .{ .switch_to_other_side = .{ .tail = &.{} } };
            var input = try queueInput(allocator, term.tty_fd, &current_side.input_tx, key, hotkey_action, debug_keys);
            defer input.deinit(allocator);
            switch (input.action) {
                .none => {},
                .signal_active_side => {
                    try maybeSignalSwitchAway(current_side, signalForSide(active, cfg));
                    if (try refreshLoopState(term, cfg, &active, primary, alternate)) return;
                    continue;
                },
                .switch_to_other_side => |payload| {
                    _ = try activateSide(term, cfg, active.toggled(), &active, primary, alternate, .explicit);
                    if (payload.tail.len != 0) {
                        try activeSidePtr(active, primary, alternate).input_tx.append(allocator, payload.tail);
                    }
                },
            }
        }

        const flush_active = activeSidePtr(active, primary, alternate);
        if (primary.isRunning() and ((pollfds[1].revents & c.POLLOUT) != 0 or active == .primary)) try flushSideInput(primary);
        if (alternate.isRunning() and ((pollfds[2].revents & c.POLLOUT) != 0 or active == .alternate)) try flushSideInput(alternate);
        if ((pollfds[0].revents & c.POLLOUT) != 0 or !flush_active.output_tx.isEmpty()) try flushActiveOutput(term, flush_active);

        if (try refreshLoopState(term, cfg, &active, primary, alternate)) return;
    }
}

test "decideLoopState falls back symmetrically when active side exits" {
    try std.testing.expectEqual(LoopDecision{ .switch_to = .{ .side = .alternate, .mode = .fallback } }, decideLoopState(.primary, false, true, null));
    try std.testing.expectEqual(LoopDecision{ .switch_to = .{ .side = .primary, .mode = .fallback } }, decideLoopState(.alternate, true, false, null));
}

test "decideLoopState exits when neither side is running" {
    try std.testing.expectEqual(LoopDecision.exit, decideLoopState(.primary, false, false, null));
    try std.testing.expectEqual(LoopDecision.exit, decideLoopState(.alternate, false, false, null));
}

test "decideLoopState restarts exited target on explicit toggle" {
    try std.testing.expectEqual(LoopDecision{ .switch_to = .{ .side = .alternate, .mode = .explicit } }, decideLoopState(.primary, true, false, .alternate));
    try std.testing.expectEqual(LoopDecision{ .switch_to = .{ .side = .primary, .mode = .explicit } }, decideLoopState(.alternate, false, true, .primary));
}

test "decideLoopState allows toggling into an unstarted side" {
    try std.testing.expectEqual(LoopDecision{ .switch_to = .{ .side = .alternate, .mode = .explicit } }, decideLoopState(.primary, true, false, .alternate));
}

test "handleInputBytes returns switch action and preserves tail for deliberate reroute" {
    var queue = ByteQueue.init();
    defer queue.deinit(std.testing.allocator);

    const hotkey: KeyBinding = .{ .spec = .{ .kind = .char, .ch = 'g', .mods = .{ .ctrl = true } } };
    var result = try handleInputBytes(std.testing.allocator, &[_]u8{ 0x07, 'x', 'y' }, &queue, hotkey, .{ .switch_to_other_side = .{ .tail = &.{} } }, false);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(queue.isEmpty());
    switch (result.action) {
        .switch_to_other_side => |payload| try std.testing.expectEqualStrings("xy", payload.tail),
        else => return error.TestUnexpectedResult,
    }
}

test "handleInputBytes returns signal action without reroute tail" {
    var queue = ByteQueue.init();
    defer queue.deinit(std.testing.allocator);

    const hotkey: KeyBinding = .{ .spec = .{ .kind = .char, .ch = 'g', .mods = .{ .ctrl = true } } };
    var result = try handleInputBytes(std.testing.allocator, &[_]u8{0x07}, &queue, hotkey, .signal_active_side, false);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(HotkeyAction.signal_active_side, result.action);
}

test "handleInputBytes forwards non-hotkey bytes unchanged" {
    var queue = ByteQueue.init();
    defer queue.deinit(std.testing.allocator);

    const hotkey: KeyBinding = .{ .spec = .{ .kind = .char, .ch = 'g', .mods = .{ .ctrl = true } } };
    var result = try handleInputBytes(std.testing.allocator, "abc", &queue, hotkey, .none, false);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(HotkeyAction.none, result.action);
    try std.testing.expectEqualStrings("abc", queue.readableSlice());
}

test "signalForSide follows configured per-side signal" {
    const cfg: Config = .{
        .allocator = std.testing.allocator,
        .key_spec = "ctrl-g",
        .alternate_path = "/bin/true",
        .signal_1 = c.SIGTERM,
        .signal_2 = null,
        .debug_keys = false,
        .primary_argv = &.{"/bin/sh"},
    };

    try std.testing.expectEqual(@as(?c_int, c.SIGTERM), signalForSide(.primary, cfg));
    try std.testing.expectEqual(@as(?c_int, null), signalForSide(.alternate, cfg));
}

fn parseSignalSpec(spec: []const u8) ?c_int {
    if (spec.len == 0) return null;
    const numeric = std.fmt.parseInt(c_int, spec, 10) catch null;
    if (numeric) |sig| return if (sig > 0) sig else null;

    var buf: [16]u8 = undefined;
    var rest = spec;
    if (std.ascii.startsWithIgnoreCase(rest, "SIG")) rest = rest[3..];
    if (rest.len == 0 or rest.len > buf.len) return null;
    for (rest, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    const upper = buf[0..rest.len];

    if (std.mem.eql(u8, upper, "HUP")) return c.SIGHUP;
    if (std.mem.eql(u8, upper, "INT")) return c.SIGINT;
    if (std.mem.eql(u8, upper, "QUIT")) return c.SIGQUIT;
    if (std.mem.eql(u8, upper, "KILL")) return c.SIGKILL;
    if (std.mem.eql(u8, upper, "TERM")) return c.SIGTERM;
    if (std.mem.eql(u8, upper, "USR1")) return c.SIGUSR1;
    if (std.mem.eql(u8, upper, "USR2")) return c.SIGUSR2;
    if (std.mem.eql(u8, upper, "STOP")) return c.SIGSTOP;
    if (std.mem.eql(u8, upper, "CONT")) return c.SIGCONT;
    if (std.mem.eql(u8, upper, "WINCH")) return c.SIGWINCH;
    return null;
}

test "switch boundary reset sequence is explicit and ordered" {
    try std.testing.expectEqualStrings("\x1b[0m\x1b[?25h\x1b[2J\x1b[H", SWITCH_BOUNDARY_RESET);
}

test "parseSignalSpec accepts common names and numbers" {
    try std.testing.expectEqual(@as(?c_int, c.SIGTERM), parseSignalSpec("TERM"));
    try std.testing.expectEqual(@as(?c_int, c.SIGINT), parseSignalSpec("sigint"));
    try std.testing.expectEqual(@as(?c_int, c.SIGUSR1), parseSignalSpec("USR1"));
    try std.testing.expectEqual(@as(?c_int, 9), parseSignalSpec("9"));
}

test "parseSignalSpec rejects empty and unknown values" {
    try std.testing.expectEqual(@as(?c_int, null), parseSignalSpec(""));
    try std.testing.expectEqual(@as(?c_int, null), parseSignalSpec("0"));
    try std.testing.expectEqual(@as(?c_int, null), parseSignalSpec("NOPE"));
}

test "switch-away signal leaves refreshed session state authoritative" {
    var side = try SideRuntime.init(.{
        .allocator = std.testing.allocator,
        .spawn = .{ .argv = &.{ "/bin/sh", "-c", "trap '' TERM; sleep 5" } },
    });
    defer side.deinit(std.testing.allocator);

    try side.session.start();
    try maybeSignalSwitchAway(&side, c.SIGTERM);
    side.refreshState();
    try std.testing.expectEqual(pty_host.HostState.running, side.currentState());
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
        Error.MissingAlternateCommand, Error.MissingPrimaryCommand => {
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

    const size = getTtySize(term.tty_fd) catch return Error.IoctlFailed;
    var primary = try SideRuntime.init(.{
        .allocator = gpa,
        .spawn = .{
            .argv = cfg.primary_argv,
            .cols = size.cols,
            .rows = size.rows,
        },
    });
    primary.desired_size = .{ .cols = size.cols, .rows = size.rows };
    defer primary.deinit(gpa);
    try primary.session.start();
    try setNonBlockingIfPresent(primary.session.masterFd());

    const alternate_argv = [_][]const u8{cfg.alternate_path};
    var alternate = try SideRuntime.init(.{
        .allocator = gpa,
        .spawn = .{
            .argv = &alternate_argv,
            .cols = size.cols,
            .rows = size.rows,
        },
    });
    alternate.desired_size = .{ .cols = size.cols, .rows = size.rows };
    defer alternate.deinit(gpa);

    passthroughLoop(gpa, &term, cfg, &primary, &alternate, key, cfg.debug_keys) catch |err| switch (err) {
        Error.ChildExited => {},
        else => return err,
    };
}
