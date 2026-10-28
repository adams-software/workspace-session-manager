const std = @import("std");
const ui_state = @import("ui_state.zig");
const menu_render = @import("menu_render.zig");
const menu_input = @import("menu_input.zig");
const policy = @import("policy.zig");
const executor_mod = @import("executor.zig");
const cli_main = @import("cli_main.zig");
const debug = @import("debug.zig");
const input_router = @import("input_router");
const enterRawMode = @import("ptyio_raw_mode").enterRawMode;
const getTtySize = @import("ptyio_tty_size").getTtySize;

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const ENTER_ALT_SCREEN = "\x1b[?1049h\x1b[2J\x1b[H\x1b[?25h";
const INTERACTION_MODE_RESET =
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l" ++
    "\x1b[?1005l\x1b[?1006l\x1b[?1015l" ++
    "\x1b[?1004l\x1b[?2004l\x1b[?2005l\x1b[?2006l\x1b[?1l";
const EXIT_RESET = INTERACTION_MODE_RESET ++ "\x1b[0m\x1b[?25h\x1b[?1049l\x1b(B";
const INPUT_PREFIX_TIMEOUT_MS = 50;
const MAX_DEFERRED_MENU_INPUT = 4096;

const Error = error{
    TerminalUnavailable,
    RawModeFailed,
    IoctlFailed,
    PollFailed,
    Unexpected,
};

const TerminalState = struct {
    tty_fd: c_int,
    raw_mode: @import("ptyio_raw_mode").RawModeGuard,

    fn init() !TerminalState {
        const tty_fd = std.c.open("/dev/tty", .{ .ACCMODE = .RDWR });
        if (tty_fd < 0) return Error.TerminalUnavailable;
        errdefer _ = c.close(tty_fd);

        var raw_mode = enterRawMode(tty_fd) catch return Error.RawModeFailed;
        errdefer raw_mode.restore();

        return .{ .tty_fd = tty_fd, .raw_mode = raw_mode };
    }

    fn deinit(self: *TerminalState) void {
        self.raw_mode.restore();
        _ = c.close(self.tty_fd);
    }
};

const ResizeState = struct {
    var pending = std.atomic.Value(bool).init(false);
};

const OuterSize = struct {
    cols: u16,
    rows: u16,
};

const PresentationPhase = enum {
    child,
    yielding,
    menu,
    resuming,
};

