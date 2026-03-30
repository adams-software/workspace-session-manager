// LEGACY RUNTIME (v1/v1.5)
//
// This file remains only as a compatibility/quarantine surface while the v2
// architecture is being finished. It is NOT the source of truth for active
// design or new feature work.
//
// Active v2 path:
// - src/host.zig
// - src/protocol.zig
// - src/server.zig
// - src/client.zig
// - src/main.zig
//
// If you are working on current architecture, start there instead of here.
const std = @import("std");
const _rpc = @import("rpc.zig");
pub const rpc = _rpc;
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/ioctl.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
});

pub const ExitStatus = struct {
    code: ?i32 = null,
    signal: ?[]const u8 = null,
};

pub const Status = enum {
    not_found,
    running,
    exited_pending_wait,
    stale,
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
    SessionEnded,
    InternalPutFailed,
};

const SessionState = enum {
    running,
    exited_pending_wait,
};

const Session = struct {
    listener_fd: c_int,
    master_fd: c_int,
    pid: c.pid_t,
    attached_fd: ?c_int,
    attached_thread_running: bool,
    state: SessionState,
    exit_status: ExitStatus,
};

/// MSR v0 runtime surface (single-session primitive).
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(Session),
    threaded: std.Io.Threaded,
    io: std.Io,
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        var threaded = std.Io.Threaded.init(allocator, .{});
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(Session).init(allocator),
            .io = threaded.io(),
            .threaded = threaded,
            .mutex = .init,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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

    fn isStaleSocket(path: []const u8) RuntimeError!bool {
        var addr: c.struct_sockaddr_un = undefined;
        @memset(std.mem.asBytes(&addr), 0);
        addr.sun_family = c.AF_UNIX;
        std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
        addr.sun_path[path.len] = 0;

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return RuntimeError.InvalidArgs;
        defer _ = c.close(fd);

        const rc = c.connect(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un)));
        if (rc == 0) return false; // live listener exists

        const e = std.c.errno(-1);
        if (e == .CONNREFUSED or e == .NOENT) return true;
        if (e == .ACCES) return RuntimeError.PermissionDenied;
        // Conservative: unknown failure means don't treat as stale.
        return false;
    }

    fn createListener(path: []const u8) RuntimeError!c_int {
        var addr: c.struct_sockaddr_un = undefined;
        @memset(std.mem.asBytes(&addr), 0);
        addr.sun_family = c.AF_UNIX;
        std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
        addr.sun_path[path.len] = 0;

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return RuntimeError.InvalidArgs;

        if (try isStaleSocket(path)) {
            unlinkBestEffort(path);
        }

        if (c.bind(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) {
            const e = std.c.errno(-1);
            _ = c.close(fd);
            return switch (e) {
                .ADDRINUSE => RuntimeError.SessionAlreadyRunning,
                .ACCES => RuntimeError.PermissionDenied,
                else => RuntimeError.InvalidArgs,
            };
        }

        if (c.listen(fd, 16) != 0) {
            const e = std.c.errno(-1);
            _ = c.close(fd);
            unlinkBestEffort(path);
            return switch (e) {
                .ACCES => RuntimeError.PermissionDenied,
                else => RuntimeError.InvalidArgs,
            };
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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

    fn writeAll(fd: c_int, bytes: []const u8) RuntimeError!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(fd, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                const e = std.c.errno(-1);
                if (e == .INTR or e == .AGAIN) continue;
                return RuntimeError.InvalidArgs;
            }
            if (n == 0) return RuntimeError.InvalidArgs;
            off += @intCast(n);
        }
    }

    pub fn exists(self: *Runtime, path: []const u8) RuntimeError!bool {
        try validateSocketPath(path);
        self.mutex.lockUncancelable(self.io);
        const has_session = self.sessions.contains(path);
        self.mutex.unlock(self.io);
        if (has_session) return true;

        // Filesystem-truth for manager discovery: return true iff a socket node exists on disk.
        // (A stale socket path counts as existing until reclaimed/cleaned.)
        var st: c.struct_stat = undefined;
        const rc = c.stat(path.ptr, &st);
        if (rc != 0) {
            const e = std.c.errno(-1);
            return switch (e) {
                .NOENT, .NODEV => false,
                .ACCES => RuntimeError.PermissionDenied,
                else => RuntimeError.InvalidArgs,
            };
        }
        return (st.st_mode & c.S_IFMT) == c.S_IFSOCK;
    }

    pub fn status(self: *Runtime, path: []const u8) RuntimeError!Status {
        try validateSocketPath(path);
        self.mutex.lockUncancelable(self.io);
        const local_status = if (self.sessions.get(path)) |s|
            switch (s.state) {
                .running => Status.running,
                .exited_pending_wait => Status.exited_pending_wait,
            }
        else
            null;
        self.mutex.unlock(self.io);
        if (local_status) |st| return st;

        // Filesystem/liveness fallback:
        // - if missing: not_found
        // - if present but stale: stale
        // - otherwise: running
        // Avoid open() on unix socket path (can return ENXIO on Linux).
        var st: c.struct_stat = undefined;
        if (c.stat(path.ptr, &st) != 0) {
            const e = std.c.errno(-1);
            return switch (e) {
                .NOENT, .NODEV => .not_found,
                .ACCES => RuntimeError.PermissionDenied,
                else => RuntimeError.InvalidArgs,
            };
        }
        if ((st.st_mode & c.S_IFMT) != c.S_IFSOCK) return .not_found;

        if (try isStaleSocket(path)) return .stale;
        return .running;
    }

    pub fn create(self: *Runtime, path: []const u8, opts: SpawnOptions) RuntimeError!void {
        if (opts.argv.len == 0) return RuntimeError.InvalidArgs;
        try validateSocketPath(path);

        self.mutex.lockUncancelable(self.io);
        const already_local = self.sessions.contains(path);
        self.mutex.unlock(self.io);
        if (already_local) return RuntimeError.SessionAlreadyRunning;

        // If the socket path exists on disk, decide whether to reclaim it.
        // - stale socket: unlink and proceed
        // - live socket: SessionAlreadyRunning
        // - non-socket node: SessionAlreadyRunning
        var st: c.struct_stat = undefined;
        if (c.stat(path.ptr, &st) == 0) {
            if ((st.st_mode & c.S_IFMT) != c.S_IFSOCK) {
                return RuntimeError.SessionAlreadyRunning;
            }
            if (!(try isStaleSocket(path))) {
                return RuntimeError.SessionAlreadyRunning;
            }
            unlinkBestEffort(path);
        }

        const listener_fd = try createListener(path);
        const child = spawnChild(opts) catch |err| {
            _ = c.close(listener_fd);
            unlinkBestEffort(path);
            return err;
        };

        const key = try self.allocator.dupe(u8, path);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.sessions.put(key, .{
            .listener_fd = listener_fd,
            .master_fd = child.master_fd,
            .pid = child.pid,
            .attached_fd = null,
            .attached_thread_running = false,
            .state = .running,
            .exit_status = .{},
        }) catch |put_err| {
            std.debug.print("msr: Runtime.create failed to register session in hashmap: {any}\n", .{put_err});
            _ = c.kill(child.pid, c.SIGKILL);
            _ = c.close(child.master_fd);
            _ = c.close(listener_fd);
            unlinkBestEffort(path);
            self.allocator.free(key);
            return RuntimeError.InternalPutFailed;
        };
    }

    pub fn resize(self: *Runtime, path: []const u8, cols: u16, rows: u16) RuntimeError!void {
        try validateSocketPath(path);
        if (cols == 0 or rows == 0) return RuntimeError.InvalidArgs;

        self.mutex.lockUncancelable(self.io);
        const s = self.sessions.get(path) orelse {
            self.mutex.unlock(self.io);
            return RuntimeError.SessionNotFound;
        };
        if (s.state != .running) {
            self.mutex.unlock(self.io);
            return RuntimeError.SessionNotFound;
        }
        const master_fd = s.master_fd;
        self.mutex.unlock(self.io);
        var ws = c.struct_winsize{
            .ws_row = @intCast(rows),
            .ws_col = @intCast(cols),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        if (c.ioctl(master_fd, c.TIOCSWINSZ, &ws) != 0) {
            const e = std.c.errno(-1);
            return switch (e) {
                .ACCES => RuntimeError.PermissionDenied,
                .INTR => RuntimeError.InvalidArgs,
                else => RuntimeError.InvalidArgs,
            };
        }
    }

    pub fn terminate(self: *Runtime, path: []const u8, signal: ?[]const u8) RuntimeError!void {
        try validateSocketPath(path);

        self.mutex.lockUncancelable(self.io);
        const s = self.sessions.get(path) orelse {
            self.mutex.unlock(self.io);
            return RuntimeError.SessionNotFound;
        };
        if (s.state != .running) {
            self.mutex.unlock(self.io);
            return RuntimeError.SessionNotFound;
        }
        const pid = s.pid;
        self.mutex.unlock(self.io);
        if (c.kill(pid, signalFromName(signal)) != 0) {
            const e = std.c.errno(-1);
            return switch (e) {
                .SRCH => RuntimeError.SessionNotFound,
                .PERM => RuntimeError.PermissionDenied,
                else => RuntimeError.InvalidArgs,
            };
        }
    }

    pub fn wait(self: *Runtime, path: []const u8) RuntimeError!ExitStatus {
        try validateSocketPath(path);

        self.mutex.lockUncancelable(self.io);
        {
            const s0 = self.sessions.get(path) orelse {
                self.mutex.unlock(self.io);
                return RuntimeError.SessionNotFound;
            };
            if (s0.state == .exited_pending_wait) {
                const out = s0.exit_status;
                self.mutex.unlock(self.io);
                self.cleanupSession(path);
                return out;
            }
        }

        const s = self.sessions.get(path) orelse {
            self.mutex.unlock(self.io);
            return RuntimeError.SessionNotFound;
        };
        const pid = s.pid;
        self.mutex.unlock(self.io);
        var wait_status: c_int = 0;
        var got: c.pid_t = -1;
        while (true) {
            got = c.waitpid(pid, &wait_status, 0);
            if (got >= 0) break;
            const e = std.c.errno(-1);
            if (e == .INTR) continue;
            return switch (e) {
                .CHILD => RuntimeError.SessionNotFound,
                .PERM => RuntimeError.PermissionDenied,
                else => RuntimeError.InvalidArgs,
            };
        }

        var out = ExitStatus{};
        if (c.WIFEXITED(wait_status)) {
            out.code = @intCast(c.WEXITSTATUS(wait_status));
        } else if (c.WIFSIGNALED(wait_status)) {
            out.signal = "SIGNALED";
        }

        self.mutex.lockUncancelable(self.io);
        if (self.sessions.getPtr(path)) |sp| {
            sp.state = .exited_pending_wait;
            sp.exit_status = out;
        }
        self.mutex.unlock(self.io);
        self.cleanupSession(path);
        return out;
    }

    pub fn pollExit(self: *Runtime, path: []const u8) RuntimeError!?ExitStatus {
        try validateSocketPath(path);
        self.mutex.lockUncancelable(self.io);
        const s = self.sessions.getPtr(path) orelse {
            self.mutex.unlock(self.io);
            return RuntimeError.SessionNotFound;
        };
        if (s.state == .exited_pending_wait) {
            const out = s.exit_status;
            self.mutex.unlock(self.io);
            return out;
        }
        const pid = s.pid;
        self.mutex.unlock(self.io);

        var wait_status: c_int = 0;
        const got = c.waitpid(pid, &wait_status, c.WNOHANG);
        if (got == 0) return null;
        if (got < 0) {
            const e = std.c.errno(-1);
            return switch (e) {
                .INTR => null,
                .CHILD => RuntimeError.SessionNotFound,
                .PERM => RuntimeError.PermissionDenied,
                else => RuntimeError.InvalidArgs,
            };
        }

        var out = ExitStatus{};
        if (c.WIFEXITED(wait_status)) {
            out.code = @intCast(c.WEXITSTATUS(wait_status));
        } else if (c.WIFSIGNALED(wait_status)) {
            out.signal = "SIGNALED";
        }
        self.mutex.lockUncancelable(self.io);
        if (self.sessions.getPtr(path)) |sp| {
            sp.state = .exited_pending_wait;
            sp.exit_status = out;
        }
        self.mutex.unlock(self.io);
        return out;
    }

    fn writeRpcRes(allocator: std.mem.Allocator, client_fd: c_int, res: rpc.ControlRes) RuntimeError!void {
        const res_bytes = rpc.encodeControlRes(allocator, res) catch return RuntimeError.InvalidArgs;
        defer allocator.free(res_bytes);
        rpc.writeFrame(client_fd, res_bytes) catch return RuntimeError.InvalidArgs;
    }

    fn writeRpcEvent(allocator: std.mem.Allocator, client_fd: c_int, ev: rpc.EventMsg) RuntimeError!void {
        const ev_bytes = rpc.encodeEventMsg(allocator, ev) catch return RuntimeError.InvalidArgs;
        defer allocator.free(ev_bytes);
        rpc.writeFrame(client_fd, ev_bytes) catch return RuntimeError.InvalidArgs;
    }

    fn bridgeAttached(self: *Runtime, allocator: std.mem.Allocator, path: []const u8, client_fd: c_int) RuntimeError!void {
        self.mutex.lockUncancelable(self.io);
        const s = self.sessions.get(path) orelse {
            self.mutex.unlock(self.io);
            return RuntimeError.SessionNotFound;
        };
        const master_fd = s.master_fd;
        self.mutex.unlock(self.io);

        defer {
            _ = c.close(client_fd);
        }

        var fds = [2]c.struct_pollfd{
            .{ .fd = client_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = master_fd, .events = c.POLLIN, .revents = 0 },
        };
        var buf: [4096]u8 = undefined;
        var b64_buf: [8192]u8 = undefined;
        var decoded_buf: [4096]u8 = undefined;

        while (true) {
            const pr = c.poll(&fds, 2, -1);
            if (pr < 0) {
                const e = std.c.errno(-1);
                if (e == .INTR) continue;
                return RuntimeError.InvalidArgs;
            }

            if ((fds[0].revents & c.POLLIN) != 0) {
                const frame = rpc.readFrame(allocator, client_fd, 64 * 1024) catch return;
                defer allocator.free(frame);

                const msg = rpc.parseDataMsg(allocator, frame) catch return RuntimeError.InvalidArgs;
                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(msg.bytes_b64) catch return RuntimeError.InvalidArgs;
                if (decoded_len > decoded_buf.len) return RuntimeError.InvalidArgs;
                std.base64.standard.Decoder.decode(decoded_buf[0..decoded_len], msg.bytes_b64) catch return RuntimeError.InvalidArgs;
                try writeAll(master_fd, decoded_buf[0..decoded_len]);
            }

            if ((fds[1].revents & c.POLLIN) != 0) {
                const n = c.read(master_fd, &buf, buf.len);
                if (n < 0) {
                    const e = std.c.errno(-1);
                    if (e == .INTR or e == .AGAIN) continue;
                    return RuntimeError.InvalidArgs;
                }
                if (n == 0) {
                    try writeRpcEvent(allocator, client_fd, .{ .kind = "session_end" });
                    return RuntimeError.SessionEnded;
                }
                const enc_len = std.base64.standard.Encoder.calcSize(@intCast(n));
                if (enc_len > b64_buf.len) return RuntimeError.InvalidArgs;
                _ = std.base64.standard.Encoder.encode(b64_buf[0..enc_len], buf[0..@intCast(n)]);
                const payload = rpc.encodeDataMsg(allocator, .{ .stream = "pty", .bytes_b64 = b64_buf[0..enc_len] }) catch return RuntimeError.InvalidArgs;
                defer allocator.free(payload);
                rpc.writeFrame(client_fd, payload) catch return RuntimeError.InvalidArgs;
            }

            if ((fds[1].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
                try writeRpcEvent(allocator, client_fd, .{ .kind = "session_end" });
                return RuntimeError.SessionEnded;
            }
            if ((fds[0].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) return;
        }
    }

    const AttachThreadCtx = struct {
        rt: *Runtime,
        allocator: std.mem.Allocator,
        path: []u8,
        client_fd: c_int,
    };

    fn attachThreadMain(ctx: *AttachThreadCtx) void {
        defer {
            ctx.allocator.free(ctx.path);
            ctx.allocator.destroy(ctx);
        }
        _ = ctx.rt.bridgeAttached(ctx.allocator, ctx.path, ctx.client_fd) catch {};

        // Mark worker finished; ensure future attaches see the correct state.
        ctx.rt.mutex.lockUncancelable(ctx.rt.io);
        if (ctx.rt.sessions.getPtr(ctx.path)) |sess| {
            if (sess.attached_fd == ctx.client_fd) sess.attached_fd = null;
            sess.attached_thread_running = false;
        }
        ctx.rt.mutex.unlock(ctx.rt.io);
    }

    pub fn serveControlOnce(self: *Runtime, allocator: std.mem.Allocator, path: []const u8, timeout_ms: i32) RuntimeError!bool {
        try validateSocketPath(path);
        self.mutex.lockUncancelable(self.io);
        const s = self.sessions.get(path) orelse {
            self.mutex.unlock(self.io);
            return RuntimeError.SessionNotFound;
        };
        const listener_fd = s.listener_fd;
        self.mutex.unlock(self.io);

        var pfd = c.struct_pollfd{ .fd = listener_fd, .events = c.POLLIN, .revents = 0 };
        const pr = c.poll(&pfd, 1, timeout_ms);
        if (pr < 0) {
            const e = std.c.errno(-1);
            if (e == .INTR) return false;
            return RuntimeError.InvalidArgs;
        }
        if (pr == 0) return false;

        const client_fd = c.accept(listener_fd, null, null);
        if (client_fd < 0) return RuntimeError.InvalidArgs;
        var keep_client_fd_open = false;
        defer {
            if (!keep_client_fd_open) _ = c.close(client_fd);
        }

        const req_bytes = rpc.readFrame(allocator, client_fd, 64 * 1024) catch return RuntimeError.InvalidArgs;
        defer allocator.free(req_bytes);

        const req = rpc.parseControlReq(allocator, req_bytes) catch return RuntimeError.InvalidArgs;

        var res = rpc.ControlRes{ .ok = false, .err = .{ .code = "unsupported" } };
        const qpath = req.path orelse path;

        if (std.mem.eql(u8, req.op, "exists")) {
            const ok = self.exists(qpath) catch false;
            res = .{ .ok = true, .exists = ok };
            try writeRpcRes(allocator, client_fd, res);
            return true;
        }

        if (std.mem.eql(u8, req.op, "resize")) {
            const cols = req.cols orelse 0;
            const rows = req.rows orelse 0;
            self.resize(qpath, cols, rows) catch |e| {
                res = switch (e) {
                    RuntimeError.SessionNotFound => .{ .ok = false, .err = .{ .code = "session_not_found" } },
                    RuntimeError.PermissionDenied => .{ .ok = false, .err = .{ .code = "permission_denied" } },
                    else => .{ .ok = false, .err = .{ .code = "invalid_args" } },
                };
                try writeRpcRes(allocator, client_fd, res);
                return true;
            };
            try writeRpcRes(allocator, client_fd, .{ .ok = true });
            return true;
        }

        if (std.mem.eql(u8, req.op, "terminate")) {
            self.terminate(qpath, req.signal) catch |e| {
                res = switch (e) {
                    RuntimeError.SessionNotFound => .{ .ok = false, .err = .{ .code = "session_not_found" } },
                    RuntimeError.PermissionDenied => .{ .ok = false, .err = .{ .code = "permission_denied" } },
                    else => .{ .ok = false, .err = .{ .code = "invalid_args" } },
                };
                try writeRpcRes(allocator, client_fd, res);
                return true;
            };
            try writeRpcRes(allocator, client_fd, .{ .ok = true });
            return true;
        }

        if (std.mem.eql(u8, req.op, "wait")) {
            const st = self.wait(qpath) catch |e| {
                res = switch (e) {
                    RuntimeError.SessionNotFound => .{ .ok = false, .err = .{ .code = "session_not_found" } },
                    RuntimeError.PermissionDenied => .{ .ok = false, .err = .{ .code = "permission_denied" } },
                    else => .{ .ok = false, .err = .{ .code = "invalid_args" } },
                };
                try writeRpcRes(allocator, client_fd, res);
                return true;
            };
            try writeRpcRes(allocator, client_fd, .{ .ok = true, .code = st.code, .signal = st.signal });
            return true;
        }

        if (std.mem.eql(u8, req.op, "attach")) {
            const mode = if (req.mode != null and std.mem.eql(u8, req.mode.?, "takeover")) AttachMode.takeover else AttachMode.exclusive;
            self.mutex.lockUncancelable(self.io);
            const old_fd_opt = blk: {
                if (self.sessions.get(qpath) == null) {
                    self.mutex.unlock(self.io);
                    try writeRpcRes(allocator, client_fd, .{ .ok = false, .err = .{ .code = "session_not_found" } });
                    return true;
                }
                var sess = self.sessions.getPtr(qpath).?;
                if (sess.state != .running) {
                    self.mutex.unlock(self.io);
                    try writeRpcRes(allocator, client_fd, .{ .ok = false, .err = .{ .code = "session_not_found" } });
                    return true;
                }
                if (sess.attached_fd != null and mode == .exclusive) {
                    self.mutex.unlock(self.io);
                    try writeRpcRes(allocator, client_fd, .{ .ok = false, .err = .{ .code = "session_running" } });
                    return true;
                }
                if (sess.attached_thread_running and mode == .exclusive) {
                    self.mutex.unlock(self.io);
                    try writeRpcRes(allocator, client_fd, .{ .ok = false, .err = .{ .code = "session_running" } });
                    return true;
                }
                const old_fd = if (mode == .takeover) sess.attached_fd else null;
                sess.attached_fd = client_fd;
                sess.attached_thread_running = true;
                break :blk old_fd;
            };
            self.mutex.unlock(self.io);
            if (old_fd_opt) |old_fd| {
                _ = c.shutdown(old_fd, c.SHUT_RDWR);
            }

            try writeRpcRes(allocator, client_fd, .{ .ok = true });
            // Allocate ctx from the runtime allocator (not the per-call allocator).
            // In tests, the per-call allocator is std.testing.allocator, and the
            // attach worker thread is detached; using std.testing.allocator here
            // causes leak detection races.
            const ctx = try self.allocator.create(AttachThreadCtx);
            ctx.* = .{
                .rt = self,
                .allocator = self.allocator,
                .path = try self.allocator.dupe(u8, qpath),
                .client_fd = client_fd,
            };
            const th = std.Thread.spawn(.{}, attachThreadMain, .{ctx}) catch {
                self.allocator.free(ctx.path);
                self.allocator.destroy(ctx);
                self.mutex.lockUncancelable(self.io);
                if (self.sessions.getPtr(qpath)) |sess| {
                    if (sess.attached_fd == client_fd) sess.attached_fd = null;
                    sess.attached_thread_running = false;
                }
                self.mutex.unlock(self.io);
                try writeRpcRes(allocator, client_fd, .{ .ok = false, .err = .{ .code = "internal" } });
                return true;
            };
            th.detach();
            keep_client_fd_open = true;
            return true;
        }

        try writeRpcRes(allocator, client_fd, res);
        return true;
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

test "exists: true for on-disk socket path" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-exists-socket-true.sock";
    Runtime.unlinkBestEffort(path);
    defer Runtime.unlinkBestEffort(path);

    // Create a socket node.
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.bind(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))));
    try std.testing.expectEqual(@as(c_int, 0), c.listen(fd, 1));
    defer _ = c.close(fd);

    try std.testing.expectEqual(true, try rt.exists(path));
}

test "status: not_found for missing path" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();
    try std.testing.expectEqual(Status.not_found, try rt.status("/tmp/this-should-not-exist-msr-status-test.sock"));
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
    try std.testing.expectEqual(Status.running, try rt.status(path));
    const status = try rt.wait(path);
    try std.testing.expectEqual(@as(?i32, 7), status.code);
    try std.testing.expectEqual(false, try rt.exists(path));
    try std.testing.expectError(RuntimeError.SessionNotFound, rt.wait(path));
}

