const std = @import("std");
const c = @cImport({
    @cInclude("sys/wait.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("string.h");
});
const host = @import("session_host_vpty");
const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const vpty_terminal = @import("vpty_terminal");
const side_effects = @import("side_effects");
const stdout_thread_mod = @import("stdout_thread");
const StdoutThread = stdout_thread_mod.StdoutThread;
const terminal_model_mod = @import("terminal_model");
const TerminalModel = terminal_model_mod.TerminalModel;
const render_thread_mod = @import("render_thread");
const RenderThread = render_thread_mod.RenderThread;
const SharedTerminalModel = render_thread_mod.SharedTerminalModel;
const WakePipe = @import("wake_pipe").WakePipe;

const INPUT_READ_CHUNK = 4096;
const OUTPUT_READ_CHUNK = 4096;
const IO_SPIN_LIMIT = 16;

var winch_changed: bool = false;
var terminate_requested: bool = false;
var terminate_signal: c_int = 0;
var wake_pipe: WakePipe = .{};

const TransportState = struct {
    stdin_open: bool = true,
    input_tx: ByteQueue = ByteQueue.init(),
    output_rx: ByteQueue = ByteQueue.init(),

    fn deinit(self: *TransportState, allocator: std.mem.Allocator) void {
        self.input_tx.deinit(allocator);
        self.output_rx.deinit(allocator);
    }

    fn configureNonBlocking(self: *TransportState, session_host: *host.SessionHost, stdin_fd: c_int, stdout_fd: c_int) !void {
        _ = self;
        try fd_stream.setNonBlocking(stdin_fd);
        try fd_stream.setNonBlocking(stdout_fd);
        if (session_host.getMasterFd()) |fd| try fd_stream.setNonBlocking(fd);
    }

    fn ptyPollEvents(self: *const TransportState) c_short {
        var events: c_short = c.POLLIN;
        if (!self.input_tx.isEmpty()) events |= c.POLLOUT;
        return events;
    }

    fn ingestStdin(self: *TransportState, stdin_fd: c_int) !void {
        if (!self.stdin_open) return;

        var spins: usize = 0;
        while (self.stdin_open and spins < IO_SPIN_LIMIT) : (spins += 1) {
            const status = try fd_stream.readIntoQueue(std.heap.page_allocator, stdin_fd, &self.input_tx, INPUT_READ_CHUNK);
            switch (status) {
                .progress => |n| {
                    if (n < INPUT_READ_CHUNK) break;
                },
                .would_block => break,
                .eof => self.stdin_open = false,
            }
        }
    }

    fn flushInput(self: *TransportState, session_host: *host.SessionHost) !void {
        var spins: usize = 0;
        while (!self.input_tx.isEmpty() and spins < IO_SPIN_LIMIT) : (spins += 1) {
            const status = try fd_stream.writeFromQueue(session_host.getMasterFd() orelse return error.InvalidState, &self.input_tx, 64 * 1024);
            switch (status) {
                .progress => |n| {
                    if (n == 0) break;
                },
                .would_block => break,
            }
        }
    }

    fn ingestPtyOutput(self: *TransportState, session_host: *host.SessionHost) !void {
        var spins: usize = 0;
        while (spins < IO_SPIN_LIMIT) : (spins += 1) {
            const status = try fd_stream.readIntoQueue(std.heap.page_allocator, session_host.getMasterFd() orelse return error.InvalidState, &self.output_rx, OUTPUT_READ_CHUNK);
            switch (status) {
                .progress => |n| {
                    if (n < OUTPUT_READ_CHUNK) break;
                },
                .would_block => break,
                .eof => break,
            }
        }
    }

    fn processOutput(self: *TransportState, shared_model: *SharedTerminalModel, render_thread: *RenderThread, forwarder: *side_effects.SideEffectForwarder, stdout_actor: *StdoutThread) !bool {
        var emitted_osc52 = false;
        var spins: usize = 0;
        while (!self.output_rx.isEmpty() and spins < IO_SPIN_LIMIT) : (spins += 1) {
            const readable = self.output_rx.readableSlice();
            const chunk_len = @min(readable.len, OUTPUT_READ_CHUNK);
            const chunk = readable[0..chunk_len];

            const result = try forwarder.feed(stdout_actor, chunk);
            emitted_osc52 = emitted_osc52 or result.emitted_osc52;

            shared_model.lock();
            const update = shared_model.model.feedScreenBytes(result.screen_bytes);
            shared_model.unlock();

            render_thread.publishModelChanged(update.asModelChanged());
            self.output_rx.discard(chunk_len);
        }
        return emitted_osc52;
    }
};

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn usage() void {
    out(
        "NAME\n" ++
            "  vpty - minimal terminal frontend for PTY-hosted applications\n\n" ++
            "USAGE\n" ++
            "  vpty -- <command> [args...]\n\n" ++
            "DESCRIPTION\n" ++
            "  Runs a child process on an inner PTY.\n",
        .{},
    );
}

fn signalNumber(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "HUP")) return @intCast(c.SIGHUP);
    if (std.mem.eql(u8, name, "INT")) return @intCast(c.SIGINT);
    if (std.mem.eql(u8, name, "QUIT")) return @intCast(c.SIGQUIT);
    if (std.mem.eql(u8, name, "KILL")) return @intCast(c.SIGKILL);
    if (std.mem.eql(u8, name, "TERM")) return @intCast(c.SIGTERM);
    return 1;
}