const App = struct {
    should_exit: bool = false,
    exit_message: ?[]u8 = null,
    allocator: std.mem.Allocator,
    term: *TerminalState,
    menu_state: ui_state.State,
    provider: policy.Provider,
    executor: executor_mod.Executor,
    size: OuterSize,
    input_router: input_router.Router,
    input_prefix_deadline_ms: ?u64 = null,
    menu_input_decoder: menu_input.Decoder = .{},
    menu_escape_deadline_ms: ?u64 = null,
    deferred_menu_input: std.ArrayList(u8) = .empty,
    presentation_phase: PresentationPhase = .child,

    fn init(allocator: std.mem.Allocator, term: *TerminalState, initial_mode: ?cli_main.Mode, root: []const u8) !App {
        var menu_state = ui_state.State.init(allocator);
        errdefer menu_state.deinit();

        var provider = try policy.Provider.init(allocator, root, null);
        errdefer provider.deinit();
        try provider.refresh();

        const size = try currentOuterSize(term);
        var app: App = .{
            .should_exit = false,
            .allocator = allocator,
            .term = term,
            .menu_state = menu_state,
            .provider = provider,
            .executor = try executor_mod.Executor.init(allocator, root),
            .size = size,
            .input_router = input_router.Router.init(0x07),
        };

        if (initial_mode) |mode| {
            try app.applyExecResult(try app.executor.bootstrapInteractive(&app.provider, mode));
            if (!app.should_exit) {
                try app.refreshPolicy();
            }
            if (!app.executor.isInteractiveAttached()) {
                app.should_exit = true;
            }
        }

        return app;
    }

    fn deinit(self: *App) void {
        if (self.exit_message) |msg| self.allocator.free(msg);
        self.deferred_menu_input.deinit(self.allocator);
        self.executor.deinit();
        self.provider.deinit();
        self.menu_state.deinit();
    }

    fn refreshPolicy(self: *App) !void {
        try self.provider.refresh();
        _ = self.menu_state.updateExternalContext(self.provider.externalContext());
    }

    fn render(self: *App) !void {
        if (self.presentation_phase != .menu) return;
        const frame = try menu_render.buildFrame(self.allocator, &self.menu_state, self.provider.menuModel(), self.size.cols, self.size.rows);
        defer self.allocator.free(frame);
        try writeAll(self.term.tty_fd, frame);
    }

    fn handleResize(self: *App) !void {
        self.size = try currentOuterSize(self.term);
        _ = self.executor.forwardResize(self.size.cols, self.size.rows) catch {};
        try self.render();
    }

    fn handleTTYInput(self: *App, bytes: []const u8) !bool {
        if (bytes.len == 0) return false;
        return switch (self.presentation_phase) {
            .child => self.handleChildInput(bytes),
            .yielding => blk: {
                try self.queueMenuInput(bytes);
                break :blk true;
            },
            .menu => blk: {
                try self.handleUiInput(bytes);
                break :blk true;
            },
            // Input read before vpty's resume boundary still belongs to the
            // closing menu. Discard it so a cancellation key or its suffix can
            // never become child input.
            .resuming => true,
        };
    }

    fn handleChildInput(self: *App, bytes: []const u8) !bool {
        if (!self.executor.supportsPresentation()) return self.executor.forwardInput(bytes);

        var child_output: [256 + input_router.max_deferred_bytes]u8 = undefined;
        if (bytes.len > 256) return error.Unexpected;
        const routed = self.input_router.route(bytes, &child_output);
        self.input_prefix_deadline_ms = if (self.input_router.hasPending()) (try monotonicMs()) + INPUT_PREFIX_TIMEOUT_MS else null;
        if (routed.child_len > 0) _ = try self.executor.forwardInput(child_output[0..routed.child_len]);
        if (!routed.hotkey) return routed.child_len > 0;

        try self.executor.requestPresentation(.request_yield);
        self.presentation_phase = .yielding;
        self.input_prefix_deadline_ms = null;
        try self.queueMenuInput(bytes[routed.consumed..]);
        return true;
    }

    fn queueMenuInput(self: *App, bytes: []const u8) !void {
        const room = MAX_DEFERRED_MENU_INPUT -| self.deferred_menu_input.items.len;
        try self.deferred_menu_input.appendSlice(self.allocator, bytes[0..@min(room, bytes.len)]);
    }

    fn flushAmbiguousChildInput(self: *App) !void {
        if (self.presentation_phase != .child) return;
        const deadline = self.input_prefix_deadline_ms orelse return;
        if (try monotonicMs() < deadline) return;

        var pending: [input_router.max_deferred_bytes]u8 = undefined;
        const count = self.input_router.flushPending(&pending);
        self.input_prefix_deadline_ms = null;
        if (count > 0) _ = try self.executor.forwardInput(pending[0..count]);
    }

    fn flushAmbiguousMenuInput(self: *App) !void {
        if (self.presentation_phase != .menu) return;
        const deadline = self.menu_escape_deadline_ms orelse return;
        if (try monotonicMs() < deadline) return;

        self.menu_input_decoder.reset();
        self.menu_escape_deadline_ms = null;
        try self.handleUiKey(.esc);
    }

    fn beginResume(self: *App) !void {
        if (self.presentation_phase != .menu) return;
        self.menu_input_decoder.reset();
        self.menu_escape_deadline_ms = null;
        try self.executor.requestPresentation(.request_resume);
        self.presentation_phase = .resuming;
    }

    fn handleUiInput(self: *App, bytes: []const u8) !void {
        for (bytes) |byte| {
            const event = self.menu_input_decoder.feed(byte);
            self.menu_escape_deadline_ms = if (self.menu_input_decoder.hasPendingEscape()) (try monotonicMs()) + INPUT_PREFIX_TIMEOUT_MS else null;
            if (event) |resolved| switch (resolved) {
                .key => |key| try self.handleUiKey(key),
                .text => |value| try self.handleUiText(value.slice()),
            };
            if (self.presentation_phase != .menu) break;
        }
    }

    fn handleUiText(self: *App, value: []const u8) !void {
        try self.handleUiResult(self.menu_state.handleText(self.provider.externalContext(), value));
    }

    fn handleUiKey(self: *App, key: ui_state.Key) !void {
        try self.handleUiResult(self.menu_state.handleKey(self.provider.externalContext(), key));
    }

    fn handleUiResult(self: *App, result: ui_state.StepResult) !void {
        if (result.request_attach_candidates) |query| {
            try self.provider.refreshAttachCandidates(query);
        }
        _ = self.menu_state.updateExternalContext(self.provider.externalContext());
        if (result.action) |action| {
            try self.handleAction(action);
            if (!self.should_exit) {
                try self.refreshPolicy();
            }
        }
        if (self.should_exit) return;
        if (self.menu_state.mode == .passive and self.presentation_phase == .menu) {
            try self.beginResume();
            return;
        }
        if (result.rerender or result.action != null) try self.render();
    }

    fn handleAction(self: *App, action: ui_state.Action) !void {
        if (action == .quit) {
            self.should_exit = true;
            return;
        }

        if (action == .detach) {
            try self.applyExecResult(try self.executeResolvedAction(action));
            try writeAll(self.term.tty_fd, "\r\n");
            self.should_exit = true;
            return;
        }

        if (action == .logs) {
            try self.openLogsLocal();
            return;
        }

        try self.applyExecResult(try self.executeResolvedAction(action));
    }

    fn executeResolvedAction(self: *App, action: ui_state.Action) !executor_mod.Result {
        defer switch (action) {
            .attach => |target| self.allocator.free(target),
            .create => |name| self.allocator.free(name),
            else => {},
        };
        const resolved = self.provider.resolveAction(action) catch |err| return .{ .err = try std.fmt.allocPrint(self.allocator, "action failed: {s}", .{@errorName(err)}) };
        return self.executor.runSized(&self.provider, resolved, self.term.tty_fd, .{ .cols = self.size.cols, .rows = self.size.rows }) catch |err| .{ .err = try std.fmt.allocPrint(self.allocator, "action failed: {s}", .{@errorName(err)}) };
    }

    fn openLogsLocal(self: *App) !void {
        try writeAll(self.term.tty_fd, EXIT_RESET);
        self.term.raw_mode.restore();

        const exec_result: executor_mod.Result = self.executor.viewLogsLocal(&self.provider) catch |err| .{
            .err = try std.fmt.allocPrint(self.allocator, "logs failed: {s}", .{@errorName(err)}),
        };

        self.term.raw_mode = enterRawMode(self.term.tty_fd) catch return Error.RawModeFailed;
        try writeAll(self.term.tty_fd, ENTER_ALT_SCREEN);
        self.size = try currentOuterSize(self.term);
        _ = self.executor.forwardResize(self.size.cols, self.size.rows) catch {};
        try self.applyExecResult(exec_result);
        try self.refreshPolicy();
        try self.render();
    }

    fn applyExecResult(self: *App, exec_result: executor_mod.Result) anyerror!void {
        switch (exec_result) {
            .info => |msg| {
                defer self.allocator.free(msg);
                _ = self.menu_state.setExternalInfo(msg);
            },
            .err => |msg| {
                defer self.allocator.free(msg);
                _ = self.menu_state.setExternalError(msg);
                if (!self.executor.isInteractiveAttached()) {
                    if (self.exit_message) |existing| self.allocator.free(existing);
                    self.exit_message = try self.allocator.dupe(u8, msg);
                }
            },
            .attached => |id| {
                defer self.allocator.free(id);
                // The previous view may have left global input modes enabled.
                // The activated vpty restores its own modes on the resize below.
                try writeAll(self.term.tty_fd, INTERACTION_MODE_RESET);
                try self.provider.setCurrentSession(id);
                _ = self.menu_state.clearNotice();
                self.input_router.reset();
                self.input_prefix_deadline_ms = null;
                self.menu_input_decoder.reset();
                self.menu_escape_deadline_ms = null;
                self.deferred_menu_input.clearRetainingCapacity();
                self.presentation_phase = .child;
                try self.syncAttachedViewport("post-attach sync failed");
                if (self.menu_state.mode != .passive) {
                    if (self.executor.supportsPresentation()) {
                        try self.executor.requestPresentation(.request_yield);
                        self.presentation_phase = .yielding;
                    } else {
                        self.menu_state.enterPassive();
                    }
                }
            },
            .detached => {
                try self.provider.setCurrentSession(null);
                _ = self.menu_state.clearNotice();
                self.input_router.reset();
                self.input_prefix_deadline_ms = null;
                self.menu_input_decoder.reset();
                self.menu_escape_deadline_ms = null;
                self.deferred_menu_input.clearRetainingCapacity();
                self.presentation_phase = .child;
            },
            .idle => {},
            .presentation_yielded => try self.finishYield(),
            .presentation_resumed => self.presentation_phase = .child,
        }
    }

    fn finishYield(self: *App) !void {
        if (self.presentation_phase != .yielding) return;
        self.presentation_phase = .menu;
        self.menu_input_decoder.reset();
        self.menu_escape_deadline_ms = null;
        try writeAll(self.term.tty_fd, INTERACTION_MODE_RESET);
        if (self.menu_state.mode == .passive) {
            _ = self.menu_state.handleKey(self.provider.externalContext(), .ctrl_g);
        }

        if (self.deferred_menu_input.items.len == 0) {
            try self.render();
            return;
        }
        const deferred = try self.allocator.dupe(u8, self.deferred_menu_input.items);
        defer self.allocator.free(deferred);
        self.deferred_menu_input.clearRetainingCapacity();
        try self.handleUiInput(deferred);
        if (self.presentation_phase == .menu) try self.render();
    }

    fn handlePumpResult(self: *App, pump_result: executor_mod.Result) anyerror!void {
        switch (pump_result) {
            .detached => {
                if (!self.executor.isInteractiveAttached()) self.should_exit = true;
            },
            .idle => {},
            .err => {
                try self.applyExecResult(pump_result);
                if (!self.executor.isInteractiveAttached()) self.should_exit = true;
            },
            .info => |msg| {
                defer self.allocator.free(msg);
                debug.log("wsm pump info len={d} attached={}\n", .{ msg.len, self.executor.isInteractiveAttached() });
            },
            .presentation_yielded, .presentation_resumed => try self.applyExecResult(pump_result),
            .attached => |id| self.allocator.free(id),
        }
    }

    fn syncAttachedViewport(self: *App, comptime failure_context: []const u8) anyerror!void {
        _ = self.executor.forwardResize(self.size.cols, self.size.rows) catch {};
        const pump_result = self.executor.pumpAttachedOutput(&self.provider, self.term.tty_fd) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ failure_context, @errorName(err) });
            _ = self.menu_state.setExternalError(msg);
            self.allocator.free(msg);
            return;
        };
        try self.handlePumpResult(pump_result);
    }
};