test "create: leaves a socket on disk immediately" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-create-leaves-socket-test.sock";
    Runtime.unlinkBestEffort(path);
    defer Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } };
    try rt.create(path, opts);

    // Must exist on disk as a socket node right after create.
    try std.testing.expectEqual(true, try rt.exists(path));
    try std.testing.expectEqual(Status.running, try rt.status(path));

    // Cleanup.
    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
    try std.testing.expectEqual(false, try rt.exists(path));
}

test "create: socket persists after function returns" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-create-persists.sock";
    Runtime.unlinkBestEffort(path);
    defer Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 2" } };
    try rt.create(path, opts);

    // Give the runtime a moment; create() should not kill/unlink on success.
    _ = c.usleep(20_000);
    try std.testing.expectEqual(true, try rt.exists(path));
    try std.testing.expectEqual(Status.running, try rt.status(path));

    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
}

test "status: reports running for live socket not in local map" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-status-live-not-local.sock";
    Runtime.unlinkBestEffort(path);
    defer Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 2" } };
    try rt.create(path, opts);
    try std.testing.expectEqual(true, try rt.exists(path));

    // Force the status() implementation to take the filesystem fallback path
    // by using a different runtime (empty local map).
    var rt2 = Runtime.init(std.testing.allocator);
    defer rt2.deinit();
    try std.testing.expectEqual(Status.running, try rt2.status(path));

    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
}

