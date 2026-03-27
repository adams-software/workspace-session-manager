const std = @import("std");
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
});

pub const ExitStatus = struct {
    code: ?i32 = null,
    signal: ?[]const u8 = null,
};

pub const SpawnOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
};

pub const AttachMode = enum {
    exclusive,
    takeover,
};

pub const CloseReasonTag = enum {
    detached,
    peer_closed,
    session_ended,
    runtime_closed,
    @"error",
};

pub const CloseReason = union(CloseReasonTag) {
    detached: void,
    peer_closed: void,
    session_ended: ExitStatus,
    runtime_closed: void,
    @"error": []const u8,
};

pub const RuntimeError = error{
    InvalidArgs,
    SessionNotFound,
    SessionAlreadyRunning,
    SessionRunning,
    AttachRecursion,
    PermissionDenied,
    PathTooLong,
    OutOfMemory,
    Unsupported,
};

const Session = struct {
    listener_fd: c_int,
    master_fd: c_int,
    pid: c.pid_t,
};

/// MSR v0 runtime surface (single-session primitive).
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(Session),

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(Session).init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            // Best effort cleanup for tests/dev lifecycle.
            _ = c.kill(entry.value_ptr.pid, c.SIGKILL);
            _ = c.close(entry.value_ptr.listener_fd);
            _ = c.close(entry.value_ptr.master_fd);
            unlinkBestEffort(entry.key_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit();
    }

    fn validateSocketPath(path: []const u8) RuntimeError!void {
        if (path.len == 0) return RuntimeError.InvalidArgs;
        // Common Unix sun_path limit is 108 including NUL.
        if (path.len >= 108) return RuntimeError.PathTooLong;
    }

    fn withCPath(path: []const u8, comptime F: anytype, args: anytype) void {
        var buf: [108:0]u8 = [_:0]u8{0} ** 108;
        if (path.len >= 108) return;
        std.mem.copyForwards(u8, buf[0..path.len], path);
        @call(.auto, F, .{buf[0..path.len :0]} ++ args);
    }

    fn unlinkBestEffort(path: []const u8) void {
        withCPath(path, struct {
            fn call(p: [:0]const u8) void {
                _ = c.unlink(p.ptr);
            }
        }.call, .{});
    }

    fn createListener(path: []const u8) RuntimeError!c_int {
        var addr: c.struct_sockaddr_un = undefined;
        @memset(std.mem.asBytes(&addr), 0);
        addr.sun_family = c.AF_UNIX;
        std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
        addr.sun_path[path.len] = 0;

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return RuntimeError.InvalidArgs;

        unlinkBestEffort(path);

        if (c.bind(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) {
            _ = c.close(fd);
            return RuntimeError.InvalidArgs;
        }

        if (c.listen(fd, 16) != 0) {
            _ = c.close(fd);
            unlinkBestEffort(path);
            return RuntimeError.InvalidArgs;
        }

        return fd;
    }

    fn spawnChild(opts: SpawnOptions) RuntimeError!struct { pid: c.pid_t, master_fd: c_int } {
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
        if (pid < 0) return RuntimeError.InvalidArgs;

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

            _ = c.execvp(argv_c[0].?, @ptrCast(argv_c.ptr));
            c._exit(127);
        }

        return .{ .pid = pid, .master_fd = master };
    }

    fn cleanupSession(self: *Runtime, path: []const u8) void {
        if (self.sessions.fetchRemove(path)) |entry| {
            _ = c.close(entry.value.listener_fd);
            _ = c.close(entry.value.master_fd);
            unlinkBestEffort(path);
            self.allocator.free(entry.key);
        }
    }

    fn signalFromName(name: ?[]const u8) c_int {
        if (name == null) return c.SIGTERM;
        if (std.mem.eql(u8, name.?, "TERM")) return c.SIGTERM;
        if (std.mem.eql(u8, name.?, "KILL")) return c.SIGKILL;
        if (std.mem.eql(u8, name.?, "INT")) return c.SIGINT;
        return c.SIGTERM;
    }

    pub fn exists(self: *Runtime, path: []const u8) RuntimeError!bool {
        try validateSocketPath(path);
        if (self.sessions.contains(path)) return true;

        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
        }, 0) catch |err| switch (err) {
            error.FileNotFound => return false,
            error.AccessDenied => return RuntimeError.PermissionDenied,
            else => return RuntimeError.InvalidArgs,
        };
        _ = c.close(fd);
        return true;
    }

    pub fn create(self: *Runtime, path: []const u8, opts: SpawnOptions) RuntimeError!void {
        if (opts.argv.len == 0) return RuntimeError.InvalidArgs;
        try validateSocketPath(path);

        if (self.sessions.contains(path)) return RuntimeError.SessionAlreadyRunning;
        if (try self.exists(path)) return RuntimeError.SessionAlreadyRunning;

        const listener_fd = try createListener(path);
        const child = spawnChild(opts) catch |err| {
            _ = c.close(listener_fd);
            unlinkBestEffort(path);
            return err;
        };

        const key = try self.allocator.dupe(u8, path);
        self.sessions.put(key, .{
            .listener_fd = listener_fd,
            .master_fd = child.master_fd,
            .pid = child.pid,
        }) catch {
            _ = c.kill(child.pid, c.SIGKILL);
            _ = c.close(child.master_fd);
            _ = c.close(listener_fd);
            unlinkBestEffort(path);
            self.allocator.free(key);
            return RuntimeError.OutOfMemory;
        };
    }

    pub fn attach(self: *Runtime, path: []const u8, mode: AttachMode) RuntimeError!void {
        _ = self;
        _ = mode;
        if (path.len == 0) return RuntimeError.InvalidArgs;
        return RuntimeError.Unsupported;
    }

    pub fn resize(self: *Runtime, path: []const u8, cols: u16, rows: u16) RuntimeError!void {
        _ = self;
        _ = cols;
        _ = rows;
        if (path.len == 0) return RuntimeError.InvalidArgs;
        return RuntimeError.Unsupported;
    }

    pub fn terminate(self: *Runtime, path: []const u8, signal: ?[]const u8) RuntimeError!void {
        try validateSocketPath(path);

        const s = self.sessions.get(path) orelse return RuntimeError.SessionNotFound;
        if (c.kill(s.pid, signalFromName(signal)) != 0) return RuntimeError.InvalidArgs;
    }

    pub fn wait(self: *Runtime, path: []const u8) RuntimeError!ExitStatus {
        try validateSocketPath(path);

        const s = self.sessions.get(path) orelse return RuntimeError.SessionNotFound;
        var status: c_int = 0;
        const got = c.waitpid(s.pid, &status, 0);
        if (got < 0) return RuntimeError.InvalidArgs;

        var out = ExitStatus{};
        if (c.WIFEXITED(status)) {
            out.code = @intCast(c.WEXITSTATUS(status));
        } else if (c.WIFSIGNALED(status)) {
            out.signal = "SIGNALED";
        }

        self.cleanupSession(path);
        return out;
    }
};

test "exists: invalid args" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();
    try std.testing.expectError(RuntimeError.InvalidArgs, rt.exists(""));
}

test "exists: path too long" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();
    var buf: [200]u8 = undefined;
    @memset(&buf, 'a');
    try std.testing.expectError(RuntimeError.PathTooLong, rt.exists(buf[0..]));
}

test "exists: false for missing path" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();
    try std.testing.expectEqual(false, try rt.exists("/tmp/this-should-not-exist-msr-test.sock"));
}

test "create: invalid args" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();
    const opts = SpawnOptions{ .argv = &.{} };
    try std.testing.expectError(RuntimeError.InvalidArgs, rt.create("/tmp/msr-test.sock", opts));
}

test "create: already exists" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-create-exists-test.sock";
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o600);
    _ = c.close(fd);
    defer Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{"sh"} };
    try std.testing.expectError(RuntimeError.SessionAlreadyRunning, rt.create(path, opts));
}

test "create + wait: child exits with status" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-create-wait-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "exit 7" } };
    try rt.create(path, opts);
    const status = try rt.wait(path);
    try std.testing.expectEqual(@as(?i32, 7), status.code);
    try std.testing.expectEqual(false, try rt.exists(path));
}
