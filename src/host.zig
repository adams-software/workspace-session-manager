const std = @import("std");
const terminal_state_vterm = @import("terminal_state_vterm.zig");
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("stdlib.h");
});

pub const ExitStatus = struct {
    code: ?i32 = null,
    signal: ?[]const u8 = null,
};

pub const HostState = enum {
    idle,
    starting,
    running,
    exited,
    closed,
};

pub const SpawnOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    enable_terminal_state: bool = false,
    replay_capacity: usize = 64,
};

pub const Error = error{
    InvalidArgs,
    InvalidState,
    NotStarted,
    AlreadyStarted,
    Closed,
    SpawnFailed,
    PtyFailed,
    PermissionDenied,
    OutOfMemory,
    Unsupported,
    IoError,
};

pub const PtyStream = struct {
    host: *SessionHost,

    pub fn write(self: PtyStream, data: []const u8) Error!void {
        return self.host.writePty(data);
    }

    pub fn read(self: PtyStream, allocator: std.mem.Allocator, max_bytes: usize, timeout_ms: i32) Error![]u8 {
        return self.host.readPty(allocator, max_bytes, timeout_ms);
    }
};

pub const ReplayChunk = struct {
    seq: u64,
    bytes: []u8,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const HostScreenCell = struct {
    text: []const u8,
};

pub const HostScreenSnapshot = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    alt_screen: bool,
    title: ?[]const u8 = null,
    seq: u64,
    cells: [][]HostScreenCell,
};


pub fn freeScreenSnapshot(allocator: std.mem.Allocator, snapshot: *HostScreenSnapshot) void {
    for (snapshot.cells) |row| {
        for (row) |cell| allocator.free(cell.text);
        allocator.free(row);
    }
    allocator.free(snapshot.cells);
    if (snapshot.title) |title| allocator.free(title);
}

