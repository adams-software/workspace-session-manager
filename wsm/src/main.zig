const std = @import("std");
const ui_state = @import("ui_state.zig");
const bar_layout = @import("bar_layout.zig");
const bar_render = @import("bar_render.zig");
const policy = @import("policy.zig");
const executor_mod = @import("executor.zig");
const cli_main = @import("cli_main.zig");
const enterRawMode = @import("ptyio_raw_mode").enterRawMode;
const getTtySize = @import("ptyio_tty_size").getTtySize;

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

const ENTER_ALT_SCREEN = "\x1b[?1049h\x1b[2J\x1b[H\x1b[?25h";
const EXIT_RESET = "\x1b[0m\x1b[?25h\x1b[?1049l\x1b(B";

const Error = error{
    TerminalUnavailable,
    RawModeFailed,
    IoctlFailed,
    PollFailed,
    UnsupportedKeySpec,
    Unexpected,
};

const KeyBinding = struct {
    ch: u8,
    ctrl: bool = false,

    fn parse(spec: []const u8) !KeyBinding {
        if (spec.len == 6 and std.ascii.startsWithIgnoreCase(spec, "ctrl-")) {
            const tail = std.ascii.toLower(spec[5]);
            if (tail >= 'a' and tail <= 'z') return .{ .ch = tail, .ctrl = true };
        }
        if (spec.len == 1) return .{ .ch = spec[0] };
        return Error.UnsupportedKeySpec;
    }
};

const TerminalState = struct {
    tty_fd: c_int,
    raw_mode: @import("ptyio_raw_mode").RawModeGuard,

    fn init() !TerminalState {
        const tty_fd = std.posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return Error.TerminalUnavailable;
        errdefer std.posix.close(tty_fd);

        var raw_mode = enterRawMode(tty_fd) catch return Error.RawModeFailed;
        errdefer raw_mode.restore();

        return .{ .tty_fd = tty_fd, .raw_mode = raw_mode };
    }

    fn deinit(self: *TerminalState) void {
        self.raw_mode.restore();
        std.posix.close(self.tty_fd);
    }
};

const ResizeState = struct {
    var pending: bool = false;
};

const OuterSize = struct {
    cols: u16,
    rows: u16,
};

fn debugEnabled() bool {
    return std.posix.getenv("WSM_DEBUG") != null;
}

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled()) return;
    std.debug.print(fmt, args);
}

