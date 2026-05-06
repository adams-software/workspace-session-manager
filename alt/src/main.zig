const alt_control = @import("alt_control.zig");
const pty_host = @import("host");
const PtyChildHost = pty_host.PtyChildHost;
const SpawnOptions = pty_host.SpawnOptions;
const Size = pty_host.Size;
const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const getTtySize = @import("ptyio_tty_size").getTtySize;
const argv_parse = @import("argv_parse");
const ctlwire = @import("ctlwire");
const std = @import("std");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

const Allocator = std.mem.Allocator;
const SWITCH_BOUNDARY_RESET = "\x1b[0m\x1b[?25h\x1b[2J\x1b[H";

const Error = error{
    InvalidArgs,
    ShowHelp,
    MissingControlPath,
    MissingAlternateCommand,
    MissingPrimaryCommand,
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

    fn index(self: ActiveSide) usize {
        return switch (self) {
            .primary => 0,
            .alternate => 1,
        };
    }

    fn fromIndex(side_index: usize) ?ActiveSide {
        return switch (side_index) {
            0 => .primary,
            1 => .alternate,
            else => null,
        };
    }
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

const ResizeState = struct { var pending: bool = false; };

fn handleSigwinch(_: c_int) callconv(.c) void {
    ResizeState.pending = true;
}

fn installSigwinchHandler() void {
    _ = c.signal(c.SIGWINCH, handleSigwinch);
}

fn findRawOptionValue(args: []const []const u8, aliases: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) break;
        for (aliases) |alias| {
            if (std.mem.startsWith(u8, arg, "--")) {
                const body = arg[2..];
                if (std.mem.eql(u8, body, alias)) {
                    if (i + 1 >= args.len) return null;
                    const next = args[i + 1];
                    if (std.mem.eql(u8, next, "--")) return null;
                    return next;
                }
                if (body.len > alias.len and body[alias.len] == '=' and std.mem.eql(u8, body[0..alias.len], alias)) {
                    return body[(alias.len + 1)..];
                }
            }
            if (alias.len == 1 and arg.len == 2 and arg[0] == '-' and arg[1] == alias[0]) {
                if (i + 1 >= args.len) return null;
                const next = args[i + 1];
                if (std.mem.eql(u8, next, "--")) return null;
                return next;
            }
        }
    }
    return null;
}

const Config = struct {
    allocator: Allocator,
    control_path: []const u8,
    alternate_path: []const u8,
    signal_1: ?c_int,
    signal_2: ?c_int,
    primary_argv: []const []const u8,

    fn parse(allocator: Allocator, args_src: []const []const u8) !Config {
        const args = if (args_src.len > 1) args_src[1..] else &.{};
        const parsed = try argv_parse.parseArgv(allocator, args);
        defer allocator.free(parsed.options);
        defer allocator.free(parsed.positionals);
        defer if (parsed.literal_tail) |tail| allocator.free(tail);

        if (argv_parse.hasOption(parsed, &.{ "h", "help" })) return Error.ShowHelp;

        const resolved_control = findRawOptionValue(args, &.{ "control" }) orelse return Error.MissingControlPath;
        const resolved_alternate = findRawOptionValue(args, &.{ "run" }) orelse return Error.MissingAlternateCommand;

        const signal_1 = if (findRawOptionValue(args, &.{ "signal-1" })) |value|
            parseSignalSpec(value) orelse return Error.InvalidArgs
        else
            null;
        const signal_2 = if (findRawOptionValue(args, &.{ "signal-2" })) |value|
            parseSignalSpec(value) orelse return Error.InvalidArgs
        else
            null;

        const tail = parsed.literal_tail orelse return Error.MissingPrimaryCommand;
        if (tail.len == 0) return Error.MissingPrimaryCommand;
        const primary_copy = try allocator.alloc([]const u8, tail.len);
        for (tail, 0..) |arg, idx| primary_copy[idx] = try allocator.dupe(u8, arg);

        return .{
            .allocator = allocator,
            .control_path = try allocator.dupe(u8, resolved_control),
            .alternate_path = try allocator.dupe(u8, resolved_alternate),
            .signal_1 = signal_1,
            .signal_2 = signal_2,
            .primary_argv = primary_copy,
        };
    }

    fn deinit(self: *Config) void {
        self.allocator.free(self.control_path);
        self.allocator.free(self.alternate_path);
        for (self.primary_argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.primary_argv);
    }
};

