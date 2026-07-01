const std = @import("std");
const global_io = std.Io.Threaded.global_single_threaded.io();
const policy = @import("policy.zig");
const session_primitives = @import("session_primitives.zig");
const session_link_mod = @import("session_link.zig");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

pub const SessionRef = struct {
    id: []u8,
    paths: session_primitives.SessionPaths,

    pub fn deinit(self: SessionRef, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.paths.deinit(allocator);
    }
};

pub const CreateAttachResult = struct {
    session: SessionRef,
    attached: AttachedSession,
};

pub const AttachResult = struct {
    session: SessionRef,
    attached: AttachedSession,
};

pub const KillSignal = enum {
    term,
    kill,
};

pub const AttachedSession = struct {
    link: session_link_mod.SessionLink,

    pub fn deinit(self: *AttachedSession) void {
        self.link.deinit();
    }

    pub fn dataFd(self: *AttachedSession) ?std.posix.fd_t {
        return self.link.dataPollFd();
    }

    pub fn writeInput(self: *AttachedSession, bytes: []const u8) !void {
        try self.link.writeInput(bytes);
    }

    pub fn pumpOutput(self: *AttachedSession, output_fd: std.posix.fd_t) !session_link_mod.PumpResult {
        return try self.link.pumpDataToOutput(output_fd);
    }

    pub fn hasPendingOutput(self: *const AttachedSession) bool {
        return self.link.hasPendingOutput();
    }

    pub fn resize(self: *AttachedSession, cols: u16, rows: u16) !void {
        try self.link.resize(cols, rows);
    }

    pub fn detach(self: *AttachedSession) void {
        self.link.detach();
    }
};

pub const SessionInfo = struct {
    session: SessionRef,
    log_path: []u8,
    data_path_exists: bool,
    control_path_exists: bool,

    pub fn deinit(self: SessionInfo, allocator: std.mem.Allocator) void {
        self.session.deinit(allocator);
        allocator.free(self.log_path);
    }
};

pub const SessionHealth = enum {
    live,
    missing_data,
    stale_data_socket,
    stale_control_socket,
    stale_both,
};

pub const AttachState = enum {
    ready,
    missing_data,
    stale_data_socket,
    stale_control_socket,
    stale_both,
    data_not_connectable,
    control_not_connectable,
};

pub const CleanupStatus = enum {
    keep,
    remove,
};

pub const CleanupEntry = struct {
    info: SessionInfo,
    health: SessionHealth,
    cleanup: CleanupStatus,
    remove_data: bool,
    remove_control: bool,

    pub fn deinit(self: CleanupEntry, allocator: std.mem.Allocator) void {
        self.info.deinit(allocator);
    }
};