pub const SessionHost = struct {
    allocator: std.mem.Allocator,
    opts: SpawnOptions,
    state: HostState,
    pid: ?c.pid_t,
    master_fd: ?c_int,
    exit_status: ?ExitStatus,
    pty: PtyStream,
    terminal_state_enabled: bool,
    screen_seq: u64,
    replay_chunks: std.ArrayList(ReplayChunk),
    terminal_state: ?terminal_state_vterm.VTermAdapter,

    pub fn init(allocator: std.mem.Allocator, opts: SpawnOptions) Error!SessionHost {
        if (opts.argv.len == 0) return Error.InvalidArgs;
        var self = SessionHost{
            .allocator = allocator,
            .opts = opts,
            .state = .idle,
            .pid = null,
            .master_fd = null,
            .exit_status = null,
            .pty = undefined,
            .terminal_state_enabled = opts.enable_terminal_state,
            .screen_seq = 0,
            .replay_chunks = .{},
            .terminal_state = if (opts.enable_terminal_state) try terminal_state_vterm.VTermAdapter.init(allocator, opts.rows orelse 24, opts.cols orelse 80) else null,
        };
        self.pty = .{ .host = &self };
        return self;
    }

    pub fn deinit(self: *SessionHost) void {
        if (self.terminal_state) |*ts| ts.deinit();
        for (self.replay_chunks.items) |chunk| self.allocator.free(chunk.bytes);
        self.replay_chunks.deinit(self.allocator);
        if (self.master_fd) |fd| {
            _ = c.close(fd);
            self.master_fd = null;
        }
    }

    fn withCPath(path: []const u8, comptime F: anytype, args: anytype) void {
        var buf: [std.fs.max_path_bytes:0]u8 = [_:0]u8{0} ** std.fs.max_path_bytes;
        if (path.len >= std.fs.max_path_bytes) return;
        std.mem.copyForwards(u8, buf[0..path.len], path);
        @call(.auto, F, .{buf[0..path.len :0]} ++ args);
    }

    fn spawnChild(opts: SpawnOptions) Error!struct { pid: c.pid_t, master_fd: c_int } {
        var master: c_int = -1;
        var ws: c.struct_winsize = .{ .ws_row = 0, .ws_col = 0, .ws_xpixel = 0, .ws_ypixel = 0 };
        const win_ptr = blk: {
            if (opts.rows != null or opts.cols != null) {
                ws.ws_row = @intCast(opts.rows orelse 24);
                ws.ws_col = @intCast(opts.cols orelse 80);
                break :blk &ws;
            }
            break :blk null;
        };

        const pid = c.forkpty(&master, null, null, win_ptr);
        if (pid < 0) return Error.PtyFailed;

        if (pid == 0) {
            if (opts.cwd) |cwd| {
                withCPath(cwd, struct {
                    fn call(p: [:0]const u8) void {
                        if (c.chdir(p.ptr) != 0) c._exit(126);
                    }
                }.call, .{});
            }

            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const argv_c = a.alloc(?[*:0]u8, opts.argv.len + 1) catch c._exit(127);
            for (opts.argv, 0..) |arg, i| {
                const z = a.dupeZ(u8, arg) catch c._exit(127);
                argv_c[i] = z.ptr;
            }
            argv_c[opts.argv.len] = null;

            if (opts.env) |env| {
                for (env) |entry| {
                    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse c._exit(127);
                    const key = a.dupeZ(u8, entry[0..eq]) catch c._exit(127);
                    const value = a.dupeZ(u8, entry[(eq + 1)..]) catch c._exit(127);
                    if (c.setenv(key.ptr, value.ptr, 1) != 0) c._exit(127);
                }
            }

            _ = c.execvp(argv_c[0].?, @ptrCast(argv_c.ptr));
            c._exit(127);
        }

        return .{ .pid = pid, .master_fd = master };
    }

    fn signalFromName(name: ?[]const u8) c_int {
        if (name == null) return c.SIGTERM;
        if (std.mem.eql(u8, name.?, "TERM")) return c.SIGTERM;
        if (std.mem.eql(u8, name.?, "KILL")) return c.SIGKILL;
        if (std.mem.eql(u8, name.?, "INT")) return c.SIGINT;
        return c.SIGTERM;
    }

    fn writeAll(fd: c_int, bytes: []const u8) Error!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(fd, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                const e = std.c.errno(-1);
                if (e == .INTR or e == .AGAIN) continue;
                return Error.IoError;
            }
            if (n == 0) return Error.IoError;
            off += @intCast(n);
        }
    }

    pub fn start(self: *SessionHost) Error!void {
        if (self.state == .closed) return Error.Closed;
        if (self.state != .idle) return Error.AlreadyStarted;
        self.state = .starting;
        const child = spawnChild(self.opts) catch |err| {
            self.state = .idle;
            return err;
        };
        self.pid = child.pid;
        self.master_fd = child.master_fd;
        self.state = .running;
        self.pty.host = self;
    }

    pub fn resize(self: *SessionHost, cols: u16, rows: u16) Error!void {
        if (cols == 0 or rows == 0) return Error.InvalidArgs;
        return switch (self.state) {
            .idle, .starting => Error.NotStarted,
            .running => blk: {
                const fd = self.master_fd orelse return Error.InvalidState;
                var ws = c.struct_winsize{
                    .ws_row = @intCast(rows),
                    .ws_col = @intCast(cols),
                    .ws_xpixel = 0,
                    .ws_ypixel = 0,
                };
                if (c.ioctl(fd, c.TIOCSWINSZ, &ws) != 0) break :blk Error.InvalidArgs;
                self.opts.rows = rows;
                self.opts.cols = cols;
                break :blk;
            },
            .exited => Error.InvalidState,
            .closed => Error.Closed,
        };
    }

    pub fn applySessionSize(self: *SessionHost, size: Size) Error!void {
        try self.resize(size.cols, size.rows);
        try self.signalWinch();
    }

    pub fn signalWinch(self: *SessionHost) Error!void {
        return switch (self.state) {
            .idle, .starting => Error.NotStarted,
            .running => blk: {
                const pid = self.pid orelse return Error.InvalidState;
                if (c.kill(pid, c.SIGWINCH) != 0) break :blk Error.InvalidArgs;
                break :blk;
            },
            .exited => Error.InvalidState,
            .closed => Error.Closed,
        };
    }

    pub fn terminate(self: *SessionHost, signal: ?[]const u8) Error!void {
        return switch (self.state) {
            .idle, .starting => Error.NotStarted,
            .running => blk: {
                const pid = self.pid orelse return Error.InvalidState;
                if (c.kill(pid, signalFromName(signal)) != 0) break :blk Error.InvalidArgs;
                break :blk;
            },
            .exited => {},
            .closed => Error.Closed,
        };
    }

    pub fn writePty(self: *SessionHost, data: []const u8) Error!void {
        return switch (self.state) {
            .idle, .starting => Error.NotStarted,
            .running => writeAll(self.master_fd orelse return Error.InvalidState, data),
            .exited => Error.InvalidState,
            .closed => Error.Closed,
        };
    }

    pub fn readPty(self: *SessionHost, allocator: std.mem.Allocator, max_bytes: usize, timeout_ms: i32) Error![]u8 {
        return switch (self.state) {
            .idle, .starting => Error.NotStarted,
            .running => blk: {
                const fd = self.master_fd orelse return Error.InvalidState;
                var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
                const pr = c.poll(&pfd, 1, timeout_ms);
                if (pr < 0) return Error.IoError;
                if (pr == 0) return allocator.alloc(u8, 0) catch Error.OutOfMemory;
                if ((pfd.revents & c.POLLIN) == 0) return allocator.alloc(u8, 0) catch Error.OutOfMemory;

                const buf = allocator.alloc(u8, max_bytes) catch return Error.OutOfMemory;
                const n = c.read(fd, buf.ptr, max_bytes);
                if (n < 0) {
                    allocator.free(buf);
                    return Error.IoError;
                }
                if (n == 0) {
                    allocator.free(buf);
                    return allocator.alloc(u8, 0) catch Error.OutOfMemory;
                }
                break :blk allocator.realloc(buf, @intCast(n)) catch buf[0..@intCast(n)];
            },
            .exited => allocator.alloc(u8, 0) catch Error.OutOfMemory,
            .closed => Error.Closed,
        };
    }

    pub fn wait(self: *SessionHost) Error!ExitStatus {
        return switch (self.state) {
            .idle, .starting => Error.NotStarted,
            .running => blk: {
                const pid = self.pid orelse return Error.InvalidState;
                var wait_status: c_int = 0;
                while (true) {
                    const got = c.waitpid(pid, &wait_status, 0);
                    if (got >= 0) break;
                    const e = std.c.errno(-1);
                    if (e == .INTR) continue;
                    break :blk Error.InvalidArgs;
                }

                var out = ExitStatus{};
                if (c.WIFEXITED(wait_status)) {
                    out.code = @intCast(c.WEXITSTATUS(wait_status));
                } else if (c.WIFSIGNALED(wait_status)) {
                    out.signal = "SIGNALED";
                }
                self.exit_status = out;
                self.state = .exited;
                break :blk out;
            },
            .exited => self.exit_status orelse ExitStatus{},
            .closed => self.exit_status orelse ExitStatus{},
        };
    }


    pub fn observePtyOutput(self: *SessionHost, bytes: []const u8) Error!void {
        return self.recordPtyOutput(bytes);
    }

    pub fn drainObservedPtyOutput(self: *SessionHost) Error![][]u8 {
        const fd = self.master_fd orelse return Error.InvalidState;
        var out = std.ArrayList([]u8){};
        errdefer {
            for (out.items) |chunk| self.allocator.free(chunk);
            out.deinit(self.allocator);
        }

        while (true) {
            var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
            const pr = c.poll(&pfd, 1, 0);
            if (pr < 0) return Error.IoError;
            if (pr == 0 or (pfd.revents & c.POLLIN) == 0) break;

            var buf: [4096]u8 = undefined;
            const n = c.read(fd, &buf, buf.len);
            if (n < 0) {
                const e = std.c.errno(-1);
                if (e == .INTR) continue;
                if (e == .IO) break;
                return Error.IoError;
            }
            if (n == 0) break;

            // The PTY master must have exactly one reader. This API is that
            // explicit drain point: read once, record into replay/terminal-state,
            // then return the same bytes to the caller for optional forwarding.
            const chunk = try self.allocator.dupe(u8, buf[0..@intCast(n)]);
            try self.recordPtyOutput(chunk);
            try out.append(self.allocator, chunk);
        }

        return out.toOwnedSlice(self.allocator);
    }

    fn recordPtyOutput(self: *SessionHost, bytes: []const u8) Error!void {
        if (!self.terminal_state_enabled) return;
        if (self.terminal_state) |*ts| ts.feed(bytes);
        self.screen_seq += 1;
        try self.replay_chunks.append(self.allocator, .{
            .seq = self.screen_seq,
            .bytes = try self.allocator.dupe(u8, bytes),
        });
        while (self.replay_chunks.items.len > self.opts.replay_capacity) {
            const victim = self.replay_chunks.orderedRemove(0);
            self.allocator.free(victim.bytes);
        }
    }

    pub fn refresh(self: *SessionHost) Error!void {
        switch (self.state) {
            .idle, .starting, .exited, .closed => return,
            .running => {
                const pid = self.pid orelse return Error.InvalidState;
                var wait_status: c_int = 0;
                const got = c.waitpid(pid, &wait_status, c.WNOHANG);
                if (got == 0) return;
                if (got < 0) {
                    const e = std.c.errno(-1);
                    if (e == .INTR) return;
                    return Error.InvalidArgs;
                }

                var out = ExitStatus{};
                if (c.WIFEXITED(wait_status)) {
                    out.code = @intCast(c.WEXITSTATUS(wait_status));
                } else if (c.WIFSIGNALED(wait_status)) {
                    out.signal = "SIGNALED";
                }
                self.exit_status = out;
                self.state = .exited;
            },
        }
    }

    pub fn close(self: *SessionHost) Error!void {
        return switch (self.state) {
            .idle, .starting, .running => Error.InvalidState,
            .exited => {
                if (self.master_fd) |fd| {
                    _ = c.close(fd);
                    self.master_fd = null;
                }
                self.state = .closed;
            },
            .closed => {},
        };
    }

    pub fn getScreenSeq(self: *const SessionHost) Error!u64 {
        if (!self.terminal_state_enabled) return Error.Unsupported;
        return self.screen_seq;
    }

    pub fn getScreenSnapshot(self: *const SessionHost, allocator: std.mem.Allocator) Error!HostScreenSnapshot {
        if (!self.terminal_state_enabled) return Error.Unsupported;
        if (self.terminal_state) |*ts| {
            var snap = try ts.snapshot(allocator);
            snap.seq = self.screen_seq;
            return snap;
        }
        return Error.Unsupported;
    }

    pub fn replayAfterSeq(self: *const SessionHost, allocator: std.mem.Allocator, after_seq: u64) Error![]ReplayChunk {
        if (!self.terminal_state_enabled) return Error.Unsupported;
        var first_idx: ?usize = null;
        for (self.replay_chunks.items, 0..) |chunk, i| {
            if (chunk.seq > after_seq) {
                first_idx = i;
                break;
            }
        }
        if (after_seq != 0 and self.screen_seq > after_seq and first_idx == null) return Error.InvalidArgs;
        if (first_idx == null) return try allocator.alloc(ReplayChunk, 0);
        const start_idx = first_idx.?;
        var out = try allocator.alloc(ReplayChunk, self.replay_chunks.items.len - start_idx);
        for (self.replay_chunks.items[start_idx..], 0..) |chunk, i| {
            out[i] = .{ .seq = chunk.seq, .bytes = try allocator.dupe(u8, chunk.bytes) };
        }
        return out;
    }

    pub fn getState(self: *const SessionHost) HostState {
        return self.state;
    }

    pub fn getExitStatus(self: *const SessionHost) ?ExitStatus {
        return self.exit_status;
    }

    pub fn getMasterFd(self: *const SessionHost) ?c_int {
        return self.master_fd;
    }
};