const ControlServer = struct {
    allocator: Allocator,
    listener_fd: c_int,
    socket_path: []u8,
    client_fd: ?c_int = null,
    rx: ByteQueue = ByteQueue.init(),

    fn init(allocator: Allocator, socket_path: []const u8) !ControlServer {
        const fd = try createListener(socket_path);
        return .{
            .allocator = allocator,
            .listener_fd = fd,
            .socket_path = try allocator.dupe(u8, socket_path),
        };
    }

    fn deinit(self: *ControlServer) void {
        if (self.client_fd) |fd| _ = c.close(fd);
        _ = c.close(self.listener_fd);
        unlinkBestEffort(self.socket_path);
        self.allocator.free(self.socket_path);
        self.rx.deinit(self.allocator);
    }
};

fn setNonBlockingIfPresent(fd: ?c_int) !void { if (fd) |real_fd| try setNonBlocking(real_fd); }
fn setNonBlocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return Error.FcntlFailed;
    if (c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return Error.FcntlFailed;
}

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
        return .{ .tty_fd = tty_fd, .original = term };
    }
    fn deinit(self: *TerminalState) void { if (self.raw_enabled) self.restore() catch {}; _ = c.close(self.tty_fd); }
    fn enableRaw(self: *TerminalState) !void { var raw = self.original; c.cfmakeraw(&raw); if (c.tcsetattr(self.tty_fd, c.TCSAFLUSH, &raw) != 0) return Error.TcSetAttrFailed; self.raw_enabled = true; }
    fn restore(self: *TerminalState) !void { if (c.tcsetattr(self.tty_fd, c.TCSAFLUSH, &self.original) != 0) return Error.TcSetAttrFailed; self.raw_enabled = false; }
};

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc < 0) {
            const err = std.posix.errno(rc);
            if (err == .INTR or err == .AGAIN) continue;
            return std.posix.unexpectedErrno(err);
        }
        offset += @intCast(rc);
    }
}

fn usage() void {
    std.fs.File.stderr().writeAll(
        "Usage: alt --control <path> --run <path> [--signal-1 <sig>] [--signal-2 <sig>] -- <primary-command...>\n\n" ++
        "Control commands: help, state, switch <index>, cycle, exit\n",
    ) catch {};
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
    if (std.mem.eql(u8, upper, "TERM")) return c.SIGTERM;
    if (std.mem.eql(u8, upper, "KILL")) return c.SIGKILL;
    if (std.mem.eql(u8, upper, "INT")) return c.SIGINT;
    return null;
}

fn signalForSide(active: ActiveSide, cfg: Config) ?c_int { return switch (active) { .primary => cfg.signal_1, .alternate => cfg.signal_2 }; }
fn maybeSignalSwitchAway(side: *SideRuntime, signal: ?c_int) !void { const sig = signal orelse return; side.refreshState(); if (!side.isRunning()) return; try side.session.sendSignal(sig); }
fn syncWindowSize(tty_fd: c_int, session: *PtyChildHost) !void { const size = getTtySize(tty_fd) catch return Error.IoctlFailed; try session.resize(size.cols, size.rows); try session.signalWinch(); }
fn syncSideWindowSize(tty_fd: c_int, side: *SideRuntime) !void { try syncWindowSize(tty_fd, &side.session); }
fn handleResizeIfPending(tty_fd: c_int, primary: *SideRuntime, alternate: *SideRuntime) !void { if (!ResizeState.pending) return; ResizeState.pending = false; try primary.captureDesiredSize(tty_fd); try alternate.captureDesiredSize(tty_fd); if (primary.isRunning()) try syncSideWindowSize(tty_fd, primary); if (alternate.isRunning()) try syncSideWindowSize(tty_fd, alternate); }
fn activeSidePtr(active: ActiveSide, primary: *SideRuntime, alternate: *SideRuntime) *SideRuntime { return switch (active) { .primary => primary, .alternate => alternate }; }
fn flushActiveOutput(term: *TerminalState, active: *SideRuntime) !void { if (active.output_tx.isEmpty()) return; _ = fd_stream.writeFromQueue(term.tty_fd, &active.output_tx, 64 * 1024) catch |e| switch (e) { fd_stream.Error.IoError => return Error.ChildExited, else => return e, }; }
fn flushSideInput(side: *SideRuntime) !void { if (side.input_tx.isEmpty()) return; _ = fd_stream.writeFromQueue(try side.masterFd(), &side.input_tx, 64 * 1024) catch |e| switch (e) { fd_stream.Error.IoError => return Error.ChildExited, else => return e, }; }
fn discardInactiveOutput(side: *SideRuntime) void { side.output_tx.clear(); }
fn pumpPtyToQueue(allocator: Allocator, pty_fd: c_int, queue: *ByteQueue) !void { while (true) { const status = fd_stream.readIntoQueue(allocator, pty_fd, queue, 8192) catch |e| switch (e) { fd_stream.Error.IoError => return Error.ChildExited, else => return e, }; switch (status) { .progress => |n| { if (n == 0 or n < 8192) return; }, .would_block => return, .eof => return Error.ChildExited, } } }
fn readSideOutput(allocator: Allocator, side: *SideRuntime) !void { try pumpPtyToQueue(allocator, try side.masterFd(), &side.output_tx); }
fn emitSwitchBoundaryReset(tty_fd: c_int) !void { try writeAll(tty_fd, SWITCH_BOUNDARY_RESET); }
fn refreshSide(side: *SideRuntime) Error!void { side.session.refresh() catch return Error.ChildExited; if (side.session.currentState() == .exited or side.session.currentState() == .closed) return Error.ChildExited; }

