const std = @import("std");
const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const PtyChildHost = @import("host").PtyChildHost;
const getTtySize = @import("ptyio_tty_size").getTtySize;
const enterRawMode = @import("ptyio_raw_mode").enterRawMode;
const log_core = @import("scroll_log_core");

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

const io_chunk_size = 64 * 1024;
const default_log_budget_bytes: u64 = 1 * 1024 * 1024;
const default_log_segment_bytes: u64 = 512 * 1024;

var winch_changed = false;
var terminate_signal: c.sig_atomic_t = 0;

const LogState = struct {
    allocator: std.mem.Allocator,
    base_path: []u8,
    budget_bytes: u64,
    segment_bytes: u64,
    file: ?std.Io.File,
    logger: ?log_core.StreamLogger,
    buf: [4096]u8 = undefined,
    warned: bool = false,
    next_segment_index: u32 = 1,
    current_bytes: u64 = 0,

    fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        rows: u16,
        cols: u16,
        budget_bytes: u64,
        segment_bytes: u64,
    ) !LogState {
        const base_path = try allocator.dupe(u8, path);
        errdefer allocator.free(base_path);
        try cleanupOldSegments(base_path);
        const file = createOutput(io, path) catch |err| {
            std.debug.print("ptylog: logging disabled: {s}\n", .{@errorName(err)});
            return .{
                .allocator = allocator,
                .base_path = base_path,
                .budget_bytes = budget_bytes,
                .segment_bytes = segment_bytes,
                .file = null,
                .logger = null,
            };
        };
        return .{
            .allocator = allocator,
            .base_path = base_path,
            .budget_bytes = budget_bytes,
            .segment_bytes = segment_bytes,
            .file = file,
            .logger = try log_core.StreamLogger.init(allocator, .ansi, rows, cols),
        };
    }

    fn deinit(self: *LogState, io: std.Io) void {
        if (self.logger) |*logger| logger.deinit();
        if (self.file) |*file| file.close(io);
        self.allocator.free(self.base_path);
    }

    fn disable(self: *LogState, io: std.Io, err: anyerror) void {
        if (!self.warned) {
            self.warned = true;
            std.debug.print("ptylog: logging disabled after error: {s}\n", .{@errorName(err)});
        }
        if (self.logger) |*logger| {
            logger.deinit();
            self.logger = null;
        }
        if (self.file) |*file| {
            file.close(io);
            self.file = null;
        }
    }

    fn postWrite(self: *LogState, io: std.Io) void {
        if (self.file == null) return;
        self.current_bytes = fileSize(self.base_path) catch |err| {
            self.disable(io, err);
            return;
        };
        if (self.current_bytes < self.segment_bytes) return;
        self.rollSegment(io) catch |err| {
            self.disable(io, err);
        };
    }

    fn rollSegment(self: *LogState, io: std.Io) !void {
        if (self.file) |*file| {
            file.close(io);
            self.file = null;
        }
        const segment_path = try self.segmentPath(self.next_segment_index);
        defer self.allocator.free(segment_path);
        try std.Io.Dir.renameAbsolute(self.base_path, segment_path, io);
        self.next_segment_index += 1;
        try self.enforceBudget();
        self.file = try createOutput(io, self.base_path);
        self.current_bytes = 0;
    }

    fn segmentPath(self: *const LogState, index: u32) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}.{d:0>6}", .{ self.base_path, index });
    }

    fn enforceBudget(self: *LogState) !void {
        if (self.budget_bytes == 0) return;
        const total = try totalRetainedBytes(self.allocator, self.base_path);
        if (total <= self.budget_bytes) return;

        var retained = total;
        var oldest: u32 = 1;
        while (retained > self.budget_bytes and oldest < self.next_segment_index) : (oldest += 1) {
            const segment_path = try self.segmentPath(oldest);
            defer self.allocator.free(segment_path);
            const size = fileSize(segment_path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            try std.Io.Dir.deleteFileAbsolute(std.Io.Threaded.global_single_threaded.io(), segment_path);
            retained -|= size;
        }
    }

    fn resize(self: *LogState, rows: u16, cols: u16) void {
        if (self.logger) |*logger| {
            logger.resize(rows, cols) catch |err| self.disable(std.Io.Threaded.global_single_threaded.io(), err);
        }
    }

    fn feed(self: *LogState, io: std.Io, bytes: []const u8) void {
        if (self.logger == null or self.file == null) return;

        var logger = &self.logger.?;
        logger.feed(bytes) catch |err| {
            self.disable(io, err);
            return;
        };

        {
            var file = &self.file.?;
            var writer = file.writer(io, &self.buf);
            logger.flushLive(&writer.interface) catch |err| {
                self.disable(io, err);
                return;
            };
            writer.interface.flush() catch |err| {
                self.disable(io, err);
                return;
            };
        }
        self.postWrite(io);
    }

    fn finish(self: *LogState, io: std.Io) void {
        if (self.logger == null or self.file == null) return;

        {
            var logger = &self.logger.?;
            var file = &self.file.?;
            var writer = file.writer(io, &self.buf);
            logger.finish(&writer.interface) catch |err| {
                self.disable(io, err);
                return;
            };
            writer.interface.flush() catch |err| {
                self.disable(io, err);
                return;
            };
        }
        self.postWrite(io);
    }
};