const App = struct {
    should_exit: bool = false,
    allocator: std.mem.Allocator,
    term: *TerminalState,
    hotkey: KeyBinding,
    bar_state: ui_state.State,
    provider: policy.Provider,
    executor: executor_mod.Executor,
    size: OuterSize,
    layout: bar_layout.Layout,

    fn init(allocator: std.mem.Allocator, term: *TerminalState, initial_mode: ?cli_main.Mode) !App {
        var bar_state = ui_state.State.init(allocator);
        errdefer bar_state.deinit();

        const root_env = std.posix.getenv("WSM_ROOT") orelse ".";
        const root = try std.fs.realpathAlloc(allocator, root_env);
        defer allocator.free(root);

        var provider = try policy.Provider.init(allocator, root, null);
        errdefer provider.deinit();
        try provider.refresh();

        const size = try currentOuterSize(term);
        const layout_state = bar_layout.compute(size.cols, size.rows, bar_state.mode);

        var app: App = .{
            .should_exit = false,
            .allocator = allocator,
            .term = term,
            .hotkey = try KeyBinding.parse("ctrl-g"),
            .bar_state = bar_state,
            .provider = provider,
            .executor = try executor_mod.Executor.init(allocator, root),
            .size = size,
            .layout = layout_state,
        };

        if (initial_mode) |mode| {
            switch (mode) {
                .interactive_attach => |id| {
                    const owned = try allocator.dupe(u8, id);
                    defer allocator.free(owned);
                    try app.handleAction(.{ .attach = owned });
                },
                .interactive_create_attach => |id| {
                    const owned = try allocator.dupe(u8, id);
                    defer allocator.free(owned);
                    try app.handleAction(.{ .create = owned });
                },
                else => {},
            }
            _ = app.executor.pumpAttachedOutput(term.tty_fd) catch {};
            if (!app.executor.isInteractiveAttached()) {
                app.should_exit = true;
            }
        }

        return app;
    }

    fn deinit(self: *App) void {
        self.executor.deinit();
        self.provider.deinit();
        self.bar_state.deinit();
    }

    fn refreshPolicy(self: *App) !void {
        try self.provider.refresh();
        _ = self.bar_state.updateExternalContext(self.provider.externalContext());
    }

    fn render(self: *App) !void {
        try self.renderBody();
        try self.renderBar();
    }

    fn renderBody(self: *App) !void {
        _ = self;
        return;
    }

    fn renderBar(self: *App) !void {
        if (!self.layout.bar_visible or self.layout.bar_row == null) return;

        const line = try bar_render.buildLine(self.allocator, &self.bar_state, self.provider.externalContext(), self.layout.outer_cols);
        defer self.allocator.free(line);

        var out = std.ArrayList(u8){};
        defer out.deinit(self.allocator);
        const row = self.layout.bar_row.? + 1;
        try out.writer(self.allocator).print("\x1b7\x1b[{d};1H\x1b[0m", .{row});
        try out.appendSlice(self.allocator, line);
        try out.appendSlice(self.allocator, "\x1b8");
        try writeAll(self.term.tty_fd, out.items);
    }

    fn clearBar(self: *App) !void {
        if (!self.layout.bar_visible or self.layout.bar_row == null) return;
        var out = std.ArrayList(u8){};
        defer out.deinit(self.allocator);
        const row = self.layout.bar_row.? + 1;
        try out.writer(self.allocator).print("\x1b7\x1b[{d};1H\x1b[0m\x1b[2K\x1b8", .{row});
        try writeAll(self.term.tty_fd, out.items);
    }

    fn handleResize(self: *App) !void {
        self.size = try currentOuterSize(self.term);
        self.layout = bar_layout.compute(self.size.cols, self.size.rows, self.bar_state.mode);
        _ = self.executor.forwardResize(self.layout.outer_cols, self.layout.main_rows) catch {};
        try self.render();
    }

    fn handleTTYInput(self: *App, bytes: []const u8) !bool {
        if (bytes.len == 0) return false;

        if (self.bar_state.mode == .passive) {
            if (keyFromInput(bytes, self.hotkey)) |key| {
                switch (key) {
                    .ctrl_g => {
                        try self.handleUiKey(key);
                        return true;
                    },
                    .ctrl_c => {
                        if (!self.executor.isInteractiveAttached()) {
                            try self.handleAction(.quit);
                            return true;
                        }
                    },
                    else => {},
                }
            }
            return try self.executor.forwardInput(bytes);
        }

        if (keyFromInput(bytes, self.hotkey)) |key| {
            try self.handleUiKey(key);
            return true;
        }

        return true;
    }

    fn handleUiKey(self: *App, key: ui_state.Key) !void {
        const result = self.bar_state.handleKey(self.provider.externalContext(), key);
        if (result.request_attach_candidates) |query| {
            try self.provider.refreshAttachCandidates(query);
        }
        _ = self.bar_state.updateExternalContext(self.provider.externalContext());
        self.layout = bar_layout.compute(self.size.cols, self.size.rows, self.bar_state.mode);
        if (result.rerender or result.action != null) try self.render();
        if (result.action) |action| {
            try self.handleAction(action);
            if (!self.should_exit) {
                try self.refreshPolicy();
                try self.render();
            }
        }
    }

    fn handleAction(self: *App, action: ui_state.Action) !void {
        if (action == .quit) {
            self.should_exit = true;
            return;
        }

        const resolved = try self.provider.resolveAction(action);
        const exec_result: executor_mod.Result = self.executor.run(&self.provider, resolved) catch |err| blk: {
            break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "action failed: {s}", .{@errorName(err)}) };
        };
        switch (exec_result) {
            .info => |msg| {
                defer self.allocator.free(msg);
                _ = self.bar_state.setExternalInfo(msg);
            },
            .err => |msg| {
                defer self.allocator.free(msg);
                _ = self.bar_state.setExternalError(msg);
            },
            .attached => |id| {
                defer self.allocator.free(id);
                try self.provider.setCurrentSession(id);
                _ = self.bar_state.setExternalInfo("attached");
                _ = self.executor.forwardResize(self.layout.outer_cols, self.layout.main_rows) catch {};
            },
            .detached => {
                try self.provider.setCurrentSession(null);
                _ = self.bar_state.setExternalInfo("detached");
            },
        }
    }
};

