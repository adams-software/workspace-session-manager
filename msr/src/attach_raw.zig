const std = @import("std");
const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const enterRawMode = @import("ptyio_raw_mode").enterRawMode;

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn usage() void {
    out(
        "NAME\n" ++
            "  msr-attach - raw terminal attacher for msr host\n\n" ++
            "USAGE\n" ++
            "  msr-attach <socket-path>\n",
        .{},
    );
}

fn connectUnix(path: []const u8) !c_int {
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);

    const max_path_len = addr.sun_path.len - 1;
    if (path.len == 0 or path.len > max_path_len) return error.InvalidArgs;

    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.ConnectFailed;

    if (c.connect(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) {
        _ = c.close(fd);
        return error.ConnectFailed;
    }

    return fd;
}

fn runAttach(allocator: std.mem.Allocator, path: []const u8) !u8 {
    const fd = try connectUnix(path);
    defer _ = c.close(fd);

    const stdin_is_tty = c.isatty(c.STDIN_FILENO) == 1;
    if (stdin_is_tty) {
        try fd_stream.setNonBlocking(c.STDIN_FILENO);
    }
    if (c.isatty(c.STDOUT_FILENO) == 1) {
        try fd_stream.setNonBlocking(c.STDOUT_FILENO);
    }
    try fd_stream.setNonBlocking(fd);

    var raw_guard: ?@import("ptyio_raw_mode").RawModeGuard = null;
    defer if (raw_guard) |*g| g.restore();
    if (stdin_is_tty) {
        raw_guard = try enterRawMode(c.STDIN_FILENO);
    }

    var stdin_rx = ByteQueue.init();
    defer stdin_rx.deinit(allocator);

    var sock_tx = ByteQueue.init();
    defer sock_tx.deinit(allocator);

    var sock_rx = ByteQueue.init();
    defer sock_rx.deinit(allocator);

    var stdout_tx = ByteQueue.init();
    defer stdout_tx.deinit(allocator);

    while (true) {
        if (stdin_is_tty) {
            const in_status = try fd_stream.readIntoQueue(allocator, c.STDIN_FILENO, &stdin_rx, 64 * 1024);
            switch (in_status) {
                .progress => {},
                .would_block => {},
                .eof => return 0,
            }

            if (!stdin_rx.isEmpty()) {
                try sock_tx.append(allocator, stdin_rx.readableSlice());
                stdin_rx.clear();
            }
        }

        _ = try fd_stream.writeFromQueue(fd, &sock_tx, 64 * 1024);

        const sock_status = try fd_stream.readIntoQueue(allocator, fd, &sock_rx, 64 * 1024);
        switch (sock_status) {
            .progress => {},
            .would_block => {},
            .eof => return 0,
        }

        if (!sock_rx.isEmpty()) {
            try stdout_tx.append(allocator, sock_rx.readableSlice());
            sock_rx.clear();
        }

        _ = try fd_stream.writeFromQueue(c.STDOUT_FILENO, &stdout_tx, 64 * 1024);

        var pfds = [_]c.struct_pollfd{
            .{ .fd = c.STDIN_FILENO, .events = if (stdin_is_tty) c.POLLIN else 0, .revents = 0 },
            .{ .fd = fd, .events = @as(c_short, c.POLLIN) | (if (!sock_tx.isEmpty()) @as(c_short, c.POLLOUT) else 0), .revents = 0 },
            .{ .fd = c.STDOUT_FILENO, .events = if (!stdout_tx.isEmpty()) c.POLLOUT else 0, .revents = 0 },
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

    if (argv.len != 2 or std.mem.eql(u8, argv[1], "-h") or std.mem.eql(u8, argv[1], "--help")) {
        usage();
        if (argv.len == 2) return;
        return std.process.exit(2);
    }

    const code = runAttach(allocator, argv[1]) catch |e| {
        std.debug.print("msr-attach: {s}\n", .{@errorName(e)});
        return std.process.exit(1);
    };
    std.process.exit(code);
}
