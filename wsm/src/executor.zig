const std = @import("std");
const policy = @import("policy.zig");
const service_mod = @import("service.zig");

pub const Result = union(enum) {
    info: []const u8,
    err: []const u8,
    attached: []const u8,
    detached,
};

pub const ResizeResult = enum {
    ignored,
    forwarded,
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    msr_bin: []const u8,
    vpty_bin: []const u8,
    link: ?service_mod.AttachedSession,
    interactive_attached: bool,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) !Executor {
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
            .msr_bin = try allocator.dupe(u8, "zig-out/bin/msr"),
            .vpty_bin = try allocator.dupe(u8, "zig-out/bin/vpty"),
            .link = null,
            .interactive_attached = false,
        };
    }

    pub fn deinit(self: *Executor) void {
        if (self.link) |*link| link.deinit();
        self.allocator.free(self.root);
        self.allocator.free(self.msr_bin);
        self.allocator.free(self.vpty_bin);
    }

    pub fn run(self: *Executor, provider: *policy.Provider, action: policy.ResolvedAction) !Result {
        return switch (action) {
            .quit => .detached,
            .detach => self.runDetach() catch |err| .{ .err = try std.fmt.allocPrint(self.allocator, "detach failed: {s}", .{@errorName(err)}) },
            .logs => blk: {
                var service = service_mod.WorkspaceService.init(self.allocator, self.msr_bin, self.vpty_bin);
                const current = if (provider.current_session.len == 0) null else provider.current_session;
                if (current == null) break :blk .{ .err = try self.allocator.dupe(u8, "no current session") };
                const info = service.sessionInfo(provider, current.?) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "logs failed: {s}", .{@errorName(err)}) };
                };
                defer info.deinit(self.allocator);
                break :blk .{ .info = try std.fmt.allocPrint(self.allocator, "transcript: {s}", .{info.transcript_path}) };
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
                var service = service_mod.WorkspaceService.init(self.allocator, self.msr_bin, self.vpty_bin);
                const result = service.createAndAttach(provider, name, shell) catch |err| switch (err) {
                    error.SessionAlreadyExists => break :blk .{ .err = try self.allocator.dupe(u8, "session already exists") },
                    error.Empty, error.StartsWithSlash, error.EndsWithSlash, error.EmptySegment, error.DotSegment, error.InvalidChar => break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "invalid id: {s}", .{@errorName(err)}) },
                    else => break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "created but attach failed: {s}", .{@errorName(err)}) },
                };
                if (self.link) |*link| link.deinit();
                self.link = result.attached;
                self.interactive_attached = true;
                defer result.session.deinit(self.allocator);
                break :blk .{ .attached = try self.allocator.dupe(u8, result.session.id) };
            },
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

    pub fn pumpAttachedOutput(self: *Executor, writer_fd: std.posix.fd_t) !bool {
        if (self.link) |*link| {
            const result = try link.pumpOutput(writer_fd);
            if (result.stream_lost) {
                self.interactive_attached = false;
                link.detach();
                return false;
            }
            return result.did_work;
        }
        return false;
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
        var service = service_mod.WorkspaceService.init(self.allocator, self.msr_bin, self.vpty_bin);
        const attached = try service.attachWithRetry(provider, id, timeout_ms);
        if (self.link) |*link| link.deinit();
        self.link = attached;
    }

    fn attachCanonical(self: *Executor, provider: *policy.Provider, id: []const u8) ![]u8 {
        var service = service_mod.WorkspaceService.init(self.allocator, self.msr_bin, self.vpty_bin);
        const result = try service.attach(provider, id);
        defer result.session.deinit(self.allocator);
        if (self.link) |*link| link.deinit();
        self.link = result.attached;
        return try self.allocator.dupe(u8, result.session.id);
    }
};
