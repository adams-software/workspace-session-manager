const std = @import("std");
const host = @import("host");
const host_runtime = @import("host_runtime");
const host_repl = @import("host_repl");
const session_server = @import("server");
const getTtySize = @import("ptyio_tty_size").getTtySize;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
});

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn usage() void {
    out(
        "NAME\n" ++
            "  msr - single-child foreground host\n\n" ++
            "USAGE\n" ++
            "  msr <socket-path> [--headless] [--size <cols>x<rows>] [--] <cmd...>\n\n" ++
            "BEHAVIOR\n" ++
            "  Starts one child process, binds one socket, accepts zero or one active\n" ++
            "  owner at a time, and exits when the child exits. The host cleans up its\n" ++
            "  socket path on exit. New attachers always replace the current owner.\n\n" ++
            "EXAMPLES\n" ++
            "  msr /tmp/dev.sock -- /bin/sh -i\n" ++
            "  msr /tmp/dev.sock --headless -- /bin/sh -i\n" ++
            "  msr /tmp/dev.sock --size 120x40 -- nvim\n",
        .{},
    );
}

const Parsed = struct {
    socket_path: []const u8,
    size: ?host.Size,
    headless: bool,
    child_argv: []const []const u8,
};

fn parseSize(text: []const u8) !host.Size {
    const x = std.mem.indexOfScalar(u8, text, 'x') orelse return error.InvalidArgs;
    const cols = try std.fmt.parseInt(u16, text[0..x], 10);
    const rows = try std.fmt.parseInt(u16, text[(x + 1)..], 10);
    if (cols == 0 or rows == 0) return error.InvalidArgs;
    return .{ .cols = cols, .rows = rows };
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Parsed {
    _ = allocator;
    if (argv.len < 2) return error.InvalidArgs;
    if (std.mem.eql(u8, argv[1], "-h") or std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "help")) {
        return error.ShowHelp;
    }

    const socket_path = argv[1];
    if (socket_path.len == 0) return error.InvalidArgs;

    var i: usize = 2;
    var size: ?host.Size = null;
    var headless = false;

    while (i < argv.len) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--headless")) {
            headless = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--size")) {
            if (i + 1 >= argv.len) return error.InvalidArgs;
            size = try parseSize(argv[i + 1]);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--size=")) {
            size = try parseSize(arg[7..]);
            i += 1;
            continue;
        }
        return error.InvalidArgs;
    }

    if (i >= argv.len) return error.InvalidArgs;

    return .{
        .socket_path = socket_path,
        .size = size,
        .headless = headless,
        .child_argv = argv[i..],
    };
}

fn mapExitSignal(text: ?[]const u8) host_runtime.Signal {
    if (text) |t| {
        if (std.mem.eql(u8, t, "INT")) return .int;
        if (std.mem.eql(u8, t, "KILL")) return .kill;
    }
    return .term;
}

const StdoutEventSink = struct {
    fn onEvent(_: ?*anyopaque, event: host_runtime.HostEvent) void {
        var stdout = std.fs.File.stdout().writer(&.{});
        host_runtime.writeEventLine(&stdout.interface, event) catch {};
    }
};

fn applyChildResize(child: *host.PtyChildHost, size: host_runtime.Size) !void {
    try child.applySize(.{ .cols = size.cols, .rows = size.rows });
}

fn runHost(allocator: std.mem.Allocator, parsed: Parsed) !u8 {
    const initial_size = parsed.size orelse blk: {
        if (getTtySize(std.posix.STDIN_FILENO)) |tty_size| {
            if (tty_size.cols != 0 and tty_size.rows != 0) {
                break :blk host.Size{ .cols = tty_size.cols, .rows = tty_size.rows };
            }
        } else |_| {}
        break :blk null;
    };

    var child = try host.PtyChildHost.init(allocator, .{
        .argv = parsed.child_argv,
        .cols = if (initial_size) |s| s.cols else null,
        .rows = if (initial_size) |s| s.rows else null,
    });
    defer child.deinit();

    try child.start();

    var server = session_server.SessionServer.init(allocator, &child);
    defer server.deinit();
    const event_sink: ?host_runtime.EventSink = if (parsed.headless)
        null
    else
        .{ .ctx = null, .onEventFn = StdoutEventSink.onEvent };
    try server.listenWithEventSink(parsed.socket_path, event_sink);
    if (child.pid == null or child.masterFd() == null) return error.InvalidState;
    try server.markReady();
    if (server.runtime) |*runtime| {
        if (initial_size) |s| try runtime.resize(s.cols, s.rows);
        if (child.pid) |pid| runtime.onChildStarted(pid);
    }

    var repl: ?host_repl.Repl = null;
    defer if (repl) |*r| r.deinit();
    if (!parsed.headless) {
        repl = host_repl.Repl.init(allocator);
        try repl.?.setup();
    }

    while (true) {
        _ = try server.step();
        try child.refresh();
        if (repl) |*r| {
            if (server.runtime) |*runtime| {
                const ResizeBridge = struct {
                    var child_ptr: *host.PtyChildHost = undefined;
                    fn call(size: host_runtime.Size) anyerror!void {
                        try applyChildResize(child_ptr, size);
                    }
                };
                ResizeBridge.child_ptr = &child;
                try r.step(runtime, ResizeBridge.call);
            }
        }

        switch (child.currentState()) {
            .running, .starting => {},
            .idle => {},
            .exited => {
                if (server.runtime) |*runtime| {
                    if (child.exitStatus()) |st| {
                        if (st.code) |code| runtime.onChildExitedCode(code) else runtime.onChildExitedSignal(mapExitSignal(st.signal));
                    } else {
                        runtime.onChildExitedCode(0);
                    }
                }
                return 0;
            },
            .closed => return 0,
        }

        if (server.runtime) |runtime| {
            if (runtime.state().host_phase == .exiting) {
                return 0;
            }
        }

        var pfds = [_]c.struct_pollfd{
            .{ .fd = server.listener_fd orelse -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = server.owner_fd orelse -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = child.masterFd() orelse -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = std.posix.STDIN_FILENO, .events = if (parsed.headless) 0 else c.POLLIN, .revents = 0 },
        };
        _ = c.poll(&pfds, pfds.len, 25);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parsed = parseArgs(allocator, argv) catch |e| {
        switch (e) {
            error.ShowHelp => {
                usage();
                return;
            },
            else => {
                usage();
                return std.process.exit(2);
            },
        }
    };

    const code = runHost(allocator, parsed) catch |e| {
        err("msr: {s}\n", .{@errorName(e)});
        return std.process.exit(1);
    };
    std.process.exit(code);
}