fn childExitCode(status: host.ExitStatus) u8 {
    if (status.code) |code| return @intCast(@max(0, @min(code, 255)));
    if (status.signal) |name| return 128 + signalNumber(name);
    return 0;
}

fn handleTerminationSignal(sig: c_int) callconv(.c) void {
    terminate_requested = true;
    terminate_signal = sig;
    wake_pipe.notify();
}

fn applyViewerSize(
    session_host: *host.SessionHost,
    shared_model: *SharedTerminalModel,
    render_thread: *RenderThread,
    rows: u16,
    cols: u16,
) void {
    session_host.applySessionSize(.{ .cols = cols, .rows = rows }) catch return;
    shared_model.lock();
    const update = shared_model.model.resize(rows, cols);
    shared_model.unlock();

    render_thread.reset();
    render_thread.publishModelChanged(update.asModelChanged());
}

fn handleSigwinch(_: c_int) callconv(.c) void {
    winch_changed = true;
    wake_pipe.notify();
}

fn handleResizeIfNeeded(session_host: *host.SessionHost, shared_model: *SharedTerminalModel, render_thread: *RenderThread, terminal: *vpty_terminal.TerminalMode) void {
    if (!winch_changed) return;
    winch_changed = false;
    const size = terminal.currentSize() catch vpty_terminal.Size{ .rows = 24, .cols = 80 };
    applyViewerSize(session_host, shared_model, render_thread, size.rows, size.cols);
}

fn handleTerminationIfNeeded(session_host: *host.SessionHost) !?host.ExitStatus {
    if (!terminate_requested) return null;

    _ = session_host.terminate(
        if (terminate_signal == c.SIGINT) "INT"
        else if (terminate_signal == c.SIGTERM) "TERM"
        else null,
    ) catch {};

    while (session_host.getState() != .exited) {
        session_host.refresh() catch {};
        if (session_host.getState() == .exited) break;
        _ = c.usleep(10_000);
    }

    return session_host.getExitStatus() orelse host.ExitStatus{
        .signal = if (terminate_signal == c.SIGINT) "INT" else "TERM",
    };
}

fn drainWakePipe() void {
    wake_pipe.drain();
}

fn stepLifecycle(
    session_host: *host.SessionHost,
    shared_model: *SharedTerminalModel,
    render_thread: *RenderThread,
    terminal: *vpty_terminal.TerminalMode,
) !?host.ExitStatus {
    handleResizeIfNeeded(session_host, shared_model, render_thread, terminal);
    return try handleTerminationIfNeeded(session_host);
}

fn stepWake(pfds: []const c.struct_pollfd) void {
    if ((pfds[2].revents & c.POLLIN) != 0) {
        drainWakePipe();
    }
}

fn stepStdoutCommitted(stdout_actor: *StdoutThread, shared_model: *SharedTerminalModel, pfds: []const c.struct_pollfd) !void {
    _ = pfds;
    if (stdout_actor.takeNewlyCommittedRenderVersion()) |notice| {
        shared_model.lock();
        shared_model.model.markCommittedThrough(notice.version);
        shared_model.unlock();
    }
}

fn stepInput(transport: *TransportState, session_host: *host.SessionHost, terminal: *vpty_terminal.TerminalMode, pfds: []const c.struct_pollfd) !void {
    if (transport.stdin_open and (pfds[0].revents & c.POLLIN) != 0) {
        try transport.ingestStdin(terminal.stdin_fd);
    }

    if (!transport.input_tx.isEmpty() and (((pfds[1].revents & c.POLLOUT) != 0) or ((pfds[0].revents & c.POLLIN) != 0))) {
        try transport.flushInput(session_host);
    }
}

