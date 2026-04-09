const std = @import("std");

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

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const SpawnOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
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

pub const PtyChildHost = struct {
    allocator: std.mem.Allocator,
    opts: SpawnOptions,
    state: HostState,
    pid: ?c.pid_t,
    master_fd: ?c_int,
    exit_status: ?ExitStatus,

    pub fn init(allocator: std.mem.Allocator, opts: SpawnOptions) Error!PtyChildHost {
        if (opts.argv.len == 0) return Error.InvalidArgs;
        return .{
            .allocator = allocator,
            .opts = opts,
            .state = .idle,
            .pid = null,
            .master_fd = null,
            .exit_status = null,
        };
    }

    pub fn deinit(self: *PtyChildHost) void {
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

    pub fn start(self: *PtyChildHost) Error!void {
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
    }

    pub fn resize(self: *PtyChildHost, cols: u16, rows: u16) Error!void {
        if (cols == 0 or rows == 0) return Error.InvalidArgs;

        return switch (self.state) {
            .idle, .starting => Error.NotStarted,
            .running => blk: {
                const fd = self.master_fd orelse return Error.InvalidState;
                var ws = c.struct_winsize{ .ws_row = @intCast(rows), .ws_col = @intCast(cols), .ws_xpixel = 0, .ws_ypixel = 0 };
                if (c.ioctl(fd, c.TIOCSWINSZ, &ws) != 0) break :blk Error.InvalidArgs;
                self.opts.rows = rows;
                self.opts.cols = cols;
                break :blk;
            },
            .exited => Error.InvalidState,
            .closed => Error.Closed,
        };
    }

    pub fn applySize(self: *PtyChildHost, size: Size) Error!void {
        try self.resize(size.cols, size.rows);
        try self.signalWinch();
    }

    pub fn signalWinch(self: *PtyChildHost) Error!void {
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

    pub fn terminate(self: *PtyChildHost, signal: ?[]const u8) Error!void {
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

    pub fn writeInput(self: *PtyChildHost, data: []const u8) Error!void {
        return switch (self.state) {
            .idle, .starting => Error.NotStarted,
            .running => writeAll(self.master_fd orelse return Error.InvalidState, data),
            .exited => Error.InvalidState,
            .closed => Error.Closed,
        };
    }

    pub fn readOutput(self: *PtyChildHost, allocator: std.mem.Allocator, max_bytes: usize, timeout_ms: i32) Error![]u8 {
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

    pub fn refresh(self: *PtyChildHost) Error!void {
        switch (self.state) {
            .idle, .starting, .exited, .closed => return,
            .running => {
                const pid = self.pid orelse return Error.InvalidState;
                var wait_status: c_int = 0;
                const got = c.waitpid(pid, &wait_status, c.WNOHANG);
                if (got < 0) return Error.IoError;
                if (got == 0) return;

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

    pub fn wait(self: *PtyChildHost) Error!ExitStatus {
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

    pub fn close(self: *PtyChildHost) Error!void {
        switch (self.state) {
            .closed => return,
            .idle, .starting => return Error.InvalidState,
            .running, .exited => {
                if (self.master_fd) |fd| {
                    _ = c.close(fd);
                    self.master_fd = null;
                }
                self.state = .closed;
            },
        }
    }

    pub fn hostState(self: *const PtyChildHost) HostState {
        return self.state;
    }

    pub fn exitStatus(self: *const PtyChildHost) ?ExitStatus {
        return self.exit_status;
    }

    pub fn ptyFd(self: *const PtyChildHost) ?c_int {
        return self.master_fd;
    }
};