fn readUntilContains(host: *SessionHost, allocator: std.mem.Allocator, needle: []const u8, timeout_ms: i32) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    const deadline_ms = timeout_ms;
    var elapsed: i32 = 0;
    while (elapsed < deadline_ms) : (elapsed += 50) {
        const chunk = try host.pty.read(allocator, 4096, 50);
        defer allocator.free(chunk);
        try out.appendSlice(allocator, chunk);
        if (std.mem.indexOf(u8, out.items, needle) != null) {
            return out.toOwnedSlice(allocator);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "host init requires argv" {
    try std.testing.expectError(Error.InvalidArgs, SessionHost.init(std.testing.allocator, .{ .argv = &.{} }));
}

test "host starts idle" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer host.deinit();
    try std.testing.expectEqual(HostState.idle, host.getState());
}

test "host start launches child and enters running" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer host.deinit();
    try host.start();
    try std.testing.expectEqual(HostState.running, host.getState());
    try host.terminate("KILL");
    _ = try host.wait();
    try host.close();
}

test "host wait returns child exit code" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "exit 7" } });
    defer host.deinit();
    try host.start();
    const st = try host.wait();
    try std.testing.expectEqual(@as(?i32, 7), st.code);
    try std.testing.expectEqual(HostState.exited, host.getState());
}