fn stepPtyOutput(
    transport: *TransportState,
    session_host: *host.SessionHost,
    shared_model: *SharedTerminalModel,
    render_thread: *RenderThread,
    forwarder: *side_effects.SideEffectForwarder,
    stdout_actor: *StdoutThread,
    pfds: []const c.struct_pollfd,
) !bool {
    if ((pfds[1].revents & c.POLLIN) != 0) {
        try transport.ingestPtyOutput(session_host);
    }

    var emitted_osc52 = false;
    if (!transport.output_rx.isEmpty()) {
        emitted_osc52 = try transport.processOutput(shared_model, render_thread, forwarder, stdout_actor);
    }
    return emitted_osc52;
}

fn stepRender(render_thread: *RenderThread, transport: *const TransportState, stdout_actor: *const StdoutThread, emitted_osc52: bool) void {
    _ = render_thread;
    _ = transport;
    _ = stdout_actor;
    _ = emitted_osc52;
}

fn stepStdoutLate(stdout_actor: *StdoutThread, shared_model: *SharedTerminalModel, pfds: []const c.struct_pollfd) !void {
    try stepStdoutCommitted(stdout_actor, shared_model, pfds);
}

fn refreshAndMaybeExit(session_host: *host.SessionHost) !?host.ExitStatus {
    session_host.refresh() catch |e| switch (e) {
        host.Error.InvalidState, host.Error.NotStarted, host.Error.Closed => return e,
        else => {},
    };

    if (session_host.getState() == .exited) {
        return session_host.getExitStatus() orelse host.ExitStatus{};
    }

    return null;
}

fn pumpUntilExit(session_host: *host.SessionHost, shared_model: *SharedTerminalModel, render_thread: *RenderThread, terminal: *vpty_terminal.TerminalMode, forwarder: *side_effects.SideEffectForwarder, stdout_actor: *StdoutThread) !host.ExitStatus {
    var transport = TransportState{};
    defer transport.deinit(std.heap.page_allocator);

    try transport.configureNonBlocking(session_host, terminal.stdin_fd, terminal.stdout_fd);

    while (true) {
        if (try stepLifecycle(session_host, shared_model, render_thread, terminal)) |status| return status;

        var pfds = [4]c.struct_pollfd{
            .{ .fd = if (transport.stdin_open) terminal.stdin_fd else -1, .events = if (transport.stdin_open) c.POLLIN else 0, .revents = 0 },
            .{ .fd = session_host.getMasterFd() orelse -1, .events = transport.ptyPollEvents(), .revents = 0 },
            .{ .fd = wake_pipe.readFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = -1, .events = 0, .revents = 0 },
        };

        const pr = c.poll(&pfds, 4, 10);
        if (pr < 0) {
            const e = std.c.errno(-1);
            if (e == .INTR) continue;
            return error.IoError;
        }

        stepWake(&pfds);
        try stepStdoutCommitted(stdout_actor, shared_model, &pfds);
        try stepInput(&transport, session_host, terminal, &pfds);
        const emitted_osc52 = try stepPtyOutput(&transport, session_host, shared_model, render_thread, forwarder, stdout_actor, &pfds);
        stepRender(render_thread, &transport, stdout_actor, emitted_osc52);
        try stepStdoutLate(stdout_actor, shared_model, &pfds);

        if (try refreshAndMaybeExit(session_host)) |status| return status;
    }
}

