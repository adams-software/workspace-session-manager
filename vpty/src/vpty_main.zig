const std = @import("std");
const c = @cImport({
    @cInclude("sys/wait.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("string.h");
});
const host = @import("host");
const vpty_terminal = @import("vpty_terminal");
const vpty_render = @import("vpty_render");
var winch_changed: bool = false;
var wake_pipe: [2]c_int = .{ -1, -1 };

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
    const msg = switch (sig) {
        c.SIGINT => "\x1b[?25h\n",
        c.SIGTERM => "\x1b[?25h\n",
        else => "\x1b[?25h\n",
    };
    _ = c.write(c.STDOUT_FILENO, msg.ptr, msg.len);
    _ = c.signal(sig, c.SIG_DFL);
    _ = c.raise(sig);
}

fn onViewerAttach(
    session_host: *host.SessionHost,
    rows: u16,
    cols: u16,
) void {
    session_host.applySessionSize(.{ .cols = cols, .rows = rows }) catch {};
    if (session_host.terminal_state) |*ts| {
        ts.forceFullDamage();
    }
    vpty_render.reset();
    vpty_render.doRender();
}

fn onViewerResize(
    session_host: *host.SessionHost,
    rows: u16,
    cols: u16,
) void {
    session_host.applySessionSize(.{ .cols = cols, .rows = rows }) catch {};
    if (session_host.terminal_state) |*ts| {
        ts.forceFullDamage();
    }
    vpty_render.renderDamaged();
}

fn applyViewerSize(
    session_host: *host.SessionHost,
    rows: u16,
    cols: u16,
) void {
    session_host.applySessionSize(.{ .cols = cols, .rows = rows }) catch return;

    if (session_host.terminal_state) |*ts| {
        ts.forceFullDamage();
    }

    vpty_render.reset();
    vpty_render.doRender();
}

fn handleSigwinch(_: c_int) callconv(.c) void {
    winch_changed = true;
    if (wake_pipe[1] >= 0) {
        const b: u8 = 1;
        _ = c.write(wake_pipe[1], &b, 1);
    }
}

fn pumpUntilExit(session_host: *host.SessionHost, terminal: *vpty_terminal.TerminalMode) !host.ExitStatus {
    var stdin_open = true;
    var buf: [4096]u8 = undefined;

    while (true) {
        if (winch_changed) {
            winch_changed = false;
            const size = terminal.currentSize() catch vpty_terminal.Size{ .rows = 24, .cols = 80 };
            applyViewerSize(session_host, size.rows, size.cols);
        }

        var pfds = [3]c.struct_pollfd{
            .{ .fd = if (stdin_open) terminal.stdin_fd else -1, .events = if (stdin_open) c.POLLIN else 0, .revents = 0 },
            .{ .fd = session_host.getMasterFd() orelse -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = wake_pipe[0], .events = c.POLLIN, .revents = 0 },
        };

        const pr = c.poll(&pfds, 2, 10);
        if (pr < 0) {
            const e = std.c.errno(-1);
            if (e == .INTR) continue;
            return error.IoError;
        }

        // 1. User input -> child PTY
        if (stdin_open and (pfds[0].revents & c.POLLIN) != 0) {
            const n = c.read(terminal.stdin_fd, &buf, buf.len);
            if (n < 0) return error.IoError;
            if (n == 0) {
                stdin_open = false;
            } else {
                try session_host.writePty(buf[0..@intCast(n)]);
            }
        }

        // 2. Child output -> vterm only; renderer paints stdout
        if ((pfds[1].revents & c.POLLIN) != 0) {
            while (true) {
                const bytes = session_host.readPty(std.heap.page_allocator, 4096, 0) catch |e| switch (e) {
                    host.Error.InvalidState, host.Error.NotStarted, host.Error.Closed => &[_]u8{},
                    else => return e,
                };
                defer if (@TypeOf(bytes) != *const [0]u8) std.heap.page_allocator.free(bytes);
                if (@TypeOf(bytes) == *const [0]u8 or bytes.len == 0) break;

                if (session_host.terminal_state) |*ts| {
                    ts.feed(bytes);
                }

                var more_pfd = c.struct_pollfd{
                    .fd = session_host.getMasterFd() orelse -1,
                    .events = c.POLLIN,
                    .revents = 0,
                };
                const more_pr = c.poll(&more_pfd, 1, 0);
                if (more_pr <= 0 or (more_pfd.revents & c.POLLIN) == 0) break;
            }
        }
        if ((pfds[2].revents & c.POLLIN) != 0) {
            var tmp: [64]u8 = undefined;
            while (true) {
                const n = c.read(wake_pipe[0], &tmp, tmp.len);
                if (n <= 0 or n < tmp.len) break;
            }
        }

        // Render once per poll cycle
        vpty_render.doRender();

        session_host.refresh() catch |e| switch (e) {
            host.Error.InvalidState, host.Error.NotStarted, host.Error.Closed => return e,
            else => {},
        };

        if (session_host.getState() == .exited) {
            return session_host.getExitStatus() orelse host.ExitStatus{};
        }
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

    const size = terminal.currentSize() catch vpty_terminal.Size{ .rows = 24, .cols = 80 };

    var session_host = try host.SessionHost.init(allocator, .{
        .argv = child_argv,
        .enable_terminal_state = true,
        .rows = size.rows,
        .cols = size.cols,
        .replay_capacity = 0,
    });
    defer session_host.deinit();

    try session_host.start();
    try terminal.enterRaw();

    if (session_host.terminal_state) |*ts| {
        vpty_render.setGlobalSessionHost(&session_host);
        ts.setRenderCallback(vpty_render.renderDamaged);
        ts.forceFullDamage();
    }
    vpty_render.reset();
    vpty_render.doRender();

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

    const status = try pumpUntilExit(&session_host, &terminal);
    _ = session_host.close() catch {};
    return childExitCode(status);
}
