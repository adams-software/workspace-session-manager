const std = @import("std");
const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const PtyChildHost = @import("host").PtyChildHost;
const enterRawMode = @import("ptyio_raw_mode").enterRawMode;
const runtime_lifecycle_mod = @import("ptylog_runtime_lifecycle");
const RuntimeLifecycle = runtime_lifecycle_mod.RuntimeLifecycle;
const log_core = @import("ptylog_log_core");

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("unistd.h");
});

const io_chunk_size = 64 * 1024;
const default_log_segment_bytes: u64 = 1 * 1024 * 1024;
const default_log_segment_count: u64 = 10;
const default_log_budget_bytes: u64 = default_log_segment_bytes * default_log_segment_count;

fn writerFromList(allocator: std.mem.Allocator, list: *std.ArrayList(u8)) std.Io.Writer.Allocating {
    return std.Io.Writer.Allocating.fromArrayList(allocator, list);
}

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
        var next_segment_index = try nextRetainedSegmentIndex(allocator, base_path);
        next_segment_index = try rollExistingBaseLog(io, allocator, base_path, next_segment_index);
        const file = createOutput(io, path) catch |err| {
            std.debug.print("ptylog: logging disabled: {s}\n", .{@errorName(err)});
            return .{
                .allocator = allocator,
                .base_path = base_path,
                .budget_bytes = budget_bytes,
                .segment_bytes = segment_bytes,
                .file = null,
                .logger = null,
                .next_segment_index = next_segment_index,
            };
        };
        var state: LogState = .{
            .allocator = allocator,
            .base_path = base_path,
            .budget_bytes = budget_bytes,
            .segment_bytes = segment_bytes,
            .file = file,
            .logger = try log_core.StreamLogger.init(allocator, .ansi, rows, cols),
            .next_segment_index = next_segment_index,
        };
        state.enforceBudget() catch |err| {
            state.disable(io, err);
        };
        return state;
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
        const total = try totalRetainedBytes(self.base_path);
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

    pub fn resize(self: *LogState, rows: u16, cols: u16) void {
        if (self.logger) |*logger| {
            logger.resize(rows, cols) catch |err| self.disable(std.Io.Threaded.global_single_threaded.io(), err);
        }
    }

    fn appendLoggedBytes(self: *LogState, io: std.Io, bytes: []const u8) void {
        if (bytes.len == 0 or self.file == null) return;

        var remaining = bytes;
        while (remaining.len > 0) {
            if (self.current_bytes >= self.segment_bytes) {
                self.rollSegment(io) catch |err| {
                    self.disable(io, err);
                    return;
                };
                if (self.file == null) return;
            }

            const space_u64 = self.segment_bytes - self.current_bytes;
            const space: usize = @intCast(@min(space_u64, @as(u64, @intCast(remaining.len))));
            if (space == 0) break;

            {
                var file = &self.file.?;
                var writer = file.writerStreaming(io, &self.buf);
                writer.interface.writeAll(remaining[0..space]) catch |err| {
                    self.disable(io, err);
                    return;
                };
                writer.interface.flush() catch |err| {
                    self.disable(io, err);
                    return;
                };
            }
            self.current_bytes += space;
            remaining = remaining[space..];
        }
    }

    fn feed(self: *LogState, io: std.Io, bytes: []const u8) void {
        if (self.logger == null or self.file == null) return;

        var logger = &self.logger.?;
        logger.feed(bytes) catch |err| {
            self.disable(io, err);
            return;
        };

        var flushed: std.ArrayList(u8) = .empty;
        defer flushed.deinit(self.allocator);
        var flushed_writer = writerFromList(self.allocator, &flushed);
        logger.flushLive(&flushed_writer.writer) catch |err| {
            self.disable(io, err);
            return;
        };
        flushed = flushed_writer.toArrayList();
        self.appendLoggedBytes(io, flushed.items);
    }

    fn finish(self: *LogState, io: std.Io) void {
        if (self.logger == null or self.file == null) return;

        var logger = &self.logger.?;
        var flushed: std.ArrayList(u8) = .empty;
        defer flushed.deinit(self.allocator);
        var flushed_writer = writerFromList(self.allocator, &flushed);
        logger.finish(&flushed_writer.writer) catch |err| {
            self.disable(io, err);
            return;
        };
        flushed = flushed_writer.toArrayList();
        self.appendLoggedBytes(io, flushed.items);
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
        "NAME\n  ptylog - PTY passthrough logger\n\nUSAGE\n  ptylog --log <path> [--segment <bytes>] [--keep <count>] -- <command> [args...]\n",
        .{},
    );
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Config {
    var log_path: ?[]const u8 = null;
    var log_segment_bytes = default_log_segment_bytes;
    var log_segment_count = default_log_segment_count;
    var budget_override: ?u64 = null;
    var keep_override = false;
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
        if (std.mem.eql(u8, arg, "--segment")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            log_segment_bytes = try std.fmt.parseUnsigned(u64, argv[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--keep")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            log_segment_count = try std.fmt.parseUnsigned(u64, argv[i], 10);
            keep_override = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--log-budget-bytes")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            budget_override = try std.fmt.parseUnsigned(u64, argv[i], 10);
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

    if (log_segment_bytes == 0) return error.InvalidArgs;
    if (keep_override and budget_override != null) return error.InvalidArgs;

    const log_budget_bytes = if (budget_override) |budget|
        budget
    else
        try std.math.mul(u64, log_segment_bytes, log_segment_count);

    if (log_segment_count == 0 or log_budget_bytes == 0 or log_segment_bytes > log_budget_bytes) return error.InvalidArgs;

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

fn nextRetainedSegmentIndex(allocator: std.mem.Allocator, base_path: []const u8) !u32 {
    const dir_name = std.fs.path.dirname(base_path) orelse ".";
    const file_name = std.fs.path.basename(base_path);
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_name, .{ .iterate = true });
    defer dir.close(io);

    var max_index: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, file_name)) continue;
        if (entry.name.len <= file_name.len + 1) continue;
        if (entry.name[file_name.len] != '.') continue;
        const suffix = entry.name[(file_name.len + 1)..];
        if (!isNumeric(suffix)) continue;
        const index = try std.fmt.parseUnsigned(u32, suffix, 10);
        max_index = @max(max_index, index);
    }
    _ = allocator;
    return max_index + 1;
}

