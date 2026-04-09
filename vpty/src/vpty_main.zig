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
const vpty_render = @import("vpty_render");
const RenderActor = vpty_render.RenderActor;
const side_effects = @import("side_effects");
const stdout_thread_mod = @import("stdout_thread");
const StdoutThread = stdout_thread_mod.StdoutThread;
const terminal_model_mod = @import("terminal_model");
const TerminalModel = terminal_model_mod.TerminalModel;

const INPUT_READ_CHUNK = 4096;
const OUTPUT_READ_CHUNK = 4096;
const IO_SPIN_LIMIT = 16;
const RENDER_BACKLOG_THRESHOLD = 16 * 1024;
const STDOUT_BACKLOG_THRESHOLD = 256 * 1024;
const MAX_RENDER_DEFERRALS = 8;

var winch_changed: bool = false;
var terminate_requested: bool = false;
var terminate_signal: c_int = 0;
var wake_pipe: [2]c_int = .{ -1, -1 };

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

    fn hasHeavyBacklog(self: *const TransportState) bool {
        return self.input_tx.len() >= RENDER_BACKLOG_THRESHOLD or self.output_rx.len() >= RENDER_BACKLOG_THRESHOLD;
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

    fn processOutput(self: *TransportState, model: *TerminalModel, render_actor: *RenderActor, forwarder: *side_effects.SideEffectForwarder, stdout_actor: *StdoutThread) !bool {
        var emitted_osc52 = false;
        var spins: usize = 0;
        while (!self.output_rx.isEmpty() and spins < IO_SPIN_LIMIT) : (spins += 1) {
            const readable = self.output_rx.readableSlice();
            const chunk_len = @min(readable.len, OUTPUT_READ_CHUNK);
            const chunk = readable[0..chunk_len];

            const result = try forwarder.feed(stdout_actor, chunk);
            emitted_osc52 = emitted_osc52 or result.emitted_osc52;
            const update = model.feedScreenBytes(result.screen_bytes);
            if (update.dirty) render_actor.renderDamaged();

            self.output_rx.discard(chunk_len);
        }
        return emitted_osc52;
    }
};