test "status: reports stale for stale socket path" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-status-stale.sock";
    Runtime.unlinkBestEffort(path);
    defer Runtime.unlinkBestEffort(path);

    // Create a stale socket node: bind/listen then close without unlink.
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    const stale_fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    try std.testing.expect(stale_fd >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.bind(stale_fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))));
    try std.testing.expectEqual(@as(c_int, 0), c.listen(stale_fd, 1));
    _ = c.close(stale_fd);

    try std.testing.expectEqual(true, try rt.exists(path));
    try std.testing.expectEqual(Status.stale, try rt.status(path));
}

test "pollExit retains exit status in memory until wait consumes cleanup" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-poll-retain-wait-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "exit 9" } };
    try rt.create(path, opts);

    var polled: ?ExitStatus = null;
    var i: usize = 0;
    while (i < 200 and polled == null) : (i += 1) {
        polled = try rt.pollExit(path);
        if (polled == null) _ = c.usleep(10_000);
    }

    try std.testing.expect(polled != null);
    try std.testing.expectEqual(@as(?i32, 9), polled.?.code);
    try std.testing.expectEqual(true, try rt.exists(path));
    try std.testing.expectEqual(Status.exited_pending_wait, try rt.status(path));

    const waited = try rt.wait(path);
    try std.testing.expectEqual(@as(?i32, 9), waited.code);
    try std.testing.expectEqual(false, try rt.exists(path));
    try std.testing.expectError(RuntimeError.SessionNotFound, rt.wait(path));
}