fn handleSigwinch(_: c_int) callconv(.c) void {
    ResizeState.pending.store(true, .seq_cst);
}

fn installSigwinchHandler() void {
    _ = c.signal(c.SIGWINCH, handleSigwinch);
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (rc < 0) {
            const err = std.posix.errno(-1);
            if (err == .INTR or err == .AGAIN) continue;
            return Error.Unexpected;
        }
        off += @intCast(rc);
    }
}

fn currentOuterSize(term: *TerminalState) !OuterSize {
    const size = getTtySize(term.tty_fd) catch return Error.IoctlFailed;
    return .{
        .cols = if (size.cols == 0) 80 else size.cols,
        .rows = if (size.rows == 0) 24 else size.rows,
    };
}

fn monotonicMs() !u64 {
    var now: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) != 0) return Error.Unexpected;
    return @as(u64, @intCast(now.tv_sec)) * 1000 + @as(u64, @intCast(now.tv_nsec)) / std.time.ns_per_ms;
}

fn setRuntimeExitMessage(app: *App, allocator: std.mem.Allocator, comptime context: []const u8, err: anyerror) !void {
    const msg = try std.fmt.allocPrint(allocator, "wsm runtime error ({s}): {s}", .{ context, @errorName(err) });
    defer allocator.free(msg);
    if (app.exit_message) |existing| allocator.free(existing);
    app.exit_message = try allocator.dupe(u8, msg);
    _ = app.menu_state.setExternalError(msg);
    app.should_exit = true;
}