const VptyRuntime = struct {
    allocator: std.mem.Allocator,
    child_argv: []const []const u8,
    terminal: vpty_terminal.TerminalMode,
    forwarder: side_effects.SideEffectForwarder,
    stdout_actor: StdoutThread,
    session_host: host.SessionHost,
    shared_model: SharedTerminalModel,
    render_thread: RenderThread,

    fn init(self: *VptyRuntime, allocator: std.mem.Allocator, io: anytype, child_argv: []const []const u8) !void {
        var terminal = vpty_terminal.TerminalMode.init(c.STDIN_FILENO, c.STDOUT_FILENO);
        errdefer terminal.restore();

        var forwarder = side_effects.SideEffectForwarder.init(allocator);
        errdefer forwarder.deinit();

        var stdout_actor = StdoutThread.init(allocator, io);
        errdefer stdout_actor.deinit();

        const size = terminal.currentSize() catch vpty_terminal.Size{ .rows = 24, .cols = 80 };

        var session_host = try host.SessionHost.init(allocator, .{
            .argv = child_argv,
            .rows = size.rows,
            .cols = size.cols,
        });
        errdefer session_host.deinit();

        var shared_model = SharedTerminalModel.init(io, try TerminalModel.init(size.rows, size.cols));
        errdefer shared_model.model.deinit();

        self.* = .{
            .allocator = allocator,
            .child_argv = child_argv,
            .terminal = terminal,
            .forwarder = forwarder,
            .stdout_actor = stdout_actor,
            .session_host = session_host,
            .shared_model = shared_model,
            .render_thread = undefined,
        };
        self.render_thread = RenderThread.init(allocator, &self.shared_model, &self.stdout_actor);
    }

    fn deinit(self: *VptyRuntime) void {
        self.render_thread.deinit();
        self.shared_model.model.deinit();
        self.session_host.deinit();
        self.stdout_actor.deinit();
        self.forwarder.deinit();
        self.terminal.restore();
        _ = self.allocator;
        _ = self.child_argv;
    }

    fn primeRender(self: *VptyRuntime) void {
        self.shared_model.lock();
        self.shared_model.model.forceFullDamage();
        self.shared_model.unlock();
        self.render_thread.reset();
        self.render_thread.publishModelChanged(.{ .version = self.shared_model.model.currentVersion() });
    }

    fn installSignalHandlers() !SignalHandlers {
        wake_pipe = try WakePipe.init();
        errdefer wake_pipe.deinit();

        const handlers = SignalHandlers{
            .old_winch = c.signal(c.SIGWINCH, handleSigwinch),
            .old_int = c.signal(c.SIGINT, handleTerminationSignal),
            .old_term = c.signal(c.SIGTERM, handleTerminationSignal),
        };

        winch_changed = true;
        terminate_requested = false;
        terminate_signal = 0;
        return handlers;
    }

    fn run(self: *VptyRuntime) !u8 {
        try self.session_host.start();
        try self.terminal.enterRaw();
        try self.stdout_actor.start();
        try self.render_thread.start();

        self.primeRender();

        const signal_handlers = try installSignalHandlers();
        defer signal_handlers.restore();

        const status = try pumpUntilExit(&self.session_host, &self.shared_model, &self.render_thread, &self.terminal, &self.forwarder, &self.stdout_actor);
        self.render_thread.shutdownActor();
        self.render_thread.stop();
        self.stdout_actor.stop();
        self.terminal.restore();
        _ = self.session_host.close() catch {};
        return childExitCode(status);
    }
};

const SignalHandlers = struct {
    old_winch: ?*const fn (c_int) callconv(.c) void,
    old_int: ?*const fn (c_int) callconv(.c) void,
    old_term: ?*const fn (c_int) callconv(.c) void,

    fn restore(self: SignalHandlers) void {
        defer wake_pipe.deinit();
        _ = c.signal(c.SIGWINCH, self.old_winch);
        _ = c.signal(c.SIGINT, self.old_int);
        _ = c.signal(c.SIGTERM, self.old_term);
    }
};

fn parseChildArgv(allocator: std.mem.Allocator, init: std.process.Init) !std.ArrayList([]const u8) {
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    var argv_list = std.ArrayList([]const u8){};
    errdefer argv_list.deinit(allocator);
    while (args_it.next()) |arg| {
        try argv_list.append(allocator, arg);
    }
    const argv = argv_list.items;

    if (argv.len < 3) {
        usage();
        return error.InvalidArgs;
    }

    var sep_idx: ?usize = null;
    for (argv[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            sep_idx = i;
            break;
        }
    }

    const cmd_start = sep_idx orelse {
        usage();
        return error.InvalidArgs;
    };
    if (cmd_start + 1 >= argv.len) {
        err("vpty: missing command after --\n", .{});
        usage();
        return error.InvalidArgs;
    }

    var result = std.ArrayList([]const u8){};
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, argv[(cmd_start + 1)..]);
    argv_list.deinit(allocator);
    return result;
}

pub fn main(init: std.process.Init) !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var child_argv_list = parseChildArgv(allocator, init) catch |parse_err| switch (parse_err) {
        error.InvalidArgs => return 1,
        else => return parse_err,
    };
    defer child_argv_list.deinit(allocator);

    var runtime: VptyRuntime = undefined;
    try runtime.init(allocator, init.io, child_argv_list.items);
    defer runtime.deinit();
    return runtime.run();
}
