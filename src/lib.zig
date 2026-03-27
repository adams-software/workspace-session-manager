const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
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

/// MSR v0 runtime surface (single-session primitive).
/// This is a scaffold: behavior is implemented in follow-up commits.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    listeners: std.StringHashMap(c_int),

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{
            .allocator = allocator,
            .listeners = std.StringHashMap(c_int).init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        var it = self.listeners.iterator();
        while (it.next()) |entry| {
            _ = c.close(entry.value_ptr.*);
            unlinkBestEffort(entry.key_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.listeners.deinit();
    }

    fn validateSocketPath(path: []const u8) RuntimeError!void {
        if (path.len == 0) return RuntimeError.InvalidArgs;
        // Common Unix sun_path limit is 108 incl. NUL; keep conservative.
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

    pub fn exists(self: *Runtime, path: []const u8) RuntimeError!bool {
        _ = self;
        try validateSocketPath(path);

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

        if (self.listeners.contains(path)) return RuntimeError.SessionAlreadyRunning;
        const already = try self.exists(path);
        if (already) return RuntimeError.SessionAlreadyRunning;

        const fd = try createListener(path);
        const key = try self.allocator.dupe(u8, path);
        self.listeners.put(key, fd) catch {
            _ = c.close(fd);
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
        _ = signal;
        try validateSocketPath(path);

        if (self.listeners.fetchRemove(path)) |entry| {
            _ = c.close(entry.value);
            unlinkBestEffort(path);
            self.allocator.free(entry.key);
            return;
        }

        const has = try self.exists(path);
        if (!has) return RuntimeError.SessionNotFound;
        return RuntimeError.Unsupported;
    }

    pub fn wait(self: *Runtime, path: []const u8) RuntimeError!ExitStatus {
        _ = self;
        if (path.len == 0) return RuntimeError.InvalidArgs;
        return RuntimeError.Unsupported;
    }
};

test "exists: invalid args" {
    var rt = Runtime.init(std.testing.allocator);
    try std.testing.expectError(RuntimeError.InvalidArgs, rt.exists(""));
}

test "exists: path too long" {
    var rt = Runtime.init(std.testing.allocator);
    var buf: [200]u8 = undefined;
    @memset(&buf, 'a');
    try std.testing.expectError(RuntimeError.PathTooLong, rt.exists(buf[0..]));
}

test "exists: false for missing path" {
    var rt = Runtime.init(std.testing.allocator);
    try std.testing.expectEqual(false, try rt.exists("/tmp/this-should-not-exist-msr-test.sock"));
}

test "create: invalid args" {
    var rt = Runtime.init(std.testing.allocator);
    const opts = SpawnOptions{ .argv = &.{} };
    try std.testing.expectError(RuntimeError.InvalidArgs, rt.create("/tmp/msr-test.sock", opts));
}

test "create: already exists" {
    var rt = Runtime.init(std.testing.allocator);

    const path = "/tmp/msr-create-exists-test.sock";
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o600);
    _ = fd;
    const opts = SpawnOptions{ .argv = &.{"sh"} };
    try std.testing.expectError(RuntimeError.SessionAlreadyRunning, rt.create(path, opts));
}
