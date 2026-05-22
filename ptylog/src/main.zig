const std = @import("std");
const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const PtyChildHost = @import("host").PtyChildHost;
const getTtySize = @import("ptyio_tty_size").getTtySize;
const log_core = @import("scroll_log_core");

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

const io_chunk_size = 64 * 1024;

var winch_changed = false;

const Config = struct {
    transcript_path: []const u8,
    log_path: []const u8,
    child_argv: []const []const u8,
};

fn usage() void {
    std.debug.print(
        "NAME\n  ptylog - PTY passthrough logger\n\nUSAGE\n  ptylog --transcript <path> --log <path> -- <command> [args...]\n",
        .{},
    );
}

fn handleSigwinch(_: c_int) callconv(.c) void {
    winch_changed = true;
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Config {
    var transcript_path: ?[]const u8 = null;
    var log_path: ?[]const u8 = null;
    var child_start: ?usize = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            child_start = i + 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.ShowHelp;
        if (std.mem.eql(u8, arg, "--transcript")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            transcript_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--log")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            log_path = argv[i];
            continue;
        }
        return error.InvalidArgs;
    }

    const start = child_start orelse return error.InvalidArgs;
    if (start >= argv.len) return error.InvalidArgs;

    return .{
        .transcript_path = transcript_path orelse return error.InvalidArgs,
        .log_path = log_path orelse return error.InvalidArgs,
        .child_argv = try allocator.dupe([]const u8, argv[start..]),
    };
}

fn ensureParent(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn createOutput(path: []const u8) !std.fs.File {
    try ensureParent(path);
    return try std.fs.createFileAbsolute(path, .{ .truncate = true, .read = false });
}

fn currentSize() struct { rows: u16, cols: u16 } {
    const fds = [_]c_int{ std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO };
    for (fds) |fd| {
        const size = getTtySize(fd) catch continue;
        if (size.rows != 0 and size.cols != 0) return .{ .rows = size.rows, .cols = size.cols };
    }
    return .{ .rows = 24, .cols = 80 };
}

fn readIntoQueuePty(allocator: std.mem.Allocator, fd: c_int, queue: *ByteQueue, max_bytes: usize) !fd_stream.ReadStatus {
    if (max_bytes == 0) return .{ .progress = 0 };

    try queue.ensureCapacity(allocator, max_bytes);
    const writable = queue.buf[queue.end .. queue.end + max_bytes];

    while (true) {
        const n = c.read(fd, writable.ptr, writable.len);
        if (n > 0) {
            queue.end += @intCast(n);
            return .{ .progress = @intCast(n) };
        }
        if (n == 0) return .eof;

        const e = std.posix.errno(-1);
        if (e == .INTR) continue;
        if (e == .AGAIN) return .would_block;
        if (e == .IO) return .eof;
        return error.IoError;
    }
}

fn run(allocator: std.mem.Allocator, config: Config) !u8 {
    defer allocator.free(config.child_argv);

    var transcript_file = try createOutput(config.transcript_path);
    defer transcript_file.close();

    var log_file = try createOutput(config.log_path);
    defer log_file.close();
    var log_buf: [4096]u8 = undefined;
    var log_writer = log_file.writer(&log_buf);

    const size = currentSize();
    var child = try PtyChildHost.init(allocator, .{
        .argv = config.child_argv,
        .cols = size.cols,
        .rows = size.rows,
    });
    defer child.deinit();
    try child.start();

    const pty_fd = child.masterFd() orelse return error.InvalidState;
    try fd_stream.setNonBlocking(std.posix.STDIN_FILENO);
    try fd_stream.setNonBlocking(std.posix.STDOUT_FILENO);
    try fd_stream.setNonBlocking(pty_fd);

    var logger = try log_core.StreamLogger.init(allocator, .ansi, size.rows, size.cols);
    defer logger.deinit();

    var stdin_rx = ByteQueue.init();
    defer stdin_rx.deinit(allocator);
    var pty_tx = ByteQueue.init();
    defer pty_tx.deinit(allocator);
    var pty_rx = ByteQueue.init();
    defer pty_rx.deinit(allocator);
    var stdout_tx = ByteQueue.init();
    defer stdout_tx.deinit(allocator);

    var stdin_open = true;
    var pty_open = true;

    while (true) {
        if (winch_changed) {
            winch_changed = false;
            const next_size = currentSize();
            child.applySize(.{ .cols = next_size.cols, .rows = next_size.rows }) catch {};
            try logger.resize(next_size.rows, next_size.cols);
        }

        if (stdin_open) {
            const stdin_status = try fd_stream.readIntoQueue(allocator, std.posix.STDIN_FILENO, &stdin_rx, io_chunk_size);
            switch (stdin_status) {
                .progress => {},
                .would_block => {},
                .eof => stdin_open = false,
            }
            if (!stdin_rx.isEmpty()) {
                try pty_tx.append(allocator, stdin_rx.readableSlice());
                stdin_rx.clear();
            }
        }

        _ = try fd_stream.writeFromQueue(pty_fd, &pty_tx, io_chunk_size);

        if (pty_open) {
            const pty_status = try readIntoQueuePty(allocator, pty_fd, &pty_rx, io_chunk_size);
            switch (pty_status) {
                .progress => {},
                .would_block => {},
                .eof => pty_open = false,
            }
            if (!pty_rx.isEmpty()) {
                const bytes = pty_rx.readableSlice();
                try stdout_tx.append(allocator, bytes);
                try transcript_file.writeAll(bytes);
                try logger.feed(bytes);
                try logger.flushLive(&log_writer.interface);
                try log_writer.interface.flush();
                pty_rx.clear();
            }
        }

        _ = try fd_stream.writeFromQueue(std.posix.STDOUT_FILENO, &stdout_tx, io_chunk_size);
        try child.refresh();

        if (!pty_open and stdout_tx.isEmpty()) break;

        var pfds = [_]c.struct_pollfd{
            .{ .fd = std.posix.STDIN_FILENO, .events = if (stdin_open) c.POLLIN else 0, .revents = 0 },
            .{ .fd = pty_fd, .events = @as(c_short, if (pty_open) c.POLLIN else 0) | (if (!pty_tx.isEmpty()) @as(c_short, c.POLLOUT) else 0), .revents = 0 },
            .{ .fd = std.posix.STDOUT_FILENO, .events = if (!stdout_tx.isEmpty()) c.POLLOUT else 0, .revents = 0 },
        };
        _ = c.poll(&pfds, pfds.len, 25);
    }

    try logger.finish(&log_writer.interface);
    try log_writer.interface.flush();
    const status = try child.wait();
    if (status.code) |code| return @intCast(@max(code, 0));
    return 1;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const old_winch = c.signal(c.SIGWINCH, handleSigwinch);
    defer _ = c.signal(c.SIGWINCH, old_winch);

    const config = parseArgs(allocator, argv) catch |err| switch (err) {
        error.ShowHelp => {
            usage();
            return;
        },
        else => {
            usage();
            std.process.exit(2);
        },
    };

    const code = run(allocator, config) catch |err| {
        std.debug.print("ptylog: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}