fn activateSide(term: *TerminalState, cfg: Config, next: ActiveSide, active: *ActiveSide, primary: *SideRuntime, alternate: *SideRuntime) !bool {
    if (next == active.*) return true;
    const previous_side = activeSidePtr(active.*, primary, alternate);
    const next_side = activeSidePtr(next, primary, alternate);
    try maybeSignalSwitchAway(previous_side, signalForSide(active.*, cfg));
    previous_side.output_tx.clear();
    try next_side.ensureLive(term.tty_fd);
    try next_side.syncActivation(term.tty_fd);
    try emitSwitchBoundaryReset(term.tty_fd);
    active.* = next;
    next_side.output_tx.clear();
    return true;
}

fn refreshLoopState(term: *TerminalState, cfg: Config, active: *ActiveSide, primary: *SideRuntime, alternate: *SideRuntime) !bool {
    refreshSide(primary) catch |err| switch (err) { Error.ChildExited => {}, else => return err };
    refreshSide(alternate) catch |err| switch (err) { Error.ChildExited => {}, else => return err };
    const active_running = activeSidePtr(active.*, primary, alternate).isRunning();
    if (active_running) return false;
    const fallback = active.*.toggled();
    if (activeSidePtr(fallback, primary, alternate).isRunning()) {
        _ = try activateSide(term, cfg, fallback, active, primary, alternate);
        return false;
    }
    return true;
}