test "create: stale socket path is reclaimed" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-stale-reclaim-test.sock";
    Runtime.unlinkBestEffort(path);

    // Create a stale socket node: bind/listen then close without unlink.
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    const stale_fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    try std.testing.expect(stale_fd >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.bind(stale_fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))));
    try std.testing.expectEqual(@as(c_int, 0), c.listen(stale_fd, 1));
    _ = c.close(stale_fd);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "exit 0" } };
    try rt.create(path, opts);
    _ = try rt.wait(path);
    try std.testing.expectEqual(false, try rt.exists(path));
}

test "resize: invalid args and not found" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    try std.testing.expectError(RuntimeError.InvalidArgs, rt.resize("", 80, 24));
    try std.testing.expectError(RuntimeError.InvalidArgs, rt.resize("/tmp/msr-none.sock", 0, 24));
    try std.testing.expectError(RuntimeError.SessionNotFound, rt.resize("/tmp/msr-none.sock", 80, 24));
}

test "resize: success on running session" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-resize-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } };
    try rt.create(path, opts);
    try rt.resize(path, 100, 30);
    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
}

test "lifecycle smoke: create resize terminate wait cleanup" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-lifecycle-smoke-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 5" } };
    try rt.create(path, opts);
    try std.testing.expectEqual(true, try rt.exists(path));

    try rt.resize(path, 120, 40);
    try rt.terminate(path, "TERM");

    const st = try rt.wait(path);
    // Terminated by signal or exits with shell-dependent code; both are acceptable.
    try std.testing.expect(st.signal != null or st.code != null);

    try std.testing.expectEqual(false, try rt.exists(path));
    try std.testing.expectError(RuntimeError.SessionNotFound, rt.wait(path));
}