const Config = struct {
    log_path: []const u8,
    log_budget_bytes: u64 = default_log_budget_bytes,
    log_segment_bytes: u64 = default_log_segment_bytes,
    child_argv: []const []const u8,
};

fn usage() void {
    std.debug.print(
        "NAME\n  ptylog - PTY passthrough logger\n\nUSAGE\n  ptylog --log <path> [--log-budget-bytes <n>] [--log-segment-bytes <n>] -- <command> [args...]\n",
        .{},
    );
}

fn handleSigwinch(_: c_int) callconv(.c) void {
    winch_changed = true;
}

fn handleTerminate(sig: c_int) callconv(.c) void {
    terminate_signal = sig;
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Config {
    var log_path: ?[]const u8 = null;
    var log_budget_bytes = default_log_budget_bytes;
    var log_segment_bytes = default_log_segment_bytes;
    var child_start: ?usize = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            child_start = i + 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.ShowHelp;
        if (std.mem.eql(u8, arg, "--log")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            log_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--log-budget-bytes")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            log_budget_bytes = try std.fmt.parseUnsigned(u64, argv[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--log-segment-bytes")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            log_segment_bytes = try std.fmt.parseUnsigned(u64, argv[i], 10);
            continue;
        }
        return error.InvalidArgs;
    }

    if (log_segment_bytes == 0 or log_budget_bytes == 0 or log_segment_bytes > log_budget_bytes) return error.InvalidArgs;

    const start = child_start orelse return error.InvalidArgs;
    if (start >= argv.len) return error.InvalidArgs;

    return .{
        .log_path = log_path orelse return error.InvalidArgs,
        .log_budget_bytes = log_budget_bytes,
        .log_segment_bytes = log_segment_bytes,
        .child_argv = try allocator.dupe([]const u8, argv[start..]),
    };
}

fn ensureParent(io: std.Io, path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.createDirPath(.cwd(), io, dir);
}

fn createOutput(io: std.Io, path: []const u8) !std.Io.File {
    try ensureParent(io, path);
    return try std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true, .read = false });
}

fn cleanupOldSegments(base_path: []const u8) !void {
    const dir_name = std.fs.path.dirname(base_path) orelse ".";
    const file_name = std.fs.path.basename(base_path);
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_name, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, file_name)) continue;
        if (entry.name.len <= file_name.len + 1) continue;
        if (entry.name[file_name.len] != '.') continue;
        if (!isNumeric(entry.name[(file_name.len + 1)..])) continue;
        try dir.deleteFile(io, entry.name);
    }
}

fn totalRetainedBytes(allocator: std.mem.Allocator, base_path: []const u8) !u64 {
    const dir_name = std.fs.path.dirname(base_path) orelse ".";
    const file_name = std.fs.path.basename(base_path);
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_name, .{ .iterate = true });
    defer dir.close(io);

    var total: u64 = 0;
    if (dir.statFile(io, file_name, .{})) |stat| {
        total += stat.size;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, file_name)) continue;
        if (entry.name.len <= file_name.len + 1) continue;
        if (entry.name[file_name.len] != '.') continue;
        if (!isNumeric(entry.name[(file_name.len + 1)..])) continue;
        const stat = try dir.statFile(io, entry.name, .{});
        total += stat.size;
    }
    _ = allocator;
    return total;
}

fn fileSize(path: []const u8) !u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir_name = std.fs.path.dirname(path) orelse ".";
    const file_name = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_name, .{});
    defer dir.close(io);
    const stat = try dir.statFile(io, file_name, .{});
    return stat.size;
}

fn isNumeric(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
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

fn run(io: std.Io, allocator: std.mem.Allocator, config: Config) !u8 {
    defer allocator.free(config.child_argv);

    const stdin_is_tty = c.isatty(std.posix.STDIN_FILENO) == 1;
    var raw_mode = if (stdin_is_tty) try enterRawMode(std.posix.STDIN_FILENO) else null;
    defer if (raw_mode) |*guard| guard.restore();

    const size = currentSize();
    var log_state = try LogState.init(
        io,
        allocator,
        config.log_path,
        size.rows,
        size.cols,
        config.log_budget_bytes,
        config.log_segment_bytes,
    );
    defer log_state.deinit(io);

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
    var forwarded_terminate = false;

    while (true) {
        if (winch_changed) {
            winch_changed = false;
            const next_size = currentSize();
            child.applySize(.{ .cols = next_size.cols, .rows = next_size.rows }) catch {};
            log_state.resize(next_size.rows, next_size.cols);
        }

        const requested_terminate: c_int = @intCast(terminate_signal);
        if (requested_terminate != 0 and !forwarded_terminate) {
            child.sendSignal(requested_terminate) catch {};
            forwarded_terminate = true;
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
                log_state.feed(io, bytes);
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

    log_state.finish(io);
    const status = try child.wait();
    if (status.code) |code| return @intCast(@max(code, 0));
    return 1;
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

    const old_winch = c.signal(c.SIGWINCH, handleSigwinch);
    defer _ = c.signal(c.SIGWINCH, old_winch);
    const old_term = c.signal(c.SIGTERM, handleTerminate);
    defer _ = c.signal(c.SIGTERM, old_term);
    const old_int = c.signal(c.SIGINT, handleTerminate);
    defer _ = c.signal(c.SIGINT, old_int);

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

    const code = run(init.io, allocator, config) catch |err| {
        std.debug.print("ptylog: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}