const RenderPolicy = struct {
    deferred_iterations: usize = 0,
    force_render: bool = false,

    fn noteForced(self: *RenderPolicy) void {
        self.force_render = true;
    }

    fn shouldRenderNow(self: *RenderPolicy, transport: *const TransportState, model: *const TerminalModel, stdout_actor: *const StdoutThread) bool {
        if (model.currentVersion() <= stdout_actor.committedRenderVersion()) return false;
        if (stdout_actor.pendingBytes() >= STDOUT_BACKLOG_THRESHOLD) return false;
        if (self.force_render) return true;
        if (!transport.hasHeavyBacklog()) return true;
        if (self.deferred_iterations >= MAX_RENDER_DEFERRALS) return true;
        self.deferred_iterations += 1;
        return false;
    }

    fn noteRendered(self: *RenderPolicy) void {
        self.deferred_iterations = 0;
        self.force_render = false;
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
    if (wake_pipe[1] >= 0) {
        const b: u8 = 1;
        _ = c.write(wake_pipe[1], &b, 1);
    }
}

fn applyViewerSize(
    session_host: *host.SessionHost,
    model: *TerminalModel,
    render_actor: *RenderActor,
    render_policy: *RenderPolicy,
    rows: u16,
    cols: u16,
) void {
    session_host.applySessionSize(.{ .cols = cols, .rows = rows }) catch return;
    _ = model.resize(rows, cols);

    render_actor.renderDamaged();
    render_policy.noteForced();
    render_actor.reset();
}

fn handleSigwinch(_: c_int) callconv(.c) void {
    winch_changed = true;
    if (wake_pipe[1] >= 0) {
        const b: u8 = 1;
        _ = c.write(wake_pipe[1], &b, 1);
    }
}

fn handleResizeIfNeeded(session_host: *host.SessionHost, model: *TerminalModel, render_actor: *RenderActor, render_policy: *RenderPolicy, terminal: *vpty_terminal.TerminalMode) void {
    if (!winch_changed) return;
    winch_changed = false;
    const size = terminal.currentSize() catch vpty_terminal.Size{ .rows = 24, .cols = 80 };
    applyViewerSize(session_host, model, render_actor, render_policy, size.rows, size.cols);
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
    var tmp: [64]u8 = undefined;
    while (true) {
        const n = c.read(wake_pipe[0], &tmp, tmp.len);
        if (n <= 0 or n < tmp.len) break;
    }
}

fn stepLifecycle(
    session_host: *host.SessionHost,
    model: *TerminalModel,
    render_actor: *RenderActor,
    render_policy: *RenderPolicy,
    terminal: *vpty_terminal.TerminalMode,
) !?host.ExitStatus {
    handleResizeIfNeeded(session_host, model, render_actor, render_policy, terminal);
    return try handleTerminationIfNeeded(session_host);
}

fn stepWake(pfds: []const c.struct_pollfd) void {
    if ((pfds[2].revents & c.POLLIN) != 0) {
        drainWakePipe();
    }
}

fn stepStdoutEarly(stdout_actor: *StdoutThread, model: *TerminalModel, render_actor: *RenderActor, pfds: []const c.struct_pollfd) !void {
    _ = pfds;
    if (stdout_actor.takeNewlyCommittedRenderVersion()) |notice| {
        model.markCommittedThrough(notice.version);
        render_actor.noteCommitted(notice);
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
    model: *TerminalModel,
    render_actor: *RenderActor,
    forwarder: *side_effects.SideEffectForwarder,
    stdout_actor: *StdoutThread,
    pfds: []const c.struct_pollfd,
) !bool {
    if ((pfds[1].revents & c.POLLIN) != 0) {
        try transport.ingestPtyOutput(session_host);
    }

    var emitted_osc52 = false;
    if (!transport.output_rx.isEmpty()) {
        emitted_osc52 = try transport.processOutput(model, render_actor, forwarder, stdout_actor);
    }
    return emitted_osc52;
}

fn stepRender(render_actor: *RenderActor, render_policy: *RenderPolicy, transport: *const TransportState, model: *const TerminalModel, stdout_actor: *const StdoutThread, emitted_osc52: bool) void {
    maybeRender(render_actor, render_policy, transport, model, stdout_actor, emitted_osc52);
}

fn stepStdoutLate(stdout_actor: *StdoutThread, model: *TerminalModel, render_actor: *RenderActor, pfds: []const c.struct_pollfd) !void {
    _ = pfds;
    if (stdout_actor.takeNewlyCommittedRenderVersion()) |notice| {
        model.markCommittedThrough(notice.version);
        render_actor.noteCommitted(notice);
    }
}

fn maybeRender(render_actor: *RenderActor, render_policy: *RenderPolicy, transport: *const TransportState, model: *const TerminalModel, stdout_actor: *const StdoutThread, emitted_osc52: bool) void {
    if (emitted_osc52) {
        render_policy.noteForced();
        return;
    }
    if (!render_policy.shouldRenderNow(transport, model, stdout_actor)) return;
    render_actor.doRender();
    render_policy.noteRendered();
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

fn pumpUntilExit(session_host: *host.SessionHost, model: *TerminalModel, render_actor: *RenderActor, terminal: *vpty_terminal.TerminalMode, forwarder: *side_effects.SideEffectForwarder, stdout_actor: *StdoutThread) !host.ExitStatus {
    var transport = TransportState{};
    defer transport.deinit(std.heap.page_allocator);

    var render_policy = RenderPolicy{};

    try transport.configureNonBlocking(session_host, terminal.stdin_fd, terminal.stdout_fd);

    while (true) {
        if (try stepLifecycle(session_host, model, render_actor, &render_policy, terminal)) |status| return status;

        var pfds = [4]c.struct_pollfd{
            .{ .fd = if (transport.stdin_open) terminal.stdin_fd else -1, .events = if (transport.stdin_open) c.POLLIN else 0, .revents = 0 },
            .{ .fd = session_host.getMasterFd() orelse -1, .events = transport.ptyPollEvents(), .revents = 0 },
            .{ .fd = wake_pipe[0], .events = c.POLLIN, .revents = 0 },
            .{ .fd = -1, .events = 0, .revents = 0 },
        };

        const pr = c.poll(&pfds, 4, 10);
        if (pr < 0) {
            const e = std.c.errno(-1);
            if (e == .INTR) continue;
            return error.IoError;
        }

        stepWake(&pfds);
        try stepStdoutEarly(stdout_actor, model, render_actor, &pfds);
        try stepInput(&transport, session_host, terminal, &pfds);
        const emitted_osc52 = try stepPtyOutput(&transport, session_host, model, render_actor, forwarder, stdout_actor, &pfds);
        stepRender(render_actor, &render_policy, &transport, model, stdout_actor, emitted_osc52);
        try stepStdoutLate(stdout_actor, model, render_actor, &pfds);

        if (try refreshAndMaybeExit(session_host)) |status| return status;
    }
}

pub fn main(init: std.process.Init) !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    var argv_list = std.ArrayList([]const u8){};
    defer argv_list.deinit(allocator);
    while (args_it.next()) |arg| {
        try argv_list.append(allocator, arg);
    }
    const argv = argv_list.items;

    if (argv.len < 3) {
        usage();
        return 1;
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
        return 1;
    };
    if (cmd_start + 1 >= argv.len) {
        err("vpty: missing command after --\n", .{});
        usage();
        return 1;
    }

    const child_argv = argv[(cmd_start + 1)..];

    var terminal = vpty_terminal.TerminalMode.init(c.STDIN_FILENO, c.STDOUT_FILENO);
    defer terminal.restore();

    var forwarder = side_effects.SideEffectForwarder.init(allocator);
    defer forwarder.deinit();

    var stdout_actor = StdoutThread.init(allocator);
    defer stdout_actor.deinit();

    var render_actor = RenderActor{};
    defer render_actor.deinit();

    const size = terminal.currentSize() catch vpty_terminal.Size{ .rows = 24, .cols = 80 };

    var session_host = try host.SessionHost.init(allocator, .{
        .argv = child_argv,
        .enable_terminal_state = false,
        .rows = size.rows,
        .cols = size.cols,
        .replay_capacity = 0,
    });
    defer session_host.deinit();

    var model = try TerminalModel.init(size.rows, size.cols);
    defer model.deinit();

    try session_host.start();
    try terminal.enterRaw();
    try stdout_actor.start();

    render_actor.setTerminalModel(&model);
    render_actor.setStdoutActor(&stdout_actor);
    model.forceFullDamage();
    render_actor.renderDamaged();
    render_actor.reset();
    render_actor.doRender();

    if (c.pipe(&wake_pipe) != 0) return error.IoError;
    defer {
        if (wake_pipe[0] >= 0) _ = c.close(wake_pipe[0]);
        if (wake_pipe[1] >= 0) _ = c.close(wake_pipe[1]);
    }

    const old_winch = c.signal(c.SIGWINCH, handleSigwinch);
    const old_int = c.signal(c.SIGINT, handleTerminationSignal);
    const old_term = c.signal(c.SIGTERM, handleTerminationSignal);
    defer {
        _ = c.signal(c.SIGWINCH, old_winch);
        _ = c.signal(c.SIGINT, old_int);
        _ = c.signal(c.SIGTERM, old_term);
    }
    winch_changed = true;

    const status = try pumpUntilExit(&session_host, &model, &render_actor, &terminal, &forwarder, &stdout_actor);
    render_actor.shutdown();
    stdout_actor.stop();
    terminal.restore();
    _ = session_host.close() catch {};
    return childExitCode(status);
}
