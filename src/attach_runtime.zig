const std = @import("std");
const client = @import("client");
const protocol = @import("protocol");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

pub const OwnerControlAction = union(enum) {
    none,
    detach,
    attach: []const u8,
};

pub const OwnerControlDecision = struct {
    action: OwnerControlAction,
    should_exit: bool,
};

fn decodeDataFrame(allocator: std.mem.Allocator, frame: []const u8) ![]u8 {
    var msg = try protocol.parseDataMsg(allocator, frame);
    defer protocol.freeDataMsg(allocator, &msg);
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(msg.bytes_b64);
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, msg.bytes_b64);
    return decoded;
}

fn writeLaneError(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, lane_id: []const u8, seq: u32, code: []const u8) !void {
    const err_json = try std.fmt.allocPrint(allocator, "{{\"code\":\"{s}\"}}", .{code});
    defer allocator.free(err_json);
    const res_bytes = try protocol.encodeLaneResMsg(allocator, .{
        .lane_id = lane_id,
        .res_type = "error",
        .seq = seq,
        .error_json = err_json,
    });
    defer allocator.free(res_bytes);
    try protocol.writeFrame(attachment.fd, res_bytes);
}

fn writeLaneReturn(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, lane_id: []const u8, seq: u32) !void {
    const res_bytes = try protocol.encodeLaneResMsg(allocator, .{
        .lane_id = lane_id,
        .res_type = "return",
        .seq = seq,
        .value_json = "{}",
    });
    defer allocator.free(res_bytes);
    try protocol.writeFrame(attachment.fd, res_bytes);
}

pub fn decideOwnerControlLaneReq(allocator: std.mem.Allocator, lane_req: protocol.LaneReqMsg) !OwnerControlDecision {
    if (lane_req.method == null) return error.InvalidArgs;

    if (std.mem.eql(u8, lane_req.method.?, "detach")) {
        return .{ .action = .detach, .should_exit = true };
    }

    if (std.mem.eql(u8, lane_req.method.?, "attach")) {
        const args_json = lane_req.args_json orelse return error.InvalidArgs;
        const AttachArgs = struct { path: []const u8 };
        var parsed_args = std.json.parseFromSlice(AttachArgs, allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
            return error.InvalidArgs;
        };
        defer parsed_args.deinit();
        if (parsed_args.value.path.len == 0) return error.InvalidArgs;
        const path = try allocator.dupe(u8, parsed_args.value.path);
        return .{ .action = .{ .attach = path }, .should_exit = false };
    }

    return error.UnsupportedMethod;
}

pub fn executeOwnerControlDecision(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, lane_req: protocol.LaneReqMsg, decision: OwnerControlDecision) !bool {
    defer switch (decision.action) {
        .attach => |path| allocator.free(path),
        else => {},
    };

    switch (decision.action) {
        .none => return false,
        .detach => {
            try writeLaneReturn(allocator, attachment, lane_req.lane_id, lane_req.seq);
            try attachment.detach();
            return true;
        },
        .attach => |path| {
            std.debug.print("[lane] owner handling attach lane id={s}\n", .{lane_req.lane_id});
            std.debug.print("[lane] owner parsed attach target path={s}\n", .{path});

            var next_cli = client.SessionClient.init(allocator, path) catch {
                try writeLaneError(allocator, attachment, lane_req.lane_id, lane_req.seq, "invalid_args");
                return false;
            };
            errdefer next_cli.deinit();

            const next_att = next_cli.attach(.takeover) catch {
                try writeLaneError(allocator, attachment, lane_req.lane_id, lane_req.seq, "attach_conflict");
                next_cli.deinit();
                return false;
            };

            std.debug.print("[lane] owner attached to target, sending lane return\n", .{});
            try writeLaneReturn(allocator, attachment, lane_req.lane_id, lane_req.seq);
            std.debug.print("[lane] owner swapping attachment to target\n", .{});
            attachment.close();
            attachment.* = next_att;
            next_cli.deinit();
            return false;
        },
    }
}

pub fn handleOwnerControlLaneReq(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, lane_req: protocol.LaneReqMsg) !bool {
    const decision = decideOwnerControlLaneReq(allocator, lane_req) catch |e| {
        switch (e) {
            error.InvalidArgs => try writeLaneError(allocator, attachment, lane_req.lane_id, lane_req.seq, "invalid_args"),
            error.UnsupportedMethod => try writeLaneError(allocator, attachment, lane_req.lane_id, lane_req.seq, "unsupported_method"),
            else => return e,
        }
        return false;
    };
    return try executeOwnerControlDecision(allocator, attachment, lane_req, decision);
}

pub fn handleLaneReq(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, frame: []const u8) !bool {
    var lane_req = try protocol.parseLaneReqMsg(allocator, frame);
    defer protocol.freeLaneReqMsg(allocator, &lane_req);

    if (std.mem.eql(u8, lane_req.lane_kind, "owner_control")) {
        return try handleOwnerControlLaneReq(allocator, attachment, lane_req);
    }

    try writeLaneError(allocator, attachment, lane_req.lane_id, lane_req.seq, "lane_unsupported");
    return false;
}

pub fn runAttachBridge(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, in_fd: c_int, out_fd: c_int) !void {
    var stdin_open = true;
    var pfd = c.struct_pollfd{ .fd = in_fd, .events = c.POLLIN, .revents = 0 };
    var in_buf: [4096]u8 = undefined;

    while (true) {
        if (stdin_open) {
            const pr = c.poll(&pfd, 1, 10);
            if (pr < 0) return error.IoError;
            if (pr > 0 and (pfd.revents & c.POLLIN) != 0) {
                const n = c.read(in_fd, &in_buf, in_buf.len);
                if (n < 0) return error.IoError;
                if (n == 0) {
                    stdin_open = false;
                } else {
                    try attachment.write(in_buf[0..@intCast(n)]);
                }
            }
            if ((pfd.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) stdin_open = false;
        }

        const frame = attachment.readFrameOwned() catch |e| switch (e) {
            error.UnexpectedEof => return,
            else => return e,
        };
        defer allocator.free(frame);

        const EnvType = struct { type: []const u8 };
        var parsed = try std.json.parseFromSlice(EnvType, allocator, frame, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (std.mem.eql(u8, parsed.value.type, "data")) {
            const decoded = try decodeDataFrame(allocator, frame);
            defer allocator.free(decoded);
            _ = c.write(out_fd, decoded.ptr, decoded.len);
            continue;
        }

        if (std.mem.eql(u8, parsed.value.type, "lane_req")) {
            const should_exit = try handleLaneReq(allocator, attachment, frame);
            if (should_exit) return;
            continue;
        }

        return error.ProtocolError;
    }
}
