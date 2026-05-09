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

pub const Result = union(enum) {
    info: []const u8,
    err: []const u8,
    attached: []const u8,
    reattached: []const u8,
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
    msr_bin: []const u8,
    vpty_bin: []const u8,
    alt_bin: []const u8,
    logs_viewer_bin: []const u8,
    link: ?service_mod.AttachedSession,
    interactive_attached: bool,
    current_session_id: ?[]u8,
    return_session_id: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) !Executor {
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
            .msr_bin = try allocator.dupe(u8, "zig-out/bin/msr"),
            .vpty_bin = try allocator.dupe(u8, "zig-out/bin/vpty"),
            .alt_bin = try allocator.dupe(u8, "zig-out/bin/alt"),
            .logs_viewer_bin = try allocator.dupe(u8, "wsm/scripts/wsm_logs_viewer"),
            .link = null,
            .interactive_attached = false,
            .current_session_id = null,
            .return_session_id = null,
        };
    }

    pub fn deinit(self: *Executor) void {
        if (self.link) |*link| link.deinit();
        self.allocator.free(self.root);
        self.allocator.free(self.msr_bin);
        self.allocator.free(self.vpty_bin);
        self.allocator.free(self.alt_bin);
        self.allocator.free(self.logs_viewer_bin);
        if (self.current_session_id) |id| self.allocator.free(id);
        if (self.return_session_id) |id| self.allocator.free(id);
    }

    pub fn run(self: *Executor, provider: *policy.Provider, action: policy.ResolvedAction) !Result {
        return switch (action) {
            .quit => .detached,
            .detach => self.runDetach() catch |err| .{ .err = try std.fmt.allocPrint(self.allocator, "detach failed: {s}", .{@errorName(err)}) },
            .logs => blk: {
                const base_id = self.current_session_id orelse break :blk .{ .err = try self.allocator.dupe(u8, "no current session") };
                if (policy.isScrollSession(base_id)) break :blk .{ .err = try self.allocator.dupe(u8, "already in logs") };
                const base_id_copy = try self.allocator.dupe(u8, base_id);
                defer self.allocator.free(base_id_copy);
                var service = service_mod.WorkspaceService.init(self.allocator, self.msr_bin, self.vpty_bin, self.alt_bin, self.logs_viewer_bin);
                const scroll_id = try policy.scrollSessionId(self.allocator, base_id_copy);
                defer self.allocator.free(scroll_id);
                const base_paths = try provider.socketPathForId(base_id_copy);
                defer self.allocator.free(base_paths);
                const transcript = try std.fmt.allocPrint(self.allocator, "{s}.typescript", .{base_paths[0 .. base_paths.len - 4]});
                defer self.allocator.free(transcript);
                const argv = [_][]const u8{ self.logs_viewer_bin, transcript };
                const result = service.createCommandAndAttach(provider, scroll_id, &argv, null, null) catch |err| switch (err) {
                    error.SessionAlreadyExists => {
                        const attached_id = try self.attachCanonical(provider, scroll_id);
                        try self.setReturnSession(base_id_copy);
                        break :blk .{ .attached = attached_id };
                    },
                    else => break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "logs failed: {s}", .{@errorName(err)}) },
                };
                try self.enterAttached(result.attached, result.session.id);
                try self.setReturnSession(base_id_copy);
                defer result.session.deinit(self.allocator);
                break :blk .{ .attached = try self.allocator.dupe(u8, result.session.id) };
            },
            .nav => |target| blk: {
                defer self.allocator.free(target);
                if (target.len == 0) break :blk .{ .err = try self.allocator.dupe(u8, "no target") };
                const attached_id = self.attachCanonical(provider, target) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "attach failed: {s}", .{@errorName(err)}) };
                };
                defer self.allocator.free(attached_id);
                self.interactive_attached = true;
                break :blk .{ .attached = try self.allocator.dupe(u8, attached_id) };
            },
            .attach => |target| blk: {
                defer self.allocator.free(target);
                if (target.len == 0) break :blk .{ .err = try self.allocator.dupe(u8, "attach target required") };
                const attached_id = self.attachCanonical(provider, target) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "attach failed: {s}", .{@errorName(err)}) };
                };
                defer self.allocator.free(attached_id);
                self.interactive_attached = true;
                break :blk .{ .attached = try self.allocator.dupe(u8, attached_id) };
            },
            .create => |name| blk: {
                defer self.allocator.free(name);
                const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
                var service = service_mod.WorkspaceService.init(self.allocator, self.msr_bin, self.vpty_bin, self.alt_bin, self.logs_viewer_bin);
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
        const base_id = self.current_session_id orelse return .{ .err = try self.allocator.dupe(u8, "no current session") };
        if (policy.isScrollSession(base_id)) return .{ .err = try self.allocator.dupe(u8, "already in logs") };
        const base_id_copy = try self.allocator.dupe(u8, base_id);
        defer self.allocator.free(base_id_copy);
        var service = service_mod.WorkspaceService.init(self.allocator, self.msr_bin, self.vpty_bin, self.alt_bin, self.logs_viewer_bin);
        const scroll_id = try policy.scrollSessionId(self.allocator, base_id_copy);
        defer self.allocator.free(scroll_id);
        const base_paths = try provider.socketPathForId(base_id_copy);
        defer self.allocator.free(base_paths);
        const transcript = try std.fmt.allocPrint(self.allocator, "{s}.typescript", .{base_paths[0 .. base_paths.len - 4]});
        defer self.allocator.free(transcript);
        const argv = [_][]const u8{ self.logs_viewer_bin, transcript };
        const result = service.createCommandAndAttach(provider, scroll_id, &argv, size.cols, size.rows) catch |err| switch (err) {
            error.SessionAlreadyExists => {
                const attached_id = try self.attachCanonical(provider, scroll_id);
                try self.setReturnSession(base_id_copy);
                return .{ .attached = attached_id };
            },
            else => return .{ .err = try std.fmt.allocPrint(self.allocator, "logs failed: {s}", .{@errorName(err)}) },
        };
        try self.enterAttached(result.attached, result.session.id);
        try self.setReturnSession(base_id_copy);
        defer result.session.deinit(self.allocator);
        return .{ .attached = try self.allocator.dupe(u8, result.session.id) };
    }

    pub fn createAndAttachSized(self: *Executor, provider: *policy.Provider, name: []const u8, shell: []const u8, size: SessionSize) !Result {
        var service = service_mod.WorkspaceService.init(self.allocator, self.msr_bin, self.vpty_bin, self.alt_bin, self.logs_viewer_bin);
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
        if (self.link) |*link| {
            const result = try link.pumpOutput(writer_fd);
            debugLog("executor pump stream_lost={} did_work={}\n", .{ result.stream_lost, result.did_work });
            if (result.stream_lost) {
                if (self.current_session_id) |current_id| {
                    if (policy.isScrollSession(current_id) and self.return_session_id != null) {
                        const return_id = self.return_session_id.?;
                        const reattached_id = self.attachCanonical(provider, return_id) catch |err| {
                            self.interactive_attached = false;
                            link.detach();
                            return .{ .err = try std.fmt.allocPrint(self.allocator, "return attach failed: {s}", .{@errorName(err)}) };
                        };
                        try provider.setCurrentSession(return_id);
                        return .{ .reattached = reattached_id };
                    }
                }
                self.interactive_attached = false;
                link.detach();
                return .detached;
            }
            return if (result.did_work) .{ .info = try self.allocator.dupe(u8, "") } else .detached;
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
        var service = service_mod.WorkspaceService.init(self.allocator, self.msr_bin, self.vpty_bin, self.alt_bin, self.logs_viewer_bin);
        const attached = try service.attachWithRetry(provider, id, timeout_ms);
        try self.enterAttached(attached, id);
    }

    fn attachCanonical(self: *Executor, provider: *policy.Provider, id: []const u8) ![]u8 {
        var service = service_mod.WorkspaceService.init(self.allocator, self.msr_bin, self.vpty_bin, self.alt_bin, self.logs_viewer_bin);
        const result = try service.attach(provider, id);
        defer result.session.deinit(self.allocator);
        try self.enterAttached(result.attached, result.session.id);
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

    fn setReturnSession(self: *Executor, id: []const u8) !void {
        if (self.return_session_id) |current| self.allocator.free(current);
        self.return_session_id = try self.allocator.dupe(u8, id);
    }
};
