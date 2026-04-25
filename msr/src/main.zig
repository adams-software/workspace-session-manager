const std = @import("std");
const host = @import("host");
const host_runtime = @import("host_runtime");
const host_repl = @import("host_repl");
const session_server = @import("server");

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
            "  msr <socket-path> [--size <cols>x<rows>] [--] <cmd...>\n\n" ++
            "BEHAVIOR\n" ++
            "  Starts one child process, binds one socket, accepts zero or one active\n" ++
            "  owner at a time, and exits when the child exits. The host cleans up its\n" ++
            "  socket path on exit. New attachers always replace the current owner.\n\n" ++
            "EXAMPLES\n" ++
            "  msr /tmp/dev.sock -- /bin/sh -i\n" ++
            "  msr /tmp/dev.sock --size 120x40 -- nvim\n",
        .{},
    );
}

const Parsed = struct {
    socket_path: []const u8,
    size: ?host.Size,
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

    while (i < argv.len) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
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

fn runHost(allocator: std.mem.Allocator, parsed: Parsed) !u8 {
    var child = try host.PtyChildHost.init(allocator, .{
        .argv = parsed.child_argv,
        .cols = if (parsed.size) |s| s.cols else null,
        .rows = if (parsed.size) |s| s.rows else null,
    });
    defer child.deinit();

    try child.start();

    var server = session_server.SessionServer.init(allocator, &child);
    defer server.deinit();
    try server.listen(parsed.socket_path);
    if (server.runtime) |*runtime| {
        if (parsed.size) |s| try runtime.resize(s.cols, s.rows);
        if (child.pid) |pid| runtime.onChildStarted(pid);
    }

    if (server.runtime) |*runtime| {
        try host_repl.run(allocator, runtime);
    }

    while (true) {
        _ = try server.step();
        try child.refresh();

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

        var pfd = [_]c.struct_pollfd{.{
            .fd = server.listener_fd orelse -1,
            .events = c.POLLIN,
            .revents = 0,
        }};
        _ = c.poll(&pfd, 1, 25);
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
