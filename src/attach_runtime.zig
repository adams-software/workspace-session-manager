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

pub const BridgeTransition = union(enum) {
    stay,
    exit,
    replace_attachment: client.SessionAttachment,
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

fn writeOwnerControlError(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, request_id: u32, code: []const u8) !void {
    _ = allocator;
    try attachment.replyOwnerControl(request_id, false, code);
}

fn writeOwnerControlSuccess(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, request_id: u32) !void {
    _ = allocator;
    try attachment.replyOwnerControl(request_id, true, null);
}

pub fn decideOwnerControlReq(allocator: std.mem.Allocator, req: protocol.OwnerControlReq) !OwnerControlDecision {
    if (std.mem.eql(u8, req.action.op, "detach")) {
        return .{ .action = .detach, .should_exit = true };
    }

    if (std.mem.eql(u8, req.action.op, "attach")) {
        const path = req.action.path orelse return error.InvalidArgs;
        if (path.len == 0) return error.InvalidArgs;
        return .{ .action = .{ .attach = try allocator.dupe(u8, path) }, .should_exit = false };
    }

    return error.UnsupportedMethod;
}

pub fn executeOwnerControlDecision(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, req: protocol.OwnerControlReq, decision: OwnerControlDecision) !BridgeTransition {
    defer switch (decision.action) {
        .attach => |path| allocator.free(path),
        else => {},
    };

    switch (decision.action) {
        .none => return .stay,
        .detach => {
            try writeOwnerControlSuccess(allocator, attachment, req.request_id);
            try attachment.detach();
            return .exit;
        },
        .attach => |path| {
            var next_cli = client.SessionClient.init(allocator, path) catch {
                try writeOwnerControlError(allocator, attachment, req.request_id, "invalid_args");
                return .stay;
            };
            errdefer next_cli.deinit();

            const next_att = next_cli.attach(.takeover) catch {
                try writeOwnerControlError(allocator, attachment, req.request_id, "attach_conflict");
                next_cli.deinit();
                return .stay;
            };

            try writeOwnerControlSuccess(allocator, attachment, req.request_id);
            next_cli.deinit();
            return .{ .replace_attachment = next_att };
        },
    }
}

pub fn handleOwnerControlReq(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, req: protocol.OwnerControlReq) !BridgeTransition {
    const decision = decideOwnerControlReq(allocator, req) catch |e| {
        switch (e) {
            error.InvalidArgs => try writeOwnerControlError(allocator, attachment, req.request_id, "invalid_args"),
            error.UnsupportedMethod => try writeOwnerControlError(allocator, attachment, req.request_id, "unsupported_method"),
            else => return e,
        }
        return .stay;
    };
    return try executeOwnerControlDecision(allocator, attachment, req, decision);
}

pub fn runAttachBridge(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, in_fd: c_int, out_fd: c_int) !void {
    var stdin_open = true;
    var in_buf: [4096]u8 = undefined;

    while (true) {
        var pfds = [2]c.struct_pollfd{
            .{ .fd = if (stdin_open) in_fd else -1, .events = if (stdin_open) c.POLLIN else 0, .revents = 0 },
            .{ .fd = attachment.fd, .events = c.POLLIN, .revents = 0 },
        };

        const pr = c.poll(&pfds, 2, -1);
        if (pr < 0) return error.IoError;

        if (stdin_open and (pfds[0].revents & c.POLLIN) != 0) {
            const n = c.read(in_fd, &in_buf, in_buf.len);
            if (n < 0) return error.IoError;
            if (n == 0) {
                stdin_open = false;
            } else {
                try attachment.write(in_buf[0..@intCast(n)]);
            }
        }
        if (stdin_open and (pfds[0].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            stdin_open = false;
        }

        const attachment_idx: usize = 1;
        if ((pfds[attachment_idx].revents & c.POLLIN) != 0) {
            var msg = attachment.readMessage() catch |e| switch (e) {
                error.UnexpectedEof => return,
                else => return e,
            };
            defer msg.deinit(allocator);

            switch (msg) {
                .data => |data_msg| {
                    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(data_msg.bytes_b64);
                    const decoded = try allocator.alloc(u8, decoded_len);
                    defer allocator.free(decoded);
                    try std.base64.standard.Decoder.decode(decoded, data_msg.bytes_b64);
                    _ = c.write(out_fd, decoded.ptr, decoded.len);
                },
                .owner_control_req => |req| {
                    const transition = try handleOwnerControlReq(allocator, attachment, req);
                    switch (transition) {
                        .stay => {},
                        .exit => return,
                        .replace_attachment => |next_attachment| {
                            attachment.close();
                            attachment.* = next_attachment;
                        },
                    }
                },
                else => return error.ProtocolError,
            }
        }

        if ((pfds[attachment_idx].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            return;
        }
    }
}
