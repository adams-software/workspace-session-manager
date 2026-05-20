const std = @import("std");
const cli_main = @import("cli_main.zig");
const policy = @import("policy.zig");
const service_mod = @import("service.zig");

fn debugEnabled() bool {
    return std.posix.getenv("WSM_DEBUG") != null;
}

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled()) return;
    std.debug.print(fmt, args);
}

fn attachStateMessage(state: service_mod.AttachState) []const u8 {
    return switch (state) {
        .ready => "ready",
        .missing_data => "session data socket missing",
        .stale_data_socket => "session data socket stale",
        .stale_control_socket => "session control socket stale",
        .stale_both => "session data and control sockets stale",
        .data_not_connectable => "session data socket not connectable",
        .control_not_connectable => "session control socket not connectable",
    };
}

pub const Result = union(enum) {
    info: []const u8,
    err: []const u8,
    attached: []const u8,
    idle,
    detached,
};

pub const ResizeResult = enum {
    ignored,
    forwarded,
};

pub const SessionSize = struct {
    cols: u16,
    rows: u16,
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    host_bin: []const u8,
    vpty_bin: []const u8,
    logs_viewer_bin: []const u8,
    link: ?service_mod.AttachedSession,
    interactive_attached: bool,
    current_session_id: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) !Executor {
        const tool_paths = try cli_main.resolveToolPaths(allocator);
        errdefer tool_paths.deinit(allocator);
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
            .host_bin = tool_paths.host_bin,
            .vpty_bin = tool_paths.vpty_bin,
            .logs_viewer_bin = tool_paths.logs_viewer_bin,
            .link = null,
            .interactive_attached = false,
            .current_session_id = null,
        };
    }

    pub fn deinit(self: *Executor) void {
        if (self.link) |*link| link.deinit();
        self.allocator.free(self.root);
        self.allocator.free(self.host_bin);
        self.allocator.free(self.vpty_bin);
        self.allocator.free(self.logs_viewer_bin);
        if (self.current_session_id) |id| self.allocator.free(id);
    }

    pub fn run(self: *Executor, provider: *policy.Provider, action: policy.ResolvedAction) !Result {
        return self.runSized(provider, action, null, null);
    }

    pub fn runSized(self: *Executor, provider: *policy.Provider, action: policy.ResolvedAction, writer_fd: ?std.posix.fd_t, size: ?SessionSize) !Result {
        return switch (action) {
            .quit => .detached,
            .detach => self.runDetach() catch |err| .{ .err = try std.fmt.allocPrint(self.allocator, "detach failed: {s}", .{@errorName(err)}) },
            .kill => blk: {
                const current_id = self.current_session_id orelse break :blk .{ .err = try self.allocator.dupe(u8, "no current session") };
                var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin);
                service.killSession(provider, current_id, .term) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "kill failed: {s}", .{@errorName(err)}) };
                };
                break :blk .{ .info = try self.allocator.dupe(u8, "sent TERM") };
            },
            .logs => blk: {
                break :blk self.viewLogsLocal(provider) catch |err| .{
                    .err = try std.fmt.allocPrint(self.allocator, "logs failed: {s}", .{@errorName(err)}),
                };
            },
            .nav => |target| blk: {
                defer self.allocator.free(target);
                if (target.len == 0) break :blk .{ .err = try self.allocator.dupe(u8, "no target") };
                var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin);
                const state = service.attachState(provider, target) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "attach preflight failed: {s}", .{@errorName(err)}) };
                };
                if (state != .ready) {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "attach blocked: {s}", .{attachStateMessage(state)}) };
                }
                const attached_id = self.attachCanonicalVerified(provider, target, writer_fd, size) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "attach failed: {s}", .{@errorName(err)}) };
                };
                defer self.allocator.free(attached_id);
                self.interactive_attached = true;
                break :blk .{ .attached = try self.allocator.dupe(u8, attached_id) };
            },
            .attach => |target| blk: {
                defer self.allocator.free(target);
                if (target.len == 0) break :blk .{ .err = try self.allocator.dupe(u8, "attach target required") };
                var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin);
                const state = service.attachState(provider, target) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "attach preflight failed: {s}", .{@errorName(err)}) };
                };
                if (state != .ready) {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "attach blocked: {s}", .{attachStateMessage(state)}) };
                }
                const attached_id = self.attachCanonicalVerified(provider, target, writer_fd, size) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "attach failed: {s}", .{@errorName(err)}) };
                };
                defer self.allocator.free(attached_id);
                self.interactive_attached = true;
                break :blk .{ .attached = try self.allocator.dupe(u8, attached_id) };
            },
            .create => |name| blk: {
                defer self.allocator.free(name);
                const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
                var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin);
                const result = service.createAndAttach(provider, name, shell, null, null) catch |err| switch (err) {
                    error.SessionAlreadyExists => break :blk .{ .err = try self.allocator.dupe(u8, "session already exists") },
                    error.Empty, error.StartsWithSlash, error.EndsWithSlash, error.EmptySegment, error.DotSegment, error.InvalidChar => break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "invalid id: {s}", .{@errorName(err)}) },
                    else => break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "created but attach failed: {s}", .{@errorName(err)}) },
                };
                try self.enterAttached(result.attached, result.session.id);
                defer result.session.deinit(self.allocator);
                break :blk .{ .attached = try self.allocator.dupe(u8, result.session.id) };
            },
        };
    }

    pub fn openLogs(self: *Executor, provider: *policy.Provider, size: SessionSize) !Result {
        _ = size;
        return self.viewLogsLocal(provider);
    }

    pub fn viewLogsLocal(self: *Executor, provider: *policy.Provider) !Result {
        const base_id = self.current_session_id orelse return .{ .err = try self.allocator.dupe(u8, "no current session") };
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin);
        const transcript = try service.transcriptPath(provider, base_id);
        defer self.allocator.free(transcript);
        std.fs.accessAbsolute(transcript, .{}) catch {
            return .{ .err = try std.fmt.allocPrint(self.allocator, "logs failed for {s}: transcript not found", .{base_id}) };
        };

        const argv = [_][]const u8{ self.logs_viewer_bin, transcript };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        const term = try child.spawnAndWait();
        return switch (term) {
            .Exited => |code| if (code == 0) .idle else .{ .err = try std.fmt.allocPrint(self.allocator, "logs viewer exited with code {d}", .{code}) },
            .Signal => |sig| .{ .err = try std.fmt.allocPrint(self.allocator, "logs viewer exited on signal {d}", .{sig}) },
            else => .{ .err = try self.allocator.dupe(u8, "logs viewer exited unexpectedly") },
        };
    }

    pub fn createAndAttachSized(self: *Executor, provider: *policy.Provider, name: []const u8, shell: []const u8, size: SessionSize) !Result {
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin);
        const result = service.createAndAttach(provider, name, shell, size.cols, size.rows) catch |err| switch (err) {
            error.SessionAlreadyExists => return .{ .err = try self.allocator.dupe(u8, "session already exists") },
            error.Empty, error.StartsWithSlash, error.EndsWithSlash, error.EmptySegment, error.DotSegment, error.InvalidChar => return .{ .err = try std.fmt.allocPrint(self.allocator, "invalid id: {s}", .{@errorName(err)}) },
            else => return .{ .err = try std.fmt.allocPrint(self.allocator, "created but attach failed: {s}", .{@errorName(err)}) },
        };
        try self.enterAttached(result.attached, result.session.id);
        defer result.session.deinit(self.allocator);
        return .{ .attached = try self.allocator.dupe(u8, result.session.id) };
    }

    pub fn bootstrapInteractive(self: *Executor, provider: *policy.Provider, mode: cli_main.Mode) !Result {
        return switch (mode) {
            .interactive_attach => |id| self.run(provider, .{ .attach = try self.allocator.dupe(u8, id) }),
            .interactive_create_attach => |id| self.run(provider, .{ .create = try self.allocator.dupe(u8, id) }),
            else => .detached,
        };
    }

    pub fn isInteractiveAttached(self: *const Executor) bool {
        return self.interactive_attached;
    }

    pub fn attachedDataFd(self: *Executor) ?std.posix.fd_t {
        if (self.link) |*link| return link.dataFd();
        return null;
    }

    pub fn forwardResize(self: *Executor, cols: u16, rows: u16) !ResizeResult {
        if (self.link) |*link| {
            try link.resize(cols, rows);
            return .forwarded;
        }
        return .ignored;
    }

    pub fn pumpAttachedOutput(self: *Executor, provider: *policy.Provider, writer_fd: std.posix.fd_t) !Result {
        _ = provider;
        if (self.link) |*link| {
            const result = try link.pumpOutput(writer_fd);
            debugLog("executor pump stream_lost={} did_work={}\n", .{ result.stream_lost, result.did_work });
            if (result.stream_lost) {
                self.interactive_attached = false;
                link.detach();
                return .detached;
            }
            return if (result.did_work) .{ .info = try self.allocator.dupe(u8, "") } else .idle;
        }
        return .detached;
    }

    pub fn forwardInput(self: *Executor, bytes: []const u8) !bool {
        if (self.link) |*link| {
            try link.writeInput(bytes);
            return true;
        }
        return false;
    }

    fn runDetach(self: *Executor) !Result {
        if (self.link) |*link| link.detach();
        self.interactive_attached = false;
        return .detached;
    }

    fn attachCanonicalWithRetry(self: *Executor, provider: *policy.Provider, id: []const u8, timeout_ms: u64) !void {
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin);
        const attached = try service.attachWithRetry(provider, id, timeout_ms);
        try self.enterAttached(attached, id);
    }

    fn attachCanonical(self: *Executor, provider: *policy.Provider, id: []const u8) ![]u8 {
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin);
        const result = try service.attach(provider, id);
        defer result.session.deinit(self.allocator);
        try self.enterAttached(result.attached, result.session.id);
        return try self.allocator.dupe(u8, result.session.id);
    }

    fn attachCanonicalVerified(self: *Executor, provider: *policy.Provider, id: []const u8, writer_fd: ?std.posix.fd_t, size: ?SessionSize) ![]u8 {
        if (writer_fd == null or size == null) return try self.attachCanonical(provider, id);

        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin);
        var result = try service.attach(provider, id);
        errdefer result.attached.deinit();
        defer result.session.deinit(self.allocator);

        try result.attached.resize(size.?.cols, size.?.rows);
        const sync = try result.attached.pumpOutput(writer_fd.?);
        if (sync.stream_lost) return error.AttachLostImmediately;

        try self.enterAttached(result.attached, result.session.id);
        result.attached = undefined;
        return try self.allocator.dupe(u8, result.session.id);
    }

    fn enterAttached(self: *Executor, attached: service_mod.AttachedSession, id: []const u8) !void {
        if (self.link) |*link| link.deinit();
        self.link = attached;
        self.interactive_attached = true;
        try self.setCurrentSession(id);
    }

    fn setCurrentSession(self: *Executor, id: []const u8) !void {
        if (self.current_session_id) |current| self.allocator.free(current);
        self.current_session_id = try self.allocator.dupe(u8, id);
    }
};