fn connectUnix(path: []const u8) !c_int {
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
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

test "attach: socket client connect/disconnect roundtrip" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-attach-roundtrip-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 2" } };
    try rt.create(path, opts);

    const th = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });

    _ = c.usleep(20_000);
    const client_fd = try connectUnix(path);
    defer _ = c.close(client_fd);

    const req = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req);
    try rpc.writeFrame(client_fd, req);

    const res_bytes = try rpc.readFrame(std.testing.allocator, client_fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    const res = try rpc.parseControlRes(std.testing.allocator, res_bytes);
    try std.testing.expect(res.ok);

    _ = c.shutdown(client_fd, c.SHUT_RDWR);
    th.join();

    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
}

test "serveControlOnce: attach handshake rejects busy exclusive" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-rpc-attach-busy-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 2" } };
    try rt.create(path, opts);
    rt.sessions.getPtr(path).?.attached_fd = -2;

    const th = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });

    _ = c.usleep(20_000);
    const client_fd = try connectUnix(path);
    defer _ = c.close(client_fd);

    const req = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req);
    try rpc.writeFrame(client_fd, req);

    const res_bytes = try rpc.readFrame(std.testing.allocator, client_fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    const res = try rpc.parseControlRes(std.testing.allocator, res_bytes);
    try std.testing.expect(!res.ok);
    try std.testing.expect(res.err != null);
    try std.testing.expectEqualStrings("session_running", res.err.?.code);

    th.join();
    rt.sessions.getPtr(path).?.attached_fd = null;
    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
}

