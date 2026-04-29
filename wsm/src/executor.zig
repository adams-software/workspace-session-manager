const std = @import("std");
const policy = @import("policy.zig");
const session_primitives = @import("session_primitives.zig");
const session_link_mod = @import("session_link.zig");

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
    link: ?session_link_mod.SessionLink,
    interactive_attached: bool,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) !Executor {
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
            .msr_bin = try allocator.dupe(u8, "zig-out/bin/msr"),
            .link = null,
            .interactive_attached = false,
        };
    }

    pub fn deinit(self: *Executor) void {
        if (self.link) |*link| link.deinit();
        self.allocator.free(self.root);
        self.allocator.free(self.msr_bin);
    }

    pub fn run(self: *Executor, provider: *policy.Provider, action: policy.ResolvedAction) !Result {
        return switch (action) {
            .quit => .detached,
            .detach => self.runDetach() catch |err| .{ .err = try std.fmt.allocPrint(self.allocator, "detach failed: {s}", .{@errorName(err)}) },
            .logs => .{ .info = try self.allocator.dupe(u8, "logs pending transcript/runtime bridge") },
            .nav => |target| blk: {
                defer self.allocator.free(target);
                if (target.len == 0) break :blk .{ .err = try self.allocator.dupe(u8, "no target") };
                self.attachCanonical(provider, target) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "attach failed: {s}", .{@errorName(err)}) };
                };
                self.interactive_attached = true;
                break :blk .{ .attached = try self.allocator.dupe(u8, target) };
            },
            .attach => |target| blk: {
                defer self.allocator.free(target);
                if (target.len == 0) break :blk .{ .err = try self.allocator.dupe(u8, "attach target required") };
                self.attachCanonical(provider, target) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "attach failed: {s}", .{@errorName(err)}) };
                };
                self.interactive_attached = true;
                break :blk .{ .attached = try self.allocator.dupe(u8, target) };
            },
            .create => |name| blk: {
                defer self.allocator.free(name);
                const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
                var paths = session_primitives.createSession(self.allocator, self.msr_bin, provider, .{
                    .id = name,
                    .shell = shell,
                }) catch |err| switch (err) {
                    error.SessionAlreadyExists => break :blk .{ .err = try self.allocator.dupe(u8, "session already exists") },
                    error.Empty, error.StartsWithSlash, error.EndsWithSlash, error.EmptySegment, error.DotSegment, error.InvalidChar => break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "invalid id: {s}", .{@errorName(err)}) },
                    else => return err,
                };
                defer paths.deinit(self.allocator);

                self.attachCanonicalWithRetry(provider, paths.id, 2000) catch |err| {
                    break :blk .{ .err = try std.fmt.allocPrint(self.allocator, "created but attach failed: {s}", .{@errorName(err)}) };
                };
                self.interactive_attached = true;
                break :blk .{ .attached = try self.allocator.dupe(u8, paths.id) };
            },
        };
    }

    pub fn isInteractiveAttached(self: *const Executor) bool {
        return self.interactive_attached;
    }

    pub fn attachedDataFd(self: *Executor) ?std.posix.fd_t {
        if (self.link) |*link| return link.dataPollFd();
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
            const result = try link.pumpDataToOutput(writer_fd);
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
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            self.attachCanonical(provider, id) catch |err| {
                if (std.time.milliTimestamp() >= deadline) return err;
                switch (err) {
                    error.ConnectFailed => {
                        std.Thread.sleep(20 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return err,
                }
            };
            return;
        }
    }

    fn attachCanonical(self: *Executor, provider: *policy.Provider, id: []const u8) !void {
        var paths = try session_primitives.pathsForId(self.allocator, provider, id);
        defer paths.deinit(self.allocator);

        if (self.link) |*link| link.deinit();
        self.link = null;

        var link = session_link_mod.SessionLink.init(self.allocator);
        errdefer link.deinit();
        try link.attach(.{
            .data_path = paths.data_path,
            .control_path = if (pathExists(paths.control_path)) paths.control_path else null,
        });
        self.link = link;
    }
};

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
