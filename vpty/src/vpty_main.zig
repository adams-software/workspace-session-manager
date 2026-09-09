const std = @import("std");
const c = @cImport({
    @cInclude("sys/wait.h");
    @cInclude("poll.h");
    @cInclude("time.h");
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
const Viewport = @import("vpty_render").Viewport;
const runtime_lifecycle_mod = @import("runtime_lifecycle");
const RuntimeLifecycle = runtime_lifecycle_mod.RuntimeLifecycle;
const ModelSize = terminal_model_mod.ModelSize;
const GraphemeMode = terminal_model_mod.GraphemeMode;

const INPUT_READ_CHUNK = 4096;
const INPUT_QUEUE_LIMIT = 256 * 1024;
const OUTPUT_READ_CHUNK = 4096;
const CONTROL_HIGH_WATER = 2 * 1024 * 1024;
const IO_SPIN_LIMIT = 16;

fn parseU16Flag(flag: []const u8, value: []const u8) !u16 {
    return std.fmt.parseInt(u16, value, 10) catch {
        err("vpty: invalid value for {s}: {s}\n", .{ flag, value });
        return error.InvalidArgs;
    };
}

const RunMode = enum {
    fullscreen,
    bounded,
};

const ViewportIntent = struct {
    rows_explicit: bool = false,
    cols_explicit: bool = false,
};

const ParsedArgs = struct {
    mode: RunMode,
    viewport: Viewport,
    viewport_intent: ViewportIntent,
    child_argv: std.ArrayList([]const u8),

    fn deinit(self: *ParsedArgs, allocator: std.mem.Allocator) void {
        self.child_argv.deinit(allocator);
    }
};

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

    fn ptyPollEvents(self: *const TransportState, pending_controls: usize) c_short {
        var events: c_short = if (self.output_rx.isEmpty() and pending_controls < CONTROL_HIGH_WATER) c.POLLIN else 0;
        if (!self.input_tx.isEmpty()) events |= c.POLLOUT;
        return events;
    }

    fn stdinPollFd(self: *const TransportState, stdin_fd: c_int) c_int {
        // A negative fd also suppresses POLLHUP while the queue is full.
        return if (self.stdin_open and self.input_tx.len() < INPUT_QUEUE_LIMIT) stdin_fd else -1;
    }

    fn ingestStdin(self: *TransportState, stdin_fd: c_int) !void {
        if (!self.stdin_open) return;

        var spins: usize = 0;
        while (self.stdin_open and self.input_tx.len() < INPUT_QUEUE_LIMIT and spins < IO_SPIN_LIMIT) : (spins += 1) {
            const status = try fd_stream.readIntoQueue(std.heap.page_allocator, stdin_fd, &self.input_tx, @min(INPUT_READ_CHUNK, INPUT_QUEUE_LIMIT - self.input_tx.len()));
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

    fn processOutput(self: *TransportState, shared_model: *SharedTerminalModel, render_thread: *RenderThread, forwarder: *side_effects.SideEffectForwarder, stdout_actor: *StdoutThread) !void {
        var spins: usize = 0;
        while (!self.output_rx.isEmpty() and stdout_actor.pendingControlBytes() < CONTROL_HIGH_WATER and spins < IO_SPIN_LIMIT) : (spins += 1) {
            const readable = self.output_rx.readableSlice();
            const chunk_len = @min(readable.len, OUTPUT_READ_CHUNK);
            const chunk = readable[0..chunk_len];

            const result = try forwarder.feed(stdout_actor, chunk);

            shared_model.lock();
            const update = shared_model.model.feedScreenBytes(result.screen_bytes);
            shared_model.unlock();

            render_thread.publishModelChanged(update.asModelChanged());
            self.output_rx.discard(chunk_len);
        }
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
            "  vpty [--origin-row N] [--origin-col N] [--rows N] [--cols N] -- <command> [args...]\n\n" ++
            "DESCRIPTION\n" ++
            "  Runs a child process on an inner PTY and renders it into a viewport.\n" ++
            "  If viewport flags are omitted, the viewport defaults to the full current terminal at origin (0,0).\n",
        .{},
    );
}

fn graphemeModeFromEnv() GraphemeMode {
    const raw = std.c.getenv("VPTY_GRAPHEME_MODE") orelse return .legacy;
    const value = std.mem.span(raw);

    if (std.ascii.eqlIgnoreCase(value, "unicode")) return .unicode;
    return .legacy;
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

fn applyViewerSize(
    session_host: *host.SessionHost,
    shared_model: *SharedTerminalModel,
    render_thread: *RenderThread,
    stdout_actor: *StdoutThread,
    rows: u16,
    cols: u16,
) void {
    session_host.applySessionSize(.{ .cols = cols, .rows = rows }) catch return;
    stdout_actor.invalidatePendingRenders();
    shared_model.lock();
    const update = shared_model.model.resize(rows, cols);
    shared_model.unlock();

    render_thread.reset();
    render_thread.publishModelChanged(update.asModelChanged());
}

fn forceViewerRepaint(shared_model: *SharedTerminalModel, render_thread: *RenderThread) void {
    shared_model.lock();
    const update = shared_model.model.forceFullDamage();
    shared_model.unlock();

    render_thread.publishModelChanged(update.asModelChanged());
}

fn viewerSizeChanged(current: ?ModelSize, rows: u16, cols: u16) bool {
    const size = current orelse return true;
    return size.rows != rows or size.cols != cols;
}

fn resolveViewport(partial: Viewport, size: vpty_terminal.Size) Viewport {
    const available_rows = if (partial.origin_row >= size.rows) @as(u16, 0) else size.rows - partial.origin_row;
    const available_cols = if (partial.origin_col >= size.cols) @as(u16, 0) else size.cols - partial.origin_col;

    const rows = if (partial.rows == 0)
        available_rows
    else
        @min(partial.rows, available_rows);
    const cols = if (partial.cols == 0)
        available_cols
    else
        @min(partial.cols, available_cols);

    return Viewport.init(
        partial.origin_row,
        partial.origin_col,
        rows,
        cols,
    );
}

fn handleResizeIfNeeded(
    lifecycle: *RuntimeLifecycle,
    session_host: *host.SessionHost,
    shared_model: *SharedTerminalModel,
    render_thread: *RenderThread,
    stdout_actor: *StdoutThread,
    terminal: *vpty_terminal.TerminalMode,
    mode: RunMode,
    viewport: Viewport,
    viewport_intent: ViewportIntent,
) void {
    const size = lifecycle.takeSettledResizeIfNeeded(terminal) orelse return;
    const resolved = switch (mode) {
        .fullscreen => Viewport.init(0, 0, size.rows, size.cols),
        .bounded => resolveViewport(viewport, size),
    };
    const target_rows = switch (mode) {
        .fullscreen => resolved.rows,
        .bounded => if (viewport_intent.rows_explicit) viewport.rows else resolved.rows,
    };
    const target_cols = switch (mode) {
        .fullscreen => resolved.cols,
        .bounded => if (viewport_intent.cols_explicit) viewport.cols else resolved.cols,
    };

    if (mode == .fullscreen) {
        render_thread.setViewport(resolved);
    }

    shared_model.lock();
    const changed = viewerSizeChanged(shared_model.model.currentSize(), target_rows, target_cols);
    shared_model.unlock();

    if (changed) {
        applyViewerSize(session_host, shared_model, render_thread, stdout_actor, target_rows, target_cols);
    } else {
        forceViewerRepaint(shared_model, render_thread);
    }
}

fn stepStdoutCommitted(stdout_actor: *StdoutThread, shared_model: *SharedTerminalModel) !void {
    if (stdout_actor.takeNewlyCommittedRenderVersion()) |notice| {
        shared_model.lock();
        shared_model.model.markCommittedThrough(notice.version);
        shared_model.unlock();
    }
}

fn stepInput(transport: *TransportState, session_host: *host.SessionHost, terminal: *vpty_terminal.TerminalMode, pfds: []const c.struct_pollfd) !void {
    if (transport.stdin_open and (pfds[0].revents & (c.POLLIN | c.POLLHUP)) != 0) {
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
) !void {
    if ((pfds[1].revents & c.POLLIN) != 0) {
        try transport.ingestPtyOutput(session_host);
    }

    if (!transport.output_rx.isEmpty()) {
        try transport.processOutput(shared_model, render_thread, forwarder, stdout_actor);
    }
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

fn pumpUntilExit(lifecycle: *RuntimeLifecycle, session_host: *host.SessionHost, shared_model: *SharedTerminalModel, render_thread: *RenderThread, terminal: *vpty_terminal.TerminalMode, mode: RunMode, viewport: Viewport, viewport_intent: ViewportIntent, forwarder: *side_effects.SideEffectForwarder, stdout_actor: *StdoutThread) !host.ExitStatus {
    var transport = TransportState{};
    defer transport.deinit(std.heap.page_allocator);

    try transport.configureNonBlocking(session_host, terminal.stdin_fd, terminal.stdout_fd);

    while (true) {
        handleResizeIfNeeded(lifecycle, session_host, shared_model, render_thread, stdout_actor, terminal, mode, viewport, viewport_intent);
        lifecycle.issueTerminationIfNeeded(session_host);
        if (stdout_actor.output_failed.load(.seq_cst)) return error.OutputClosed;

        const pty_events = transport.ptyPollEvents(stdout_actor.pendingControlBytes());
        var pfds = [4]c.struct_pollfd{
            .{ .fd = transport.stdinPollFd(terminal.stdin_fd), .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (pty_events != 0) session_host.getMasterFd() orelse -1 else -1, .events = pty_events, .revents = 0 },
            .{ .fd = lifecycle.readFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = -1, .events = 0, .revents = 0 },
        };

        const pr = c.poll(&pfds, 4, 10);
        if (pr < 0) {
            const e = std.posix.errno(-1);
            if (e == .INTR) continue;
            return error.IoError;
        }

        lifecycle.consumeWakeRevents(pfds[2].revents);
        try stepStdoutCommitted(stdout_actor, shared_model);
        try stepInput(&transport, session_host, terminal, &pfds);
        try stepPtyOutput(&transport, session_host, shared_model, render_thread, forwarder, stdout_actor, &pfds);
        try stepStdoutCommitted(stdout_actor, shared_model);

        if (try refreshAndMaybeExit(session_host)) |status| return status;
    }
}

const VptyRuntime = struct {
    allocator: std.mem.Allocator,
    child_argv: []const []const u8,
    mode: RunMode,
    viewport: Viewport,
    viewport_intent: ViewportIntent,
    terminal: vpty_terminal.TerminalMode,
    forwarder: side_effects.SideEffectForwarder,
    stdout_actor: StdoutThread,
    session_host: host.SessionHost,
    shared_model: SharedTerminalModel,
    render_thread: RenderThread,
    lifecycle: RuntimeLifecycle,

    fn init(self: *VptyRuntime, allocator: std.mem.Allocator, io: anytype, child_argv: []const []const u8, mode: RunMode, viewport_override: Viewport, viewport_intent: ViewportIntent) !void {
        var terminal = vpty_terminal.TerminalMode.init(c.STDIN_FILENO, c.STDOUT_FILENO);
        errdefer terminal.restore();

        var forwarder = side_effects.SideEffectForwarder.init(allocator);
        errdefer forwarder.deinit();

        var stdout_actor = StdoutThread.init(allocator, io);
        errdefer stdout_actor.deinit();

        const size = terminal.currentSize() catch vpty_terminal.Size{ .rows = 24, .cols = 80 };
        const resolved = switch (mode) {
            .fullscreen => Viewport.init(0, 0, size.rows, size.cols),
            .bounded => resolveViewport(viewport_override, size),
        };
        const target_rows = switch (mode) {
            .fullscreen => resolved.rows,
            .bounded => if (viewport_intent.rows_explicit) viewport_override.rows else resolved.rows,
        };
        const target_cols = switch (mode) {
            .fullscreen => resolved.cols,
            .bounded => if (viewport_intent.cols_explicit) viewport_override.cols else resolved.cols,
        };
        const viewport = Viewport.init(
            resolved.origin_row,
            resolved.origin_col,
            target_rows,
            target_cols,
        );

        var session_host = try host.SessionHost.init(allocator, .{
            .argv = child_argv,
            .rows = viewport.rows,
            .cols = viewport.cols,
        });
        errdefer session_host.deinit();

        var shared_model = SharedTerminalModel.init(io, try TerminalModel.initWithMode(viewport.rows, viewport.cols, graphemeModeFromEnv()));
        errdefer shared_model.model.deinit();

        self.* = .{
            .allocator = allocator,
            .child_argv = child_argv,
            .mode = mode,
            .viewport = viewport,
            .viewport_intent = viewport_intent,
            .terminal = terminal,
            .forwarder = forwarder,
            .stdout_actor = stdout_actor,
            .session_host = session_host,
            .shared_model = shared_model,
            .render_thread = undefined,
            .lifecycle = .{},
        };
        self.render_thread = RenderThread.init(
            allocator,
            &self.shared_model,
            &self.stdout_actor,
            viewport,
        );
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
        const update = self.shared_model.model.forceFullDamage();
        self.shared_model.unlock();

        self.render_thread.reset();
        self.render_thread.publishModelChanged(update.asModelChanged());
    }

    fn run(self: *VptyRuntime) !u8 {
        try self.session_host.start();
        if (self.mode == .fullscreen) try self.terminal.enterAltScreen();
        try self.terminal.enterRaw();
        try self.stdout_actor.start();
        errdefer self.stdout_actor.stopDiscardPending();
        try self.render_thread.start();
        errdefer self.render_thread.stop();

        self.primeRender();

        const signal_handlers = try self.lifecycle.install();
        defer signal_handlers.restore();

        const status = try pumpUntilExit(&self.lifecycle, &self.session_host, &self.shared_model, &self.render_thread, &self.terminal, self.mode, self.viewport, self.viewport_intent, &self.forwarder, &self.stdout_actor);
        self.render_thread.shutdownActor();
        self.render_thread.stop();
        if (self.mode == .fullscreen) {
            self.stdout_actor.stopDiscardPending();
            self.terminal.restore();
        } else {
            self.stdout_actor.stop();
            self.terminal.restore();
        }
        self.lifecycle.clearPendingResize();
        _ = self.session_host.close() catch {};
        if (self.stdout_actor.output_failed.load(.seq_cst)) return error.OutputClosed;
        return childExitCode(status);
    }
};

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    if (argv.len < 3) {
        usage();
        return error.InvalidArgs;
    }

    var origin_row: ?u16 = null;
    var origin_col: ?u16 = null;
    var rows: ?u16 = null;
    var cols: ?u16 = null;
    var sep_idx: ?usize = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            sep_idx = i;
            break;
        }
        if (std.mem.eql(u8, arg, "--origin-row") or std.mem.eql(u8, arg, "--origin-col") or std.mem.eql(u8, arg, "--rows") or std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= argv.len) {
                err("vpty: missing value for {s}\n", .{arg});
                return error.InvalidArgs;
            }
            const value = try parseU16Flag(arg, argv[i]);
            if (std.mem.eql(u8, arg, "--origin-row")) origin_row = value
            else if (std.mem.eql(u8, arg, "--origin-col")) origin_col = value
            else if (std.mem.eql(u8, arg, "--rows")) rows = value
            else cols = value;
            continue;
        }

        err("vpty: unknown option: {s}\n", .{arg});
        usage();
        return error.InvalidArgs;
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

    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, argv[(cmd_start + 1)..]);

    const has_viewport_flags = origin_row != null or origin_col != null or rows != null or cols != null;

    return .{
        .mode = if (has_viewport_flags) .bounded else .fullscreen,
        .viewport = Viewport.init(origin_row orelse 0, origin_col orelse 0, rows orelse 0, cols orelse 0),
        .viewport_intent = .{
            .rows_explicit = rows != null,
            .cols_explicit = cols != null,
        },
        .child_argv = result,
    };
}

fn allocArgs(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw = try args.toSlice(arena);
    const argv = try arena.alloc([]const u8, raw.len);
    for (raw, 0..) |arg, i| argv[i] = arg;
    return argv;
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const argv = try allocArgs(init.arena.allocator(), init.minimal.args);

    var parsed = parseArgs(allocator, argv) catch |parse_err| switch (parse_err) {
        error.InvalidArgs => return 1,
        else => return parse_err,
    };
    defer parsed.deinit(allocator);

    var runtime: VptyRuntime = undefined;
    try runtime.init(allocator, .{}, parsed.child_argv.items, parsed.mode, parsed.viewport, parsed.viewport_intent);
    defer runtime.deinit();
    return runtime.run();
}

test "viewerSizeChanged detects same-size WINCH as repaint-only" {
    try std.testing.expect(!viewerSizeChanged(.{ .rows = 24, .cols = 80 }, 24, 80));
    try std.testing.expect(viewerSizeChanged(.{ .rows = 24, .cols = 80 }, 25, 80));
    try std.testing.expect(viewerSizeChanged(.{ .rows = 24, .cols = 80 }, 24, 81));
    try std.testing.expect(viewerSizeChanged(null, 24, 80));
}

test "resolveViewport preserves origin while defaulting missing dimensions to remaining space" {
    const resolved = resolveViewport(
        Viewport.init(10, 5, 0, 0),
        .{ .rows = 24, .cols = 80 },
    );

    try std.testing.expectEqual(@as(u16, 10), resolved.origin_row);
    try std.testing.expectEqual(@as(u16, 5), resolved.origin_col);
    try std.testing.expectEqual(@as(u16, 14), resolved.rows);
    try std.testing.expectEqual(@as(u16, 75), resolved.cols);
}

test "resolveViewport clips explicit dimensions to remaining physical bounds" {
    const resolved = resolveViewport(
        Viewport.init(20, 70, 10, 20),
        .{ .rows = 24, .cols = 80 },
    );

    try std.testing.expectEqual(@as(u16, 20), resolved.origin_row);
    try std.testing.expectEqual(@as(u16, 70), resolved.origin_col);
    try std.testing.expectEqual(@as(u16, 4), resolved.rows);
    try std.testing.expectEqual(@as(u16, 10), resolved.cols);
}

test "parseArgs marks explicit rows and cols intent" {
    const argv = [_][]const u8{ "vpty", "--origin-row", "5", "--rows", "10", "--cols", "40", "--", "bash" };
    var parsed = try parseArgs(std.testing.allocator, argv[0..]);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(RunMode.bounded, parsed.mode);
    try std.testing.expect(parsed.viewport_intent.rows_explicit);
    try std.testing.expect(parsed.viewport_intent.cols_explicit);
    try std.testing.expectEqual(@as(u16, 5), parsed.viewport.origin_row);
    try std.testing.expectEqual(@as(u16, 10), parsed.viewport.rows);
    try std.testing.expectEqual(@as(u16, 40), parsed.viewport.cols);
}

test "parseArgs defaults to fullscreen mode when no viewport flags are provided" {
    const argv = [_][]const u8{ "vpty", "--", "bash" };
    var parsed = try parseArgs(std.testing.allocator, argv[0..]);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(RunMode.fullscreen, parsed.mode);
    try std.testing.expect(!parsed.viewport_intent.rows_explicit);
    try std.testing.expect(!parsed.viewport_intent.cols_explicit);
}

test "parseArgs treats origin-only viewport flags as bounded mode" {
    const argv = [_][]const u8{ "vpty", "--origin-row", "5", "--origin-col", "10", "--", "bash" };
    var parsed = try parseArgs(std.testing.allocator, argv[0..]);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(RunMode.bounded, parsed.mode);
    try std.testing.expectEqual(@as(u16, 5), parsed.viewport.origin_row);
    try std.testing.expectEqual(@as(u16, 10), parsed.viewport.origin_col);
    try std.testing.expectEqual(@as(u16, 0), parsed.viewport.rows);
    try std.testing.expectEqual(@as(u16, 0), parsed.viewport.cols);
    try std.testing.expect(!parsed.viewport_intent.rows_explicit);
    try std.testing.expect(!parsed.viewport_intent.cols_explicit);
}

test "vpty input pauses at its limit and resumes without losing bytes" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    try fd_stream.setNonBlocking(fds[0]);

    var transport = TransportState{};
    defer transport.deinit(std.heap.page_allocator);
    // Leave less than one read chunk free to exercise the exact boundary.
    const prefix = try std.testing.allocator.alloc(u8, 256 * 1024 - 3);
    defer std.testing.allocator.free(prefix);
    @memset(prefix, 'a');
    try transport.input_tx.append(std.heap.page_allocator, prefix);
    const input = "0123456789";
    try std.testing.expectEqual(@as(isize, input.len), c.write(fds[1], input.ptr, input.len));
    try transport.ingestStdin(fds[0]);
    try std.testing.expectEqual(@as(usize, 256 * 1024), transport.input_tx.len());
    try std.testing.expectEqual(@as(usize, 256 * 1024), transport.input_tx.capacity());
    try std.testing.expectEqualStrings("012", transport.input_tx.readableSlice()[prefix.len..]);
    try std.testing.expectEqual(@as(c_int, -1), transport.stdinPollFd(fds[0]));

    // Readable stdin must not grow the queue or wake poll while the child stalls.
    for (0..100) |_| try transport.ingestStdin(fds[0]);
    var pollfds = [_]std.c.pollfd{.{ .fd = transport.stdinPollFd(fds[0]), .events = c.POLLIN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&pollfds, 1, 0));
    try std.testing.expectEqual(@as(usize, 256 * 1024), transport.input_tx.len());
    try std.testing.expectEqual(@as(usize, 256 * 1024), transport.input_tx.capacity());

    // Simulate delivery of the prefix; the remaining bytes must stay in order.
    transport.input_tx.discard(prefix.len);
    try std.testing.expectEqual(fds[0], transport.stdinPollFd(fds[0]));
    try transport.ingestStdin(fds[0]);
    try std.testing.expectEqualStrings(input, transport.input_tx.readableSlice());
    try std.testing.expectEqual(@as(usize, 256 * 1024), transport.input_tx.capacity());
}

test "vpty input EOF disables stdin polling without discarding queued bytes" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    _ = c.close(fds[1]);
    var transport = TransportState{};
    defer transport.deinit(std.heap.page_allocator);
    try transport.input_tx.append(std.heap.page_allocator, "pending");
    try transport.ingestStdin(fds[0]);
    try std.testing.expectEqual(@as(c_int, -1), transport.stdinPollFd(fds[0]));
    try std.testing.expectEqualStrings("pending", transport.input_tx.readableSlice());
    try std.testing.expect((transport.ptyPollEvents(0) & c.POLLOUT) != 0);
}

