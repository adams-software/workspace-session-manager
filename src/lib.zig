const std = @import("std");

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
    Unsupported,
};

/// MSR v0 runtime surface (single-session primitive).
/// This is a scaffold: behavior is implemented in follow-up commits.
pub const Runtime = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{ .allocator = allocator };
    }

    pub fn exists(self: *Runtime, path: []const u8) RuntimeError!bool {
        _ = self;
        if (path.len == 0) return RuntimeError.InvalidArgs;
        return RuntimeError.Unsupported;
    }

    pub fn create(self: *Runtime, path: []const u8, opts: SpawnOptions) RuntimeError!void {
        _ = self;
        if (path.len == 0 or opts.argv.len == 0) return RuntimeError.InvalidArgs;
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

test "runtime scaffold initializes" {
    var rt = Runtime.init(std.testing.allocator);
    try std.testing.expectError(RuntimeError.InvalidArgs, rt.exists(""));
}
