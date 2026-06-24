const std = @import("std");
const global_io = std.Io.Threaded.global_single_threaded.io();
const cli_main = @import("cli_main.zig");
const commands = @import("commands.zig");
const policy = @import("policy.zig");
const service_mod = @import("service.zig");

fn debugEnabled() bool {
    return std.c.getenv("WSM_DEBUG") != null;
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

fn attachOutcomeMessage(allocator: std.mem.Allocator, outcome: commands.AttachOutcome, query: []const u8) ![]u8 {
    return switch (outcome) {
        .ready => unreachable,
        .no_sessions => try allocator.dupe(u8, "no sessions found; press c to create one"),
        .no_match => try std.fmt.allocPrint(allocator, "no session matching '{s}'", .{query}),
        .ambiguous => try std.fmt.allocPrint(allocator, "ambiguous session '{s}'", .{query}),
        .not_attachable => |payload| try std.fmt.allocPrint(allocator, "session '{s}' is not attachable: {s}", .{ payload.id, attachStateMessage(payload.state) }),
    };
}

fn createInvalidIdMessage(allocator: std.mem.Allocator, reason: commands.CreateInvalidIdReason) ![]u8 {
    return try std.fmt.allocPrint(allocator, "invalid id: {s}", .{switch (reason) {
        .empty => "Empty",
        .starts_with_slash => "StartsWithSlash",
        .ends_with_slash => "EndsWithSlash",
        .empty_segment => "EmptySegment",
        .dot_segment => "DotSegment",
        .invalid_char => "InvalidChar",
    }});
}

fn killOutcomeMessage(allocator: std.mem.Allocator, outcome: commands.KillOutcome) ![]u8 {
    return switch (outcome) {
        .signaled => |sig| try std.fmt.allocPrint(allocator, "sent {s}", .{if (sig == .kill) "KILL" else "TERM"}),
        .no_current_session => try allocator.dupe(u8, "no current session"),
        .no_control => try allocator.dupe(u8, "kill failed: session has no control socket"),
    };
}

fn backOutcomeMessage(allocator: std.mem.Allocator, outcome: commands.BackOutcome) ![]u8 {
    return switch (outcome) {
        .ready => unreachable,
        .no_previous_session => try allocator.dupe(u8, "no previous session"),
        .not_attachable => |payload| try std.fmt.allocPrint(allocator, "session '{s}' is not attachable: {s}", .{ payload.id, attachStateMessage(payload.state) }),
    };
}

fn navOutcomeMessage(allocator: std.mem.Allocator, outcome: commands.NavOutcome) ![]u8 {
    return switch (outcome) {
        .ready => unreachable,
        .no_target => try allocator.dupe(u8, "no target"),
        .not_attachable => |payload| try std.fmt.allocPrint(allocator, "session '{s}' is not attachable: {s}", .{ payload.id, attachStateMessage(payload.state) }),
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
    host_bin: []const u8,
    vpty_bin: []const u8,
    ptylog_bin: []const u8,
    logs_viewer_bin: []const u8,
    link: ?service_mod.AttachedSession,
    interactive_attached: bool,
    current_session_id: ?[]u8,
    previous_session_id: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, _: []const u8) !Executor {
        const tool_paths = try cli_main.resolveToolPaths(allocator);
        errdefer tool_paths.deinit(allocator);
        return .{
            .allocator = allocator,
            .host_bin = tool_paths.host_bin,
            .vpty_bin = tool_paths.vpty_bin,
            .ptylog_bin = tool_paths.ptylog_bin,
            .logs_viewer_bin = tool_paths.logs_viewer_bin,
            .link = null,
            .interactive_attached = false,
            .current_session_id = null,
            .previous_session_id = null,
        };
    }

    pub fn deinit(self: *Executor) void {
        if (self.link) |*link| link.deinit();
        self.allocator.free(self.host_bin);
        self.allocator.free(self.vpty_bin);
        self.allocator.free(self.ptylog_bin);
        self.allocator.free(self.logs_viewer_bin);
        if (self.current_session_id) |id| self.allocator.free(id);
        if (self.previous_session_id) |id| self.allocator.free(id);
    }

    pub fn run(self: *Executor, provider: *policy.Provider, action: policy.ResolvedAction) !Result {
        return self.runSized(provider, action, null, null);
    }

    pub fn runSized(self: *Executor, provider: *policy.Provider, action: policy.ResolvedAction, writer_fd: ?std.posix.fd_t, size: ?SessionSize) !Result {
        return switch (action) {
            .quit => .detached,
            .detach => self.runDetach() catch |err| .{ .err = try std.fmt.allocPrint(self.allocator, "detach failed: {s}", .{@errorName(err)}) },
            .back => self.handleBack(provider, writer_fd, size),
            .kill => self.handleKill(provider),
            .logs => blk: {
                break :blk self.viewLogsLocal(provider) catch |err| .{
                    .err = try std.fmt.allocPrint(self.allocator, "logs failed: {s}", .{@errorName(err)}),
                };
            },
            .nav => |target| self.handleNav(provider, target, writer_fd, size),
            .attach => |target| self.handleAttach(provider, target, writer_fd, size),
            .create => |name| self.handleCreate(provider, name, size),
        };
    }

    pub fn openLogs(self: *Executor, provider: *policy.Provider, size: SessionSize) !Result {
        _ = size;
        return self.viewLogsLocal(provider);
    }

    pub fn viewLogsLocal(self: *Executor, provider: *policy.Provider) !Result {
        const base_id = self.current_session_id orelse return .{ .err = try self.allocator.dupe(u8, "no current session") };
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin, self.ptylog_bin);
        const log_path = try service.logPath(provider, base_id);
        defer self.allocator.free(log_path);
        std.Io.Dir.accessAbsolute(global_io, log_path, .{}) catch {
            return .{ .err = try std.fmt.allocPrint(self.allocator, "logs failed for {s}: log not found", .{base_id}) };
        };

        const argv = [_][]const u8{ self.logs_viewer_bin, log_path };
        var spawn_runtime = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        defer spawn_runtime.deinit();
        const spawn_io = spawn_runtime.io();
        var child = try std.process.spawn(spawn_io, .{
            .argv = &argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        defer child.kill(spawn_io);
        const term = try child.wait(spawn_io);
        return switch (term) {
            .exited => |code| if (code == 0) .idle else .{ .err = try std.fmt.allocPrint(self.allocator, "logs viewer exited with code {d}", .{code}) },
            .signal => |sig| .{ .err = try std.fmt.allocPrint(self.allocator, "logs viewer exited on signal {d}", .{sig}) },
            else => .{ .err = try self.allocator.dupe(u8, "logs viewer exited unexpectedly") },
        };
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

    fn handleBack(self: *Executor, provider: *policy.Provider, writer_fd: ?std.posix.fd_t, size: ?SessionSize) Result {
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin, self.ptylog_bin);
        var outcome = commands.planBack(self.allocator, provider, &service, self.current_session_id, self.previous_session_id) catch |err| {
            return .{ .err = std.fmt.allocPrint(self.allocator, "back planning failed: {s}", .{@errorName(err)}) catch unreachable };
        };
        defer outcome.deinit(self.allocator);
        return switch (outcome) {
            .ready => |previous_id| self.attachReadyId(provider, previous_id, writer_fd, size, "back"),
            else => .{ .err = backOutcomeMessage(self.allocator, outcome) catch unreachable },
        };
    }

    fn handleKill(self: *Executor, provider: *policy.Provider) Result {
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin, self.ptylog_bin);
        const outcome = commands.killCurrentSession(provider, &service, self.current_session_id, .kill) catch |err| {
            return .{ .err = std.fmt.allocPrint(self.allocator, "kill failed: {s}", .{@errorName(err)}) catch unreachable };
        };
        return switch (outcome) {
            .signaled => .{ .info = killOutcomeMessage(self.allocator, outcome) catch unreachable },
            else => .{ .err = killOutcomeMessage(self.allocator, outcome) catch unreachable },
        };
    }

    fn handleNav(self: *Executor, provider: *policy.Provider, target: []u8, writer_fd: ?std.posix.fd_t, size: ?SessionSize) Result {
        defer self.allocator.free(target);
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin, self.ptylog_bin);
        var outcome = commands.planResolvedTarget(self.allocator, provider, &service, target) catch |err| {
            return .{ .err = std.fmt.allocPrint(self.allocator, "nav planning failed: {s}", .{@errorName(err)}) catch unreachable };
        };
        defer outcome.deinit(self.allocator);
        return switch (outcome) {
            .ready => |resolved_target| self.attachReadyId(provider, resolved_target, writer_fd, size, "attach"),
            else => .{ .err = navOutcomeMessage(self.allocator, outcome) catch unreachable },
        };
    }

    fn handleAttach(self: *Executor, provider: *policy.Provider, target: []u8, writer_fd: ?std.posix.fd_t, size: ?SessionSize) Result {
        defer self.allocator.free(target);
        if (target.len == 0) return .{ .err = self.allocator.dupe(u8, "attach target required") catch unreachable };
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin, self.ptylog_bin);
        var outcome = commands.planAttach(self.allocator, provider, &service, target) catch |err| {
            return .{ .err = std.fmt.allocPrint(self.allocator, "attach planning failed: {s}", .{@errorName(err)}) catch unreachable };
        };
        defer outcome.deinit(self.allocator);
        return switch (outcome) {
            .ready => |resolved_target| self.attachReadyId(provider, resolved_target, writer_fd, size, "attach"),
            else => .{ .err = attachOutcomeMessage(self.allocator, outcome, target) catch unreachable },
        };
    }

    fn handleCreate(self: *Executor, provider: *policy.Provider, name: []u8, size: ?SessionSize) Result {
        defer self.allocator.free(name);
        const shell = if (std.c.getenv("SHELL")) |value| std.mem.span(value) else "/bin/sh";
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin, self.ptylog_bin);
        const outcome = commands.createAttached(provider, &service, name, shell, if (size) |s| s.cols else null, if (size) |s| s.rows else null) catch |err| {
            return .{ .err = std.fmt.allocPrint(self.allocator, "created but attach failed: {s}", .{@errorName(err)}) catch unreachable };
        };
        return self.finishCreateOutcome(outcome);
    }

    fn finishCreateOutcome(self: *Executor, outcome: commands.CreateAttachedOutcome) Result {
        var mutable = outcome;
        return switch (mutable) {
            .created => |result| blk: {
                defer result.session.deinit(self.allocator);
                self.enterAttached(result.attached, result.session.id) catch |err| {
                    return .{ .err = std.fmt.allocPrint(self.allocator, "create attach handoff failed: {s}", .{@errorName(err)}) catch unreachable };
                };
                mutable = .session_exists;
                break :blk .{ .attached = self.allocator.dupe(u8, result.session.id) catch unreachable };
            },
            .session_exists => .{ .err = self.allocator.dupe(u8, "session already exists") catch unreachable },
            .invalid_id => |reason| .{ .err = createInvalidIdMessage(self.allocator, reason) catch unreachable },
        };
    }

    fn attachReadyId(self: *Executor, provider: *policy.Provider, id: []const u8, writer_fd: ?std.posix.fd_t, size: ?SessionSize, comptime context: []const u8) Result {
        const attached_id = self.attachCanonicalVerified(provider, id, writer_fd, size) catch |err| {
            return .{ .err = std.fmt.allocPrint(self.allocator, "{s} failed: {s}", .{ context, @errorName(err) }) catch unreachable };
        };
        defer self.allocator.free(attached_id);
        self.interactive_attached = true;
        return .{ .attached = self.allocator.dupe(u8, attached_id) catch unreachable };
    }

    fn attachCanonical(self: *Executor, provider: *policy.Provider, id: []const u8) ![]u8 {
        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin, self.ptylog_bin);
        const result = try service.attach(provider, id);
        defer result.session.deinit(self.allocator);
        try self.enterAttached(result.attached, result.session.id);
        return try self.allocator.dupe(u8, result.session.id);
    }

    fn attachCanonicalVerified(self: *Executor, provider: *policy.Provider, id: []const u8, writer_fd: ?std.posix.fd_t, size: ?SessionSize) ![]u8 {
        if (writer_fd == null or size == null) return try self.attachCanonical(provider, id);

        var service = service_mod.WorkspaceService.init(self.allocator, self.host_bin, self.vpty_bin, self.ptylog_bin);
        var result = try service.attach(provider, id);
        errdefer result.attached.deinit();
        defer result.session.deinit(self.allocator);

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
        if (self.current_session_id) |current| {
            if (std.mem.eql(u8, current, id)) return;
            const next_current = try self.allocator.dupe(u8, id);
            const previous_copy = try self.allocator.dupe(u8, current);
            if (self.previous_session_id) |old_previous| self.allocator.free(old_previous);
            self.previous_session_id = previous_copy;
            self.allocator.free(current);
            self.current_session_id = next_current;
            return;
        }
        self.current_session_id = try self.allocator.dupe(u8, id);
    }
};
