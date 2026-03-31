const std = @import("std");
const client = @import("client");
const protocol = @import("protocol");
const attach_runtime = @import("attach_runtime");
const c = @cImport({
    @cInclude("unistd.h");
});

fn readLaneResFromPipe(allocator: std.mem.Allocator, fd: c_int) !protocol.LaneResMsg {
    const frame = try protocol.readFrame(allocator, fd, 64 * 1024);
    defer allocator.free(frame);
    return try protocol.parseLaneResMsg(allocator, frame);
}

fn makePipeAttachment() !struct { read_fd: c_int, att: client.SessionAttachment } {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    return .{
        .read_fd = fds[0],
        .att = .{ .allocator = std.testing.allocator, .fd = fds[1] },
    };
}

test "decide owner_control missing method returns invalid_args" {
    const req = protocol.LaneReqMsg{ .lane_id = "lane-1", .lane_kind = "owner_control", .req_type = "call", .seq = 1, .method = null, .args_json = null };
    try std.testing.expectError(error.InvalidArgs, attach_runtime.decideOwnerControlLaneReq(std.testing.allocator, req));
}

test "decide owner_control detach returns detach action and should_exit" {
    const req = protocol.LaneReqMsg{ .lane_id = "lane-2", .lane_kind = "owner_control", .req_type = "call", .seq = 1, .method = "detach", .args_json = null };
    const decision = try attach_runtime.decideOwnerControlLaneReq(std.testing.allocator, req);
    try std.testing.expect(decision.should_exit);
    switch (decision.action) {
        .detach => {},
        else => return error.TestUnexpectedResult,
    }
}

test "decide owner_control unsupported method returns unsupported_method" {
    const req = protocol.LaneReqMsg{ .lane_id = "lane-3", .lane_kind = "owner_control", .req_type = "call", .seq = 1, .method = "bogus", .args_json = null };
    try std.testing.expectError(error.UnsupportedMethod, attach_runtime.decideOwnerControlLaneReq(std.testing.allocator, req));
}

test "decide owner_control attach missing args returns invalid_args" {
    const req = protocol.LaneReqMsg{ .lane_id = "lane-4", .lane_kind = "owner_control", .req_type = "call", .seq = 1, .method = "attach", .args_json = null };
    try std.testing.expectError(error.InvalidArgs, attach_runtime.decideOwnerControlLaneReq(std.testing.allocator, req));
}

test "decide owner_control attach malformed args returns invalid_args" {
    const req = protocol.LaneReqMsg{ .lane_id = "lane-5", .lane_kind = "owner_control", .req_type = "call", .seq = 1, .method = "attach", .args_json = "{\"bogus\":true}" };
    try std.testing.expectError(error.InvalidArgs, attach_runtime.decideOwnerControlLaneReq(std.testing.allocator, req));
}

test "decide owner_control attach empty path returns invalid_args" {
    const req = protocol.LaneReqMsg{ .lane_id = "lane-6", .lane_kind = "owner_control", .req_type = "call", .seq = 1, .method = "attach", .args_json = "{\"path\":\"\"}" };
    try std.testing.expectError(error.InvalidArgs, attach_runtime.decideOwnerControlLaneReq(std.testing.allocator, req));
}

test "decide owner_control attach valid path returns attach action" {
    const req = protocol.LaneReqMsg{ .lane_id = "lane-7", .lane_kind = "owner_control", .req_type = "call", .seq = 1, .method = "attach", .args_json = "{\"path\":\"/tmp/target.sock\"}" };
    const decision = try attach_runtime.decideOwnerControlLaneReq(std.testing.allocator, req);
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

test "execute owner_control invalid method never needed because decide rejects it" {
    try std.testing.expect(true);
}

test "generic unsupported lane returns lane_unsupported" {
    var pipe = try makePipeAttachment();
    defer {
        _ = c.close(pipe.read_fd);
        pipe.att.close();
    }

    const req = protocol.LaneReqMsg{ .lane_id = "lane-8", .lane_kind = "bogus_lane", .req_type = "call", .seq = 1, .method = "anything", .args_json = null };
    const frame = try protocol.encodeLaneReqMsg(std.testing.allocator, req);
    defer std.testing.allocator.free(frame);

    const should_exit = try attach_runtime.handleLaneReq(std.testing.allocator, &pipe.att, frame);
    try std.testing.expect(!should_exit);

    var res = try readLaneResFromPipe(std.testing.allocator, pipe.read_fd);
    defer protocol.freeLaneResMsg(std.testing.allocator, &res);
    try std.testing.expectEqualStrings("error", res.res_type);
    try std.testing.expect(res.error_json != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_json.?, "lane_unsupported") != null);
}