test "host pty write/read supports simple echo flow" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "read line; printf 'got:%s\\n' \"$line\"" } });
    defer host.deinit();
    try host.start();
    try host.pty.write("hello from test\n");
    const out = try readUntilContains(&host, std.testing.allocator, "got:hello from test", 1000);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "got:hello from test") != null);
    _ = try host.wait();
    try host.close();
}

test "host pty read before start is not allowed" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer host.deinit();
    try std.testing.expectError(Error.NotStarted, host.pty.read(std.testing.allocator, 32, 10));
}

test "host wait after exit reuses cached status" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "exit 3" } });
    defer host.deinit();
    try host.start();
    const st1 = try host.wait();
    const st2 = try host.wait();
    try std.testing.expectEqual(@as(?i32, 3), st1.code);
    try std.testing.expectEqual(@as(?i32, 3), st2.code);
    try std.testing.expectEqual(@as(?i32, 3), host.getExitStatus().?.code);
}

test "host resize before start is not allowed" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer host.deinit();
    try std.testing.expectError(Error.NotStarted, host.resize(80, 24));
}

test "host terminate before start is not allowed" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer host.deinit();
    try std.testing.expectError(Error.NotStarted, host.terminate(null));
}

test "host double start fails" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer host.deinit();
    try host.start();
    try std.testing.expectError(Error.AlreadyStarted, host.start());
    try host.terminate("KILL");
    _ = try host.wait();
    try host.close();
}

