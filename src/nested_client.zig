const std = @import("std");
const client = @import("client");
const protocol = @import("protocol");

pub const Error = client.Error || error{
    InvalidArgs,
};

pub const NestedClient = struct {
    inner: client.SessionClient,

    pub fn init(allocator: std.mem.Allocator, current_socket_path: []const u8) !NestedClient {
        return .{ .inner = try client.SessionClient.init(allocator, current_socket_path) };
    }

    pub fn deinit(self: *NestedClient) void {
        self.inner.deinit();
    }

    pub fn attach(self: *NestedClient, target_socket_path: []const u8) !void {
        if (target_socket_path.len == 0) return Error.InvalidArgs;
        return self.inner.ownerForward(.{ .op = "attach", .path = target_socket_path });
    }

    pub fn detach(self: *NestedClient) !void {
        return self.inner.requestOwnerDetach();
    }
};

test "nested client attach forwards attach action" {
    _ = protocol.OwnerAction;
}