test "vpty output backpressure preserves input polling and drains buffered output first" {
    var transport = TransportState{};
    defer transport.deinit(std.heap.page_allocator);
    try std.testing.expect((transport.ptyPollEvents(0) & c.POLLIN) != 0);
    try std.testing.expectEqual(@as(c_short, 0), transport.ptyPollEvents(2 * 1024 * 1024));
    try transport.input_tx.append(std.heap.page_allocator, "input");
    try std.testing.expectEqual(@as(c_short, c.POLLOUT), transport.ptyPollEvents(2 * 1024 * 1024));
    try transport.output_rx.append(std.heap.page_allocator, "output");
    try std.testing.expectEqual(@as(c_short, c.POLLOUT), transport.ptyPollEvents(0));
    transport.output_rx.clear();
    try std.testing.expectEqual(@as(c_short, c.POLLIN | c.POLLOUT), transport.ptyPollEvents(0));
}

test "vpty output parsing pauses at control high water and resumes in order" {
    var transport = TransportState{};
    defer transport.deinit(std.heap.page_allocator);
    var stdout_actor = StdoutThread.init(std.testing.allocator, {});
    defer stdout_actor.deinit();
    var shared_model = SharedTerminalModel.init({}, try TerminalModel.init(24, 80));
    defer shared_model.model.deinit();
    var render_thread = RenderThread.init(std.testing.allocator, &shared_model, &stdout_actor, .{ .origin_row = 1, .origin_col = 1, .rows = 24, .cols = 80 });
    defer render_thread.deinit();
    var forwarder = side_effects.SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    // One parsed chunk crosses the threshold; all later chunks must wait.
    const queued = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024 - 1);
    defer std.testing.allocator.free(queued);
    @memset(queued, 'x');
    try stdout_actor.enqueueControl(.{ .bytes = queued });
    const control = "\x1b[?2004h";
    for (0..1024) |_| try transport.output_rx.append(std.heap.page_allocator, control);
    try transport.processOutput(&shared_model, &render_thread, &forwarder, &stdout_actor);
    try std.testing.expectEqual(@as(usize, 4096), transport.output_rx.len());
    try std.testing.expectEqual(queued.len + 4096, stdout_actor.pendingControlBytes());
    for (0..100) |_| try transport.processOutput(&shared_model, &render_thread, &forwarder, &stdout_actor);
    try std.testing.expectEqual(@as(usize, 4096), transport.output_rx.len());
    try std.testing.expectEqual(queued.len + 4096, stdout_actor.pendingControlBytes());

    // Consume the mailbox as stdout would, then let the remaining chunk parse.
    var count: usize = 0;
    while (stdout_actor.control_queue.pop()) |chunk| {
        defer std.testing.allocator.free(chunk.bytes);
        try std.testing.expectEqualStrings(if (count == 0) queued else control, chunk.bytes);
        _ = stdout_actor.shared.pending_control_bytes.fetchSub(chunk.bytes.len, .seq_cst);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 513), count);
    try transport.processOutput(&shared_model, &render_thread, &forwarder, &stdout_actor);
    try std.testing.expect(transport.output_rx.isEmpty());
    try std.testing.expectEqual(@as(usize, 4096), stdout_actor.pendingControlBytes());
    count = 0;
    while (stdout_actor.control_queue.pop()) |chunk| {
        defer std.testing.allocator.free(chunk.bytes);
        try std.testing.expectEqualStrings(control, chunk.bytes);
        _ = stdout_actor.shared.pending_control_bytes.fetchSub(chunk.bytes.len, .seq_cst);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 512), count);
    try std.testing.expectEqual(@as(usize, 0), stdout_actor.pendingControlBytes());
}
