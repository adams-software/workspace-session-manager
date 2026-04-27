const std = @import("std");

pub const AttachSpec = struct {
    data_path: []const u8,
    control_path: ?[]const u8 = null,
};

pub const RouterState = struct {
    control_path: []const u8,
    attached: bool,
    data_path: ?[]const u8,
    target_control_path: ?[]const u8,
};

pub const Error = error{
    AlreadyAttached,
    NotAttached,
    OutOfMemory,
};

pub const RouterRuntime = struct {
    allocator: std.mem.Allocator,
    control_path: []u8,
    attached_data_path: ?[]u8,
    attached_control_path: ?[]u8,
    should_exit: bool,

    pub fn init(allocator: std.mem.Allocator, control_path: []const u8) !RouterRuntime {
        return .{
            .allocator = allocator,
            .control_path = try allocator.dupe(u8, control_path),
            .attached_data_path = null,
            .attached_control_path = null,
            .should_exit = false,
        };
    }

    pub fn deinit(self: *RouterRuntime) void {
        self.allocator.free(self.control_path);
        if (self.attached_data_path) |path| self.allocator.free(path);
        if (self.attached_control_path) |path| self.allocator.free(path);
    }

    pub fn state(self: *const RouterRuntime) RouterState {
        return .{
            .control_path = self.control_path,
            .attached = self.attached_data_path != null,
            .data_path = self.attached_data_path,
            .target_control_path = self.attached_control_path,
        };
    }

    pub fn attach(self: *RouterRuntime, spec: AttachSpec) Error!void {
        if (self.attached_data_path != null) return Error.AlreadyAttached;
        self.attached_data_path = try self.allocator.dupe(u8, spec.data_path);
        errdefer {
            self.allocator.free(self.attached_data_path.?);
            self.attached_data_path = null;
        }
        if (spec.control_path) |control_path| {
            self.attached_control_path = try self.allocator.dupe(u8, control_path);
        }
    }

    pub fn detach(self: *RouterRuntime) Error!void {
        if (self.attached_data_path == null) return Error.NotAttached;
        self.allocator.free(self.attached_data_path.?);
        self.attached_data_path = null;
        self.allocator.free(self.attached_control_path.?);
        self.attached_control_path = null;
    }
};

test "router_runtime attach then detach" {
    var runtime = try RouterRuntime.init(std.testing.allocator, "/tmp/router.sock");
    defer runtime.deinit();
    try std.testing.expectEqual(false, runtime.state().attached);

    try runtime.attach(.{ .data_path = "/tmp/msr.data", .control_path = "/tmp/msr.control" });
    try std.testing.expectEqual(true, runtime.state().attached);
    try std.testing.expectEqualStrings("/tmp/msr.data", runtime.state().data_path.?);
    try std.testing.expectEqualStrings("/tmp/msr.control", runtime.state().target_control_path.?);

    try runtime.detach();
    try std.testing.expectEqual(false, runtime.state().attached);
    try std.testing.expect(runtime.state().data_path == null);
    try std.testing.expect(runtime.state().target_control_path == null);
}

test "router_runtime rejects attach while already attached" {
    var runtime = try RouterRuntime.init(std.testing.allocator, "/tmp/router.sock");
    defer runtime.deinit();
    try runtime.attach(.{ .data_path = "/tmp/a", .control_path = "/tmp/b" });
    try std.testing.expectError(Error.AlreadyAttached, runtime.attach(.{ .data_path = "/tmp/c", .control_path = "/tmp/d" }));
}

test "router_runtime rejects detach while unattached" {
    var runtime = try RouterRuntime.init(std.testing.allocator, "/tmp/router.sock");
    defer runtime.deinit();
    try std.testing.expectError(Error.NotAttached, runtime.detach());
}