fn pumpAttachedOutputOrExit(app: *App, allocator: std.mem.Allocator, term: *TerminalState) !void {
    const pump_result = app.executor.pumpAttachedOutput(&app.provider, term.tty_fd) catch |err| {
        try setRuntimeExitMessage(app, allocator, "pump attached output", err);
        return;
    };
    app.handlePumpResult(pump_result) catch |err| {
        try setRuntimeExitMessage(app, allocator, "handle pump result", err);
    };
}

fn allocArgs(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw = try args.toSlice(arena);
    const argv = try arena.alloc([]const u8, raw.len);
    for (raw, 0..) |arg, i| argv[i] = arg;
    return argv;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try allocArgs(init.arena.allocator(), init.minimal.args);
    const args = if (argv.len > 1) argv[1..] else &.{};

    const mode = try cli_main.parseMode(allocator, args);
    defer mode.deinit(allocator);
    const nested_session = std.c.getenv("WSM_SESSION_ID");
    if (nested_session != null) {
        switch (mode) {
            .interactive_attach, .interactive_create_attach => {
                const msg = "wsm: nested interactive sessions are not supported, use detached create or run from outside the session\n";
                std.debug.print("{s}", .{msg});
                return;
            },
            else => {},
        }
    }

    const root = cli_main.resolveWorkspace(init.io, allocator, args) catch |err| {
        std.debug.print("wsm: cannot open session directory ({s}). Set WSM_ROOT to an existing directory you own, or use --workspace=<path>.\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(root);

    switch (mode) {
        .help, .list, .inspect, .log, .cleanup, .create_detached, .create_detached_alias, .kill => {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
            _ = try cli_main.runCommand(allocator, root, mode, &stdout_writer.interface);
            try stdout_writer.interface.flush();
            return;
        },
        .interactive_attach, .interactive_create_attach => try runInteractive(allocator, mode, root),
    }
}

fn runInteractive(allocator: std.mem.Allocator, mode: cli_main.Mode, root: []const u8) !void {
    installSigwinchHandler();

    var term = try TerminalState.init();
    errdefer {
        writeAll(term.tty_fd, EXIT_RESET) catch {};
        term.deinit();
    }
    try writeAll(term.tty_fd, ENTER_ALT_SCREEN);

    var app = try App.init(allocator, &term, mode, root);
    errdefer app.deinit();

    app.render() catch |err| {
        try setRuntimeExitMessage(&app, allocator, "render", err);
    };

    var tty_buf: [256]u8 = undefined;
    while (!app.should_exit) {
        app.flushAmbiguousChildInput() catch |err| {
            try setRuntimeExitMessage(&app, allocator, "flush terminal input", err);
            continue;
        };
        app.flushAmbiguousMenuInput() catch |err| {
            try setRuntimeExitMessage(&app, allocator, "flush menu input", err);
            continue;
        };
        if (ResizeState.pending.swap(false, .seq_cst)) {
            app.handleResize() catch |err| {
                try setRuntimeExitMessage(&app, allocator, "resize", err);
                continue;
            };
        }

        const transition_has_room = app.presentation_phase != .yielding or app.deferred_menu_input.items.len < MAX_DEFERRED_MENU_INPUT;
        const child_read_size = tty_buf.len + if (app.executor.supportsPresentation()) input_router.max_deferred_bytes else 0;
        const read_tty = transition_has_room and (app.presentation_phase != .child or app.executor.canAcceptAttachedInput(child_read_size));
        var tty_events: c_short = if (read_tty) c.POLLIN else 0;
        if (app.executor.hasPendingAttachedOutput()) tty_events |= c.POLLOUT;

        var pfds: [2]c.struct_pollfd = .{
            .{ .fd = term.tty_fd, .events = tty_events, .revents = 0 },
            .{ .fd = -1, .events = 0, .revents = 0 },
        };
        var nfds: c.nfds_t = 1;
        if (app.executor.attachedDataFd()) |data_fd| {
            pfds[1] = .{ .fd = data_fd, .events = app.executor.attachedPollEvents(), .revents = 0 };
            nfds = 2;
        }

        const pr = std.c.poll(@ptrCast(&pfds), nfds, 25);
        if (pr < 0) {
            const err = std.posix.errno(-1);
            if (err == .INTR) continue;
            return Error.PollFailed;
        }
        if (pr == 0) continue;

        // Hangup/error events are reported even while input reads are paused.
        if ((pfds[0].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            app.should_exit = true;
            continue;
        }

        if ((pfds[0].revents & c.POLLIN) != 0) {
            const n = c.read(term.tty_fd, &tty_buf, tty_buf.len);
            if (n > 0) {
                const used: usize = @intCast(n);
                _ = app.handleTTYInput(tty_buf[0..used]) catch |err| {
                    try setRuntimeExitMessage(&app, allocator, "tty input", err);
                    continue;
                };
            } else if (n == 0) {
                app.should_exit = true;
                continue;
            } else if (n < 0) {
                const err = std.posix.errno(-1);
                if (err != .AGAIN and err != .INTR) return Error.Unexpected;
            }
        }

        if ((pfds[0].revents & c.POLLOUT) != 0 and app.executor.hasPendingAttachedOutput()) {
            try pumpAttachedOutputOrExit(&app, allocator, &term);
            continue;
        }

        if (nfds > 1) {
            const rev = pfds[1].revents;
            if (rev != 0) debug.log("wsm poll attached fd={d} revents=0x{x}\n", .{ pfds[1].fd, rev });
            if ((rev & c.POLLNVAL) != 0) {
                std.debug.print("wsm attached data POLLNVAL fd={d}\n", .{pfds[1].fd});
                return Error.Unexpected;
            }
            if ((rev & (c.POLLHUP | c.POLLERR | c.POLLIN | c.POLLOUT)) != 0) {
                try pumpAttachedOutputOrExit(&app, allocator, &term);
            }
        }
    }

    const exit_message = if (app.exit_message) |msg| try allocator.dupe(u8, msg) else null;
    defer if (exit_message) |msg| allocator.free(msg);

    writeAll(term.tty_fd, EXIT_RESET) catch {};
    app.deinit();
    term.deinit();

    if (exit_message) |msg| {
        std.debug.print("{s}\n", .{msg});
    }
}
