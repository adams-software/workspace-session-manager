const std = @import("std");
const builtin = @import("builtin");

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
    Unsupported,
};

/// MSR v0 runtime surface (single-session primitive).
/// This is a scaffold: behavior is implemented in follow-up commits.
pub const Runtime = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{ .allocator = allocator };
    }

    fn validateSocketPath(path: []const u8) RuntimeError!void {
        if (path.len == 0) return RuntimeError.InvalidArgs;
        // Common Unix sun_path limit is 108 incl. NUL; keep conservative.
        if (path.len >= 108) return RuntimeError.PathTooLong;
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
        _ = fd; // TODO: close fd via std.posix system helper in next pass.
        return true;
    }

    pub fn create(self: *Runtime, path: []const u8, opts: SpawnOptions) RuntimeError!void {
        if (opts.argv.len == 0) return RuntimeError.InvalidArgs;
        const already = try self.exists(path);
        if (already) return RuntimeError.SessionAlreadyRunning;

        // Placeholder for runtime bootstrap:
        // - create/bind/listen unix socket at `path`
        // - spawn child with forkpty using opts
        // - enter event loop
        return RuntimeError.Unsupported;
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
        _ = self;
        _ = signal;
        if (path.len == 0) return RuntimeError.InvalidArgs;
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