pub const CleanupSummary = struct {
    entries: []CleanupEntry,

    pub fn deinit(self: CleanupSummary, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub const WorkspaceService = struct {
    allocator: std.mem.Allocator,
    host_bin: []const u8,
    vpty_bin: []const u8,
    ptylog_bin: []const u8,

    pub fn init(allocator: std.mem.Allocator, host_bin: []const u8, vpty_bin: []const u8, ptylog_bin: []const u8) WorkspaceService {
        return .{
            .allocator = allocator,
            .host_bin = host_bin,
            .vpty_bin = vpty_bin,
            .ptylog_bin = ptylog_bin,
        };
    }

    pub fn create(self: *WorkspaceService, provider: *policy.Provider, id: []const u8, shell: []const u8, cols: ?u16, rows: ?u16) !SessionRef {
        var paths = try session_primitives.createSession(self.allocator, self.host_bin, provider, .{
            .id = id,
            .shell = shell,
            .vpty_bin = self.vpty_bin,
            .ptylog_bin = self.ptylog_bin,
            .cols = cols,
            .rows = rows,
        });
        defer paths.deinit(self.allocator);

        return .{
            .id = try self.allocator.dupe(u8, paths.id),
            .paths = try session_primitives.pathsForId(self.allocator, provider, paths.id),
        };
    }

    pub fn createAndAttach(self: *WorkspaceService, provider: *policy.Provider, id: []const u8, shell: []const u8, cols: ?u16, rows: ?u16) !CreateAttachResult {
        const session = try self.create(provider, id, shell, cols, rows);
        errdefer session.deinit(self.allocator);
        const attached = try self.attachWithRetry(provider, session.id, 2000);
        return .{
            .session = session,
            .attached = attached,
        };
    }


    pub fn attach(self: *WorkspaceService, provider: *policy.Provider, id: []const u8) !AttachResult {
        const attached = try self.attachOnce(provider, id);
        return .{
            .session = .{
                .id = try self.allocator.dupe(u8, id),
                .paths = try session_primitives.pathsForId(self.allocator, provider, id),
            },
            .attached = attached,
        };
    }

    pub fn sessionRef(self: *WorkspaceService, provider: *policy.Provider, id: []const u8) !SessionRef {
        const paths = try session_primitives.pathsForId(self.allocator, provider, id);
        return .{
            .id = try self.allocator.dupe(u8, id),
            .paths = paths,
        };
    }

    pub fn logPath(self: *WorkspaceService, provider: *policy.Provider, id: []const u8) ![]u8 {
        const session = try self.sessionRef(provider, id);
        defer session.deinit(self.allocator);
        return try std.fmt.allocPrint(self.allocator, "{s}.log", .{session.paths.data_path[0 .. session.paths.data_path.len - 4]});
    }

    pub fn sessionInfo(self: *WorkspaceService, provider: *policy.Provider, id: []const u8) !SessionInfo {
        const session = try self.sessionRef(provider, id);
        errdefer session.deinit(self.allocator);
        const log_path = try self.logPath(provider, id);
        return .{
            .session = session,
            .log_path = log_path,
            .data_path_exists = pathExists(session.paths.data_path),
            .control_path_exists = pathExists(session.paths.control_path),
        };
    }

    pub fn listSessionIds(self: *WorkspaceService, provider: *policy.Provider) ![][]u8 {
        return policy.scanSessionIds(self.allocator, provider.root);
    }

    pub fn cleanupEntry(self: *WorkspaceService, provider: *policy.Provider, id: []const u8) !CleanupEntry {
        const info = try self.sessionInfo(provider, id);
        const data_stale = if (info.data_path_exists) try isStaleSocket(info.session.paths.data_path) else false;
        const control_stale = if (info.control_path_exists) try isStaleSocket(info.session.paths.control_path) else false;

        const session_health: SessionHealth = if (!info.data_path_exists)
            .missing_data
        else if (data_stale and control_stale)
            .stale_both
        else if (data_stale)
            .stale_data_socket
        else if (control_stale)
            .stale_control_socket
        else
            .live;

        return .{
            .info = info,
            .health = session_health,
            .cleanup = if (data_stale or control_stale) .remove else .keep,
            .remove_data = data_stale,
            .remove_control = control_stale,
        };
    }

    pub fn cleanupReport(self: *WorkspaceService, provider: *policy.Provider) !CleanupSummary {
        const ids = try self.listSessionIds(provider);
        defer {
            for (ids) |id| self.allocator.free(id);
            self.allocator.free(ids);
        }

        var out: std.ArrayList(CleanupEntry) = .empty;
        errdefer {
            for (out.items) |item| item.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        for (ids) |id| {
            try out.append(self.allocator, try self.cleanupEntry(provider, id));
        }
        return .{ .entries = try out.toOwnedSlice(self.allocator) };
    }

    pub fn applyCleanupEntry(_: *WorkspaceService, entry: CleanupEntry) void {
        if (entry.remove_data) {
            unlinkBestEffort(entry.info.session.paths.data_path);
        }
        if (entry.remove_control) {
            unlinkBestEffort(entry.info.session.paths.control_path);
        }
    }

    pub fn health(self: *WorkspaceService, provider: *policy.Provider, id: []const u8) !SessionHealth {
        const entry = try self.cleanupEntry(provider, id);
        defer entry.deinit(self.allocator);
        return entry.health;
    }

    pub fn attachState(self: *WorkspaceService, provider: *policy.Provider, id: []const u8) !AttachState {
        const session = try self.sessionRef(provider, id);
        defer session.deinit(self.allocator);

        if (!pathExists(session.paths.data_path)) return .missing_data;
        return .ready;
    }

    pub fn killSession(self: *WorkspaceService, provider: *policy.Provider, id: []const u8, sig: KillSignal) !void {
        var attached = try self.attachOnce(provider, id);
        defer attached.deinit();
        try attached.link.signal(switch (sig) {
            .term => .term,
            .kill => .kill,
        });
    }

    pub fn attachWithRetry(self: *WorkspaceService, provider: *policy.Provider, id: []const u8, timeout_ms: u64) !AttachedSession {
        const deadline = monotonicMs() + timeout_ms;
        while (true) {
            return self.attachOnce(provider, id) catch |err| {
                if (monotonicMs() >= deadline) return err;
                switch (err) {
                    error.ConnectFailed => {
                        _ = c.usleep(20_000);
                        continue;
                    },
                    else => return err,
                }
            };
        }
    }

    fn attachOnce(self: *WorkspaceService, provider: *policy.Provider, id: []const u8) !AttachedSession {
        var paths = try session_primitives.pathsForId(self.allocator, provider, id);
        defer paths.deinit(self.allocator);

        var link = session_link_mod.SessionLink.init(self.allocator);
        errdefer link.deinit();
        try link.attach(.{
            .data_path = paths.data_path,
            .control_path = if (pathExists(paths.control_path)) paths.control_path else null,
        });
        return .{ .link = link };
    }
};

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(global_io, path, .{}) catch return false;
    return true;
}

fn unlinkBestEffort(path: []const u8) void {
    var buf: [108:0]u8 = [_:0]u8{0} ** 108;
    if (path.len >= 108) return;
    std.mem.copyForwards(u8, buf[0..path.len], path);
    _ = c.unlink(buf[0..path.len :0].ptr);
}

fn isStaleSocket(path: []const u8) !bool {
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.IoError;
    defer _ = c.close(fd);

    const rc = c.connect(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un)));
    if (rc == 0) return false;

    const e = std.posix.errno(-1);
    if (e == .CONNREFUSED or e == .NOENT) return true;
    if (e == .ACCES) return error.PermissionDenied;
    return false;
}

fn isConnectableSocket(path: []const u8) !bool {
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.IoError;
    defer _ = c.close(fd);

    const rc = c.connect(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un)));
    if (rc == 0) return true;

    const e = std.posix.errno(-1);
    if (e == .CONNREFUSED or e == .NOENT or e == .NOTSOCK) return false;
    if (e == .ACCES) return error.PermissionDenied;
    return false;
}

fn monotonicMs() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ms_per_s + @as(u64, @intCast(@divTrunc(ts.tv_nsec, std.time.ns_per_ms)));
}