fn rollExistingBaseLog(io: std.Io, allocator: std.mem.Allocator, base_path: []const u8, next_segment_index: u32) !u32 {
    const existing_size = fileSize(base_path) catch |err| switch (err) {
        error.FileNotFound => return next_segment_index,
        else => return err,
    };
    if (existing_size == 0) return next_segment_index;

    const segment_path = try std.fmt.allocPrint(allocator, "{s}.{d:0>6}", .{ base_path, next_segment_index });
    defer allocator.free(segment_path);
    try std.Io.Dir.renameAbsolute(base_path, segment_path, io);
    return next_segment_index + 1;
}

fn totalRetainedBytes(base_path: []const u8) !u64 {
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

fn run(io: std.Io, allocator: std.mem.Allocator, config: Config, lifecycle: *RuntimeLifecycle) !u8 {
    defer allocator.free(config.child_argv);

    const stdin_is_tty = c.isatty(std.posix.STDIN_FILENO) == 1;
    var raw_mode = if (stdin_is_tty) try enterRawMode(std.posix.STDIN_FILENO) else null;
    defer if (raw_mode) |*guard| guard.restore();

    const size = lifecycle.currentSize();
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
    while (true) {
        lifecycle.applyPendingResizeIfNeeded(&child, &log_state);
        lifecycle.issueTerminationIfNeeded(&child);

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
            .{ .fd = lifecycle.readFd(), .events = c.POLLIN, .revents = 0 },
        };
        _ = c.poll(&pfds, pfds.len, 25);
        lifecycle.consumeWakeRevents(pfds[3].revents);
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

    var lifecycle = RuntimeLifecycle{};
    const signal_handlers = try lifecycle.install();
    defer signal_handlers.restore();

    const code = run(init.io, allocator, config, &lifecycle) catch |err| {
        std.debug.print("ptylog: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}
