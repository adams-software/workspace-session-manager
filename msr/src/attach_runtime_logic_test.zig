const std = @import("std");
const client = @import("client");
const protocol = @import("protocol");
const attach_runtime = @import("attach_runtime");
const c = @cImport({
    @cInclude("unistd.h");
});

fn readOwnerControlResFromPipe(allocator: std.mem.Allocator, fd: c_int) !protocol.OwnerControlRes {
    const frame = try protocol.readFrame(allocator, fd, 64 * 1024);
    defer allocator.free(frame);
    return try protocol.parseOwnerControlRes(allocator, frame);
}

fn makePipeAttachment() !struct { read_fd: c_int, att: client.SessionAttachment } {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    return .{
        .read_fd = fds[0],
        .att = .{ .allocator = std.testing.allocator, .fd = fds[1] },
    };
}

test "decide owner_control attach missing path returns invalid_args" {
    const req = protocol.OwnerControlReq{ .request_id = 1, .action = .{ .op = "attach", .path = null } };
    try std.testing.expectError(error.InvalidArgs, attach_runtime.decideOwnerControlReq(std.testing.allocator, req));
}

test "decide owner_control detach returns detach action and should_exit" {
    const req = protocol.OwnerControlReq{ .request_id = 2, .action = .{ .op = "detach" } };
    const decision = try attach_runtime.decideOwnerControlReq(std.testing.allocator, req);
    try std.testing.expect(decision.should_exit);
    switch (decision.action) {
        .detach => {},
        else => return error.TestUnexpectedResult,
    }
}

test "decide owner_control unsupported method returns unsupported_method" {
    const req = protocol.OwnerControlReq{ .request_id = 3, .action = .{ .op = "bogus" } };
    try std.testing.expectError(error.UnsupportedMethod, attach_runtime.decideOwnerControlReq(std.testing.allocator, req));
}

test "decide owner_control attach empty path returns invalid_args" {
    const req = protocol.OwnerControlReq{ .request_id = 4, .action = .{ .op = "attach", .path = "" } };
    try std.testing.expectError(error.InvalidArgs, attach_runtime.decideOwnerControlReq(std.testing.allocator, req));
}

test "decide owner_control attach valid path returns attach action" {
    const req = protocol.OwnerControlReq{ .request_id = 5, .action = .{ .op = "attach", .path = "/tmp/target.sock" } };
    const decision = try attach_runtime.decideOwnerControlReq(std.testing.allocator, req);
    defer switch (decision.action) {
        .attach => |path| std.testing.allocator.free(path),
        else => {},
    };
    try std.testing.expect(!decision.should_exit);
    switch (decision.action) {
        .attach => |path| try std.testing.expectEqualStrings("/tmp/target.sock", path),
        else => return error.TestUnexpectedResult,
    }
}

test "handle owner_control unsupported method returns unsupported_method error response" {
    var pipe = try makePipeAttachment();
    defer {
        _ = c.close(pipe.read_fd);
        pipe.att.close();
    }

    const req = protocol.OwnerControlReq{ .request_id = 8, .action = .{ .op = "bogus" } };
    const transition = try attach_runtime.handleOwnerControlReq(std.testing.allocator, &pipe.att, req);
    switch (transition) {
        .stay => {},
        else => return error.TestUnexpectedResult,
    }

    var res = try readOwnerControlResFromPipe(std.testing.allocator, pipe.read_fd);
    defer protocol.freeOwnerControlRes(std.testing.allocator, &res);
    try std.testing.expectEqual(@as(u32, 8), res.request_id);
    try std.testing.expect(!res.ok);
    try std.testing.expect(res.err != null);
    try std.testing.expectEqualStrings("unsupported_method", res.err.?.code);
}