test "host close before exit is invalid" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer host.deinit();
    try std.testing.expectError(Error.InvalidState, host.close());
}

test "host close after exit transitions to closed" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "exit 0" } });
    defer host.deinit();
    try host.start();
    _ = try host.wait();
    try host.close();
    try std.testing.expectEqual(HostState.closed, host.getState());
}

test "host close is idempotent after closed" {
    var host = try SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "exit 0" } });
    defer host.deinit();
    try host.start();
    _ = try host.wait();
    try host.close();
    try host.close();
    try std.testing.expectEqual(HostState.closed, host.getState());
}


test "host replayAfterSeq returns only tail after snapshot boundary" {
    var h = try SessionHost.init(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-i" },
        .enable_terminal_state = true,
        .rows = 24,
        .cols = 80,
        .replay_capacity = 64,
    });
    defer h.deinit();
    try h.start();

    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        const drained = try h.drainObservedPtyOutput();
        defer {
            for (drained) |chunk| std.testing.allocator.free(chunk);
            std.testing.allocator.free(drained);
        }
        _ = try h.refresh();
        _ = c.usleep(10_000);
    }

    try h.writePty("printf pre\n");
    tries = 0;
    while (tries < 200 and h.screen_seq == 0) : (tries += 1) {
        const drained = try h.drainObservedPtyOutput();
        defer {
            for (drained) |chunk| std.testing.allocator.free(chunk);
            std.testing.allocator.free(drained);
        }
        _ = try h.refresh();
        _ = c.usleep(10_000);
    }
    try std.testing.expect(h.screen_seq > 0);

    var snap = try h.getScreenSnapshot(std.testing.allocator);
    defer freeScreenSnapshot(std.testing.allocator, &snap);
    const seq = snap.seq;

    try h.writePty("printf post\n");
    tries = 0;
    while (tries < 200 and h.screen_seq <= seq) : (tries += 1) {
        const drained = try h.drainObservedPtyOutput();
        defer {
            for (drained) |chunk| std.testing.allocator.free(chunk);
            std.testing.allocator.free(drained);
        }
        _ = try h.refresh();
        _ = c.usleep(10_000);
    }
    try std.testing.expect(h.screen_seq > seq);

    const replays = try h.replayAfterSeq(std.testing.allocator, seq);
    defer {
        for (replays) |chunk| std.testing.allocator.free(chunk.bytes);
        std.testing.allocator.free(replays);
    }

    var saw_post = false;
    for (replays) |chunk| {
        if (std.mem.indexOf(u8, chunk.bytes, "post") != null) saw_post = true;
    }
    try std.testing.expect(saw_post);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}
