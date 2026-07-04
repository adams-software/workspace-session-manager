const std = @import("std");
const host = @import("host");
const host_session = @import("host_session");
const host_runtime = @import("host_runtime");
const getTtySize = @import("ptyio_tty_size").getTtySize;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn progName(argv0: []const u8) []const u8 {
    return std.fs.path.basename(argv0);
}

fn usage(name: []const u8) void {
    out(
        "NAME\n" ++
            "  {s} - single-child foreground host\n\n" ++
            "USAGE\n" ++
            "  {s} <socket-path> [--headless] [--size <cols>x<rows>] [--] <cmd...>\n\n" ++
            "BEHAVIOR\n" ++
            "  Starts one child process, binds one socket, accepts zero or one active\n" ++
            "  owner at a time, and exits when the child exits. The host cleans up its\n" ++
            "  socket path on exit. New attachers always replace the current owner.\n\n" ++
            "EXAMPLES\n" ++
            "  {s} /tmp/dev.sock -- /bin/sh -i\n" ++
            "  {s} /tmp/dev.sock --headless -- /bin/sh -i\n" ++
            "  {s} /tmp/dev.sock --size 120x40 -- nvim\n",
        .{ name, name, name, name, name },
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

const StdoutEventSink = struct {
    const Ctx = struct {
        io: std.Io,
    };

    fn onEvent(ctx: ?*anyopaque, event: host_runtime.HostEvent) void {
        const sink: *Ctx = @ptrCast(@alignCast(ctx.?));
        var buf: [256]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(sink.io, &buf);
        host_runtime.writeEventLine(&stdout.interface, event) catch {};
        stdout.interface.flush() catch {};
    }
};

fn runHost(allocator: std.mem.Allocator, io: std.Io, parsed: Parsed) !u8 {
    const initial_size = parsed.size orelse blk: {
        if (getTtySize(std.posix.STDIN_FILENO)) |tty_size| {
            if (tty_size.cols != 0 and tty_size.rows != 0) {
                break :blk host.Size{ .cols = tty_size.cols, .rows = tty_size.rows };
            }
        } else |_| {}
        break :blk null;
    };

    var sink_ctx = StdoutEventSink.Ctx{ .io = io };
    const event_sink: ?host_runtime.EventSink = if (parsed.headless)
        null
    else
        .{ .ctx = &sink_ctx, .onEventFn = StdoutEventSink.onEvent };
    var session = try host_session.HostSession.init(allocator, io, .{
        .socket_path = parsed.socket_path,
        .initial_size = initial_size,
        .headless = parsed.headless,
        .child_argv = parsed.child_argv,
        .event_sink = event_sink,
    });
    defer session.deinit();

    while (true) {
        if (try session.step()) |code| return code;
        var pfds = [_]c.struct_pollfd{
            .{ .fd = session.listenerFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = session.ownerFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = session.masterFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = std.posix.STDIN_FILENO, .events = if (session.stdinPollEnabled()) c.POLLIN else 0, .revents = 0 },
        };
        _ = c.poll(&pfds, pfds.len, 25);
    }
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
    const name = if (argv.len > 0) progName(argv[0]) else "host";

    const parsed = parseArgs(allocator, argv) catch |e| {
        switch (e) {
            error.ShowHelp => {
                usage(name);
                return;
            },
            else => {
                usage(name);
                return std.process.exit(2);
            },
        }
    };

    const code = runHost(allocator, init.io, parsed) catch |e| {
        err("{s}: {s}\n", .{ name, @errorName(e) });
        return std.process.exit(1);
    };
    std.process.exit(code);
}