fn createListener(path: []const u8) !c_int {
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return Error.InvalidArgs;
    if (path.len >= addr.sun_path.len) return Error.InvalidArgs;
    unlinkBestEffort(path);
    if (c.bind(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) return Error.InvalidArgs;
    if (c.listen(fd, 4) != 0) return Error.InvalidArgs;
    try setNonBlocking(fd);
    return fd;
}

fn unlinkBestEffort(path: []const u8) void {
    var buf: [108:0]u8 = [_:0]u8{0} ** 108;
    if (path.len >= 108) return;
    std.mem.copyForwards(u8, buf[0..path.len], path);
    _ = c.unlink(buf[0..path.len :0].ptr);
}

fn stateName(side: *const SideRuntime) []const u8 {
    return switch (side.currentState()) {
        .idle => "idle",
        .starting => "starting",
        .running => "running",
        .exited => "exited",
        .closed => "closed",
    };
}

fn dropControlClient(server: *ControlServer) void {
    if (server.client_fd) |fd| {
        _ = c.close(fd);
        server.client_fd = null;
    }
    server.rx.clear();
}

fn writeCtlLine(fd: c_int, line: []const u8) !void {
    var file = std.fs.File{ .handle = fd };
    var writer = file.writer(&.{});
    try writer.interface.writeAll(line);
}

fn writeCtlOk(fd: c_int) !void {
    var file = std.fs.File{ .handle = fd };
    var writer = file.writer(&.{});
    try ctlwire.message.writeOk(&writer.interface);
}

fn writeCtlOkPayload(fd: c_int, payload: []const u8) !void {
    var file = std.fs.File{ .handle = fd };
    var writer = file.writer(&.{});
    try ctlwire.message.writeOkPayload(&writer.interface, payload);
}

fn writeCtlErr(fd: c_int, kind: []const u8) !void {
    var file = std.fs.File{ .handle = fd };
    var writer = file.writer(&.{});
    try ctlwire.message.writeErr(&writer.interface, .{ .kind = kind });
}

fn handleControlServer(server: *ControlServer, active: *ActiveSide, should_exit: *bool, term: *TerminalState, cfg: Config, primary: *SideRuntime, alternate: *SideRuntime) !void {
    if (server.client_fd == null) {
        const fd = c.accept(server.listener_fd, null, null);
        if (fd >= 0) {
            try setNonBlocking(fd);
            server.client_fd = fd;
            server.rx.clear();
        }
    }
    const client_fd = server.client_fd orelse return;
    var buf: [512]u8 = undefined;
    const rc = c.read(client_fd, &buf, buf.len);
    if (rc == 0) {
        dropControlClient(server);
        return;
    }
    if (rc < 0) {
        const err = std.posix.errno(rc);
        if (err == .INTR or err == .AGAIN) return;
        dropControlClient(server);
        return;
    }
    try server.rx.append(server.allocator, buf[0..@intCast(rc)]);
    while (true) {
        const readable = server.rx.readableSlice();
        const line_end = std.mem.indexOfAny(u8, readable, "\r\n") orelse break;
        const line_owned = try server.allocator.dupe(u8, std.mem.trim(u8, readable[0..line_end], " \r\n"));
        defer server.allocator.free(line_owned);
        var discard_len = line_end + 1;
        while (discard_len < readable.len and (readable[discard_len] == '\r' or readable[discard_len] == '\n')) : (discard_len += 1) {}
        server.rx.discard(discard_len);
        const line = line_owned;
        switch (alt_control.parse(line)) {
            .err => |err| {
                try writeCtlErr(client_fd, @tagName(err));
                continue;
            },
            .command => |cmd| switch (cmd) {
                .help => {
                    try writeCtlOkPayload(client_fd, "commands=help,state,switch,cycle,exit");
                    continue;
                },
                .state => {
                    const msg = try std.fmt.allocPrint(server.allocator, "active={d} screens=2 screen0={s} screen1={s}", .{ active.*.index(), stateName(primary), stateName(alternate) });
                    defer server.allocator.free(msg);
                    try writeCtlOkPayload(client_fd, msg);
                    continue;
                },
                .cycle => {
                    _ = try activateSide(term, cfg, active.*.toggled(), active, primary, alternate);
                    const msg = try std.fmt.allocPrint(server.allocator, "active={d} screens=2", .{active.*.index()});
                    defer server.allocator.free(msg);
                    try writeCtlOkPayload(client_fd, msg);
                    continue;
                },
                .exit => {
                    should_exit.* = true;
                    try writeCtlOk(client_fd);
                    continue;
                },
                .switch_to => |idx| {
                    const target = ActiveSide.fromIndex(idx) orelse {
                        try writeCtlErr(client_fd, "invalid_args");
                        continue;
                    };
                    _ = try activateSide(term, cfg, target, active, primary, alternate);
                    const msg = try std.fmt.allocPrint(server.allocator, "active={d} screens=2", .{active.*.index()});
                    defer server.allocator.free(msg);
                    try writeCtlOkPayload(client_fd, msg);
                    continue;
                },
            },
        }
    }
}

fn passthroughLoop(allocator: Allocator, term: *TerminalState, cfg: Config, primary: *SideRuntime, alternate: *SideRuntime, server: *ControlServer) !void {
    try setNonBlocking(term.tty_fd);
    try setNonBlockingIfPresent(primary.session.masterFd());
    try setNonBlockingIfPresent(alternate.session.masterFd());
    installSigwinchHandler();

    var active: ActiveSide = .primary;
    var should_exit = false;
    var pollfds = [_]c.struct_pollfd{
        .{ .fd = term.tty_fd, .events = 0, .revents = 0 },
        .{ .fd = -1, .events = 0, .revents = 0 },
        .{ .fd = -1, .events = 0, .revents = 0 },
        .{ .fd = server.listener_fd, .events = c.POLLIN, .revents = 0 },
        .{ .fd = -1, .events = c.POLLIN, .revents = 0 },
    };

    while (!should_exit) {
        if (try refreshLoopState(term, cfg, &active, primary, alternate)) return;
        try handleResizeIfPending(term.tty_fd, primary, alternate);

        const poll_active = activeSidePtr(active, primary, alternate);
        pollfds[0] = .{ .fd = term.tty_fd, .events = c.POLLIN, .revents = 0 };
        if (!poll_active.output_tx.isEmpty()) pollfds[0].events |= c.POLLOUT;
        pollfds[1] = .{ .fd = if (primary.isRunning()) try primary.masterFd() else -1, .events = if (primary.isRunning()) @as(c_short, @intCast(c.POLLIN | (if (!primary.input_tx.isEmpty()) c.POLLOUT else 0))) else 0, .revents = 0 };
        pollfds[2] = .{ .fd = if (alternate.isRunning()) try alternate.masterFd() else -1, .events = if (alternate.isRunning()) @as(c_short, @intCast(c.POLLIN | (if (!alternate.input_tx.isEmpty()) c.POLLOUT else 0))) else 0, .revents = 0 };
        pollfds[4] = .{ .fd = server.client_fd orelse -1, .events = if (server.client_fd != null) c.POLLIN else 0, .revents = 0 };

        const rc = c.poll(&pollfds, pollfds.len, 250);
        if (rc < 0) { if (std.posix.errno(rc) == .INTR) continue; return Error.PollFailed; }
        if (rc == 0) continue;

        if ((pollfds[3].revents & c.POLLIN) != 0 or (pollfds[4].fd >= 0 and (pollfds[4].revents & c.POLLIN) != 0)) {
            try handleControlServer(server, &active, &should_exit, term, cfg, primary, alternate);
        }

        if ((pollfds[1].revents & c.POLLIN) != 0) { try readSideOutput(allocator, primary); if (active != .primary) discardInactiveOutput(primary); }
        if ((pollfds[2].revents & c.POLLIN) != 0) { try readSideOutput(allocator, alternate); if (active != .alternate) discardInactiveOutput(alternate); }
        if ((pollfds[1].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) refreshSide(primary) catch |err| switch (err) { Error.ChildExited => {}, else => return err };
        if ((pollfds[2].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) refreshSide(alternate) catch |err| switch (err) { Error.ChildExited => {}, else => return err };
        if ((pollfds[0].revents & c.POLLIN) != 0) {
            var buf: [256]u8 = undefined;
            const n = c.read(term.tty_fd, &buf, buf.len);
            if (n > 0) try activeSidePtr(active, primary, alternate).input_tx.append(allocator, buf[0..@intCast(n)]);
        }
        const flush_active = activeSidePtr(active, primary, alternate);
        if (primary.isRunning() and ((pollfds[1].revents & c.POLLOUT) != 0 or active == .primary)) try flushSideInput(primary);
        if (alternate.isRunning() and ((pollfds[2].revents & c.POLLOUT) != 0 or active == .alternate)) try flushSideInput(alternate);
        if ((pollfds[0].revents & c.POLLOUT) != 0 or !flush_active.output_tx.isEmpty()) try flushActiveOutput(term, flush_active);
    }
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    if (argv.len <= 1) { usage(); return; }

    var cfg = Config.parse(allocator, argv) catch |err| switch (err) {
        Error.ShowHelp => {
            usage();
            return;
        },
        Error.InvalidArgs, Error.MissingControlPath, Error.MissingAlternateCommand, Error.MissingPrimaryCommand => { usage(); return err; },
        else => return err,
    };
    defer cfg.deinit();

    var term = try TerminalState.init();
    defer term.deinit();
    try term.enableRaw();

    const size = getTtySize(term.tty_fd) catch return Error.IoctlFailed;
    var primary = try SideRuntime.init(.{ .allocator = allocator, .spawn = .{ .argv = cfg.primary_argv, .cols = size.cols, .rows = size.rows } });
    primary.desired_size = .{ .cols = size.cols, .rows = size.rows };
    defer primary.deinit(allocator);
    try primary.session.start();
    try setNonBlockingIfPresent(primary.session.masterFd());

    const alternate_argv = [_][]const u8{cfg.alternate_path};
    var alternate = try SideRuntime.init(.{ .allocator = allocator, .spawn = .{ .argv = &alternate_argv, .cols = size.cols, .rows = size.rows } });
    alternate.desired_size = .{ .cols = size.cols, .rows = size.rows };
    defer alternate.deinit(allocator);

    var server = try ControlServer.init(allocator, cfg.control_path);
    defer server.deinit();

    passthroughLoop(allocator, &term, cfg, &primary, &alternate, &server) catch |err| switch (err) {
        Error.ChildExited => {},
        else => return err,
    };
}