test "serveControlOnce: attach handshake accepts takeover when busy" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-rpc-attach-takeover-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 2" } };
    try rt.create(path, opts);
    rt.sessions.getPtr(path).?.attached_fd = -2;

    const th = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });

    _ = c.usleep(20_000);
    const client_fd = try connectUnix(path);
    defer _ = c.close(client_fd);

    const req = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "takeover" });
    defer std.testing.allocator.free(req);
    try rpc.writeFrame(client_fd, req);

    const res_bytes = try rpc.readFrame(std.testing.allocator, client_fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    const res = try rpc.parseControlRes(std.testing.allocator, res_bytes);
    try std.testing.expect(res.ok);

    _ = c.shutdown(client_fd, c.SHUT_RDWR);
    th.join();

    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
}

test "serveControlOnce: attached worker keeps host responsive for busy rejection" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-rpc-attach-responsive-busy-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "printf ready; sleep 2" } };
    try rt.create(path, opts);

    const host1 = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });

    _ = c.usleep(20_000);
    const client1 = try connectUnix(path);
    defer _ = c.close(client1);
    const req1 = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req1);
    try rpc.writeFrame(client1, req1);
    const res1_bytes = try rpc.readFrame(std.testing.allocator, client1, 64 * 1024);
    defer std.testing.allocator.free(res1_bytes);
    const res1 = try rpc.parseControlRes(std.testing.allocator, res1_bytes);
    try std.testing.expect(res1.ok);
    host1.join();

    const host2 = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });

    _ = c.usleep(20_000);
    const client2 = try connectUnix(path);
    defer _ = c.close(client2);
    const req2 = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req2);
    try rpc.writeFrame(client2, req2);
    const res2_bytes = try rpc.readFrame(std.testing.allocator, client2, 64 * 1024);
    defer std.testing.allocator.free(res2_bytes);
    const res2 = try rpc.parseControlRes(std.testing.allocator, res2_bytes);
    try std.testing.expect(!res2.ok);
    try std.testing.expect(res2.err != null);
    try std.testing.expectEqualStrings("session_running", res2.err.?.code);
    host2.join();

    _ = c.shutdown(client1, c.SHUT_RDWR);
    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
}