fn handleSigwinch(_: c_int) callconv(.c) void {
    ResizeState.pending = true;
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

fn keyFromInput(bytes: []const u8, hotkey: KeyBinding) ?ui_state.Key {
    if (bytes.len == 0) return null;
    const b = bytes[0];
    if (hotkey.ctrl and b >= 0x01 and b <= 0x1a and ('a' + (b - 1)) == hotkey.ch) return .ctrl_g;
    return ui_state.Key.fromByte(b);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    const args = if (argv.len > 1) argv[1..] else &.{};

    const mode = try cli_main.parseMode(allocator, args);
    defer mode.deinit(allocator);
    const nested_session = std.posix.getenv("WSM_SESSION_ID");
    if (nested_session != null) {
        switch (mode) {
            .interactive_attach, .interactive_create_attach => {
                const msg = "wsm: nested interactive sessions are not supported, use detached create or run from outside the session\n";
                try std.fs.File.stdout().writeAll(msg);
                return;
            },
            else => {},
        }
    }

    switch (mode) {
        .help, .list, .inspect, .cleanup, .create_detached, .kill => {
            const root = cli_main.resolveWorkspace(allocator, args) catch |err| {
                if (err == error.MissingWorkspace) {
                    try cli_main.printHelp(allocator, std.fs.File.stdout(), null, std.posix.getenv("WSM_SESSION_ID"));
                    return;
                }
                return err;
            };
            defer allocator.free(root);
            _ = try cli_main.runCommand(allocator, root, mode, std.fs.File.stdout());
            return;
        },
        .interactive_attach, .interactive_create_attach => try runInteractive(allocator, mode),
    }
}

fn runInteractive(allocator: std.mem.Allocator, mode: cli_main.Mode) !void {
    installSigwinchHandler();

    var term = try TerminalState.init();
    defer term.deinit();
    try writeAll(term.tty_fd, ENTER_ALT_SCREEN);

    var app = try App.init(allocator, &term, mode);
    defer app.deinit();
    defer writeAll(term.tty_fd, EXIT_RESET) catch {};
    defer app.clearBar() catch {};

    try app.render();

    var tty_buf: [256]u8 = undefined;
    while (!app.should_exit) {
        if (ResizeState.pending) {
            ResizeState.pending = false;
            try app.handleResize();
        }

        var pfds: [2]c.struct_pollfd = .{
            .{ .fd = term.tty_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = -1, .events = 0, .revents = 0 },
        };
        var nfds: c.nfds_t = 1;
        if (app.executor.attachedDataFd()) |data_fd| {
            pfds[1] = .{ .fd = data_fd, .events = c.POLLIN, .revents = 0 };
            nfds = 2;
        }

        const pr = c.poll(&pfds, nfds, 25);
        if (pr < 0) {
            const err = std.posix.errno(-1);
            if (err == .INTR) continue;
            return Error.PollFailed;
        }
        if (pr == 0) continue;

        if ((pfds[0].revents & c.POLLIN) != 0) {
            const n = c.read(term.tty_fd, &tty_buf, tty_buf.len);
            if (n > 0) {
                const used: usize = @intCast(n);
                _ = try app.handleTTYInput(tty_buf[0..used]);
            } else if (n < 0) {
                const err = std.posix.errno(-1);
                if (err != .AGAIN and err != .INTR) return Error.Unexpected;
            }
        }

        if (nfds > 1) {
            const rev = pfds[1].revents;
            if (rev != 0) debugLog("wsm poll attached fd={d} revents=0x{x}\n", .{ pfds[1].fd, rev });
            if ((rev & c.POLLNVAL) != 0) {
                std.debug.print("wsm attached data POLLNVAL fd={d}\n", .{pfds[1].fd});
                return Error.Unexpected;
            }
            if ((rev & (c.POLLHUP | c.POLLERR)) != 0) {
                const did_work = try app.executor.pumpAttachedOutput(term.tty_fd);
                debugLog("wsm pump after hup/err did_work={} attached={}\n", .{ did_work, app.executor.isInteractiveAttached() });
                if (!app.executor.isInteractiveAttached() and !did_work) {
                    app.should_exit = true;
                    continue;
                }
            }
            if ((rev & c.POLLIN) != 0) {
                const did_work = try app.executor.pumpAttachedOutput(term.tty_fd);
                debugLog("wsm pump after pollin did_work={} attached={}\n", .{ did_work, app.executor.isInteractiveAttached() });
                if (!app.executor.isInteractiveAttached() and !did_work) {
                    app.should_exit = true;
                    continue;
                }
            }
        }
    }
}