test "serveControlOnce: takeover replaces prior owner and new exclusive is busy" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-rpc-attach-takeover-displace-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "printf hello; sleep 2" } };
    try rt.create(path, opts);

    const host1 = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });
    _ = c.usleep(20_000);
    const client1 = try connectUnix(path);
    defer _ = c.close(client1);
    const req1 = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req1);
    try rpc.writeFrame(client1, req1);
    const res1_bytes = try rpc.readFrame(std.testing.allocator, client1, 64 * 1024);
    defer std.testing.allocator.free(res1_bytes);
    const res1 = try rpc.parseControlRes(std.testing.allocator, res1_bytes);
    try std.testing.expect(res1.ok);
    host1.join();

    const host2 = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });
    _ = c.usleep(20_000);
    const client2 = try connectUnix(path);
    defer _ = c.close(client2);
    const req2 = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "takeover" });
    defer std.testing.allocator.free(req2);
    try rpc.writeFrame(client2, req2);
    const res2_bytes = try rpc.readFrame(std.testing.allocator, client2, 64 * 1024);
    defer std.testing.allocator.free(res2_bytes);
    const res2 = try rpc.parseControlRes(std.testing.allocator, res2_bytes);
    try std.testing.expect(res2.ok);
    host2.join();

    const host3 = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });
    _ = c.usleep(20_000);
    const client3 = try connectUnix(path);
    defer _ = c.close(client3);
    const req3 = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req3);
    try rpc.writeFrame(client3, req3);
    const res3_bytes = try rpc.readFrame(std.testing.allocator, client3, 64 * 1024);
    defer std.testing.allocator.free(res3_bytes);
    const res3 = try rpc.parseControlRes(std.testing.allocator, res3_bytes);
    try std.testing.expect(!res3.ok);
    try std.testing.expect(res3.err != null);
    try std.testing.expectEqualStrings("session_running", res3.err.?.code);
    host3.join();

    _ = c.shutdown(client1, c.SHUT_RDWR);
    _ = c.shutdown(client2, c.SHUT_RDWR);
    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
}

test "serveControlOnce: stale old-owner disconnect does not clear new owner" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-rpc-attach-stale-owner-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "printf hello; sleep 3" } };
    try rt.create(path, opts);

    const host1 = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });
    _ = c.usleep(20_000);
    const client1 = try connectUnix(path);
    defer _ = c.close(client1);
    const req1 = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req1);
    try rpc.writeFrame(client1, req1);
    const res1_bytes = try rpc.readFrame(std.testing.allocator, client1, 64 * 1024);
    defer std.testing.allocator.free(res1_bytes);
    const res1 = try rpc.parseControlRes(std.testing.allocator, res1_bytes);
    try std.testing.expect(res1.ok);
    host1.join();

    const host2 = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });
    _ = c.usleep(20_000);
    const client2 = try connectUnix(path);
    defer _ = c.close(client2);
    const req2 = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "takeover" });
    defer std.testing.allocator.free(req2);
    try rpc.writeFrame(client2, req2);
    const res2_bytes = try rpc.readFrame(std.testing.allocator, client2, 64 * 1024);
    defer std.testing.allocator.free(res2_bytes);
    const res2 = try rpc.parseControlRes(std.testing.allocator, res2_bytes);
    try std.testing.expect(res2.ok);
    host2.join();

    _ = c.shutdown(client1, c.SHUT_RDWR);
    _ = c.usleep(50_000);

    const host3 = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });
    _ = c.usleep(20_000);
    const client3 = try connectUnix(path);
    defer _ = c.close(client3);
    const req3 = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req3);
    try rpc.writeFrame(client3, req3);
    const res3_bytes = try rpc.readFrame(std.testing.allocator, client3, 64 * 1024);
    defer std.testing.allocator.free(res3_bytes);
    const res3 = try rpc.parseControlRes(std.testing.allocator, res3_bytes);
    try std.testing.expect(!res3.ok);
    try std.testing.expect(res3.err != null);
    try std.testing.expectEqualStrings("session_running", res3.err.?.code);
    host3.join();

    _ = c.shutdown(client2, c.SHUT_RDWR);
    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
}

test "serveControlOnce: two exclusive attach attempts yield one winner and one busy" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-rpc-attach-race-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "printf hi; sleep 2" } };
    try rt.create(path, opts);

    const host1 = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });
    const host2 = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1000) catch {};
        }
    }.run, .{ &rt, path });

    _ = c.usleep(20_000);
    const client1 = try connectUnix(path);
    defer _ = c.close(client1);
    const client2 = try connectUnix(path);
    defer _ = c.close(client2);

    const req1 = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req1);
    const req2 = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req2);
    try rpc.writeFrame(client1, req1);
    try rpc.writeFrame(client2, req2);

    const res1_bytes = try rpc.readFrame(std.testing.allocator, client1, 64 * 1024);
    defer std.testing.allocator.free(res1_bytes);
    const res2_bytes = try rpc.readFrame(std.testing.allocator, client2, 64 * 1024);
    defer std.testing.allocator.free(res2_bytes);
    const res1 = try rpc.parseControlRes(std.testing.allocator, res1_bytes);
    const res2 = try rpc.parseControlRes(std.testing.allocator, res2_bytes);

    const ok_count: u8 = @intFromBool(res1.ok) + @intFromBool(res2.ok);
    try std.testing.expectEqual(@as(u8, 1), ok_count);
    if (!res1.ok) {
        try std.testing.expect(res1.err != null);
        try std.testing.expectEqualStrings("session_running", res1.err.?.code);
    }
    if (!res2.ok) {
        try std.testing.expect(res2.err != null);
        try std.testing.expectEqualStrings("session_running", res2.err.?.code);
    }

    host1.join();
    host2.join();
    _ = c.shutdown(client1, c.SHUT_RDWR);
    _ = c.shutdown(client2, c.SHUT_RDWR);
    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);
}

test "serveControlOnce: attach streams PTY output as data frame" {
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const path = "/tmp/msr-rpc-attach-stream-test.sock";
    Runtime.unlinkBestEffort(path);

    const opts = SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "printf hello; sleep 1" } };
    try rt.create(path, opts);

    const th = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *Runtime, p: []const u8) void {
            _ = runtime.serveControlOnce(std.testing.allocator, p, 1500) catch {};
        }
    }.run, .{ &rt, path });

    _ = c.usleep(20_000);
    const client_fd = try connectUnix(path);
    defer _ = c.close(client_fd);

    const req = try rpc.encodeControlReq(std.testing.allocator, .{ .op = "attach", .path = path, .mode = "exclusive" });
    defer std.testing.allocator.free(req);
    try rpc.writeFrame(client_fd, req);

    const res_bytes = try rpc.readFrame(std.testing.allocator, client_fd, 64 * 1024);
    defer std.testing.allocator.free(res_bytes);
    const res = try rpc.parseControlRes(std.testing.allocator, res_bytes);
    try std.testing.expect(res.ok);

    const frame = try rpc.readFrame(std.testing.allocator, client_fd, 256 * 1024);
    defer std.testing.allocator.free(frame);
    const msg = try rpc.parseDataMsg(std.testing.allocator, frame);
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(msg.bytes_b64);
    const decoded = try std.testing.allocator.alloc(u8, decoded_len);
    defer std.testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, msg.bytes_b64);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "hello") != null);

    _ = c.shutdown(client_fd, c.SHUT_RDWR);
    th.join();

    _ = rt.wait(path) catch {};
}
