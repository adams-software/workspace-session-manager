const std = @import("std");
const client2 = @import("session_client");
const core = @import("session_core");
const wire = @import("session_wire");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("termios.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
});

pub const Error = client2.Error || error{
    IoError,
    UnsupportedMessage,
};

pub const BridgeExit = enum {
    clean,
    remote_closed,
    remote_error,
    stdout_unavailable,
};

const BridgeTransition = union(enum) {
    stay,
    exit,
    replace_attachment: client2.SessionAttachment,
};

var winch_changed: bool = false;

fn handleSigwinch(_: c_int) callconv(.c) void {
    winch_changed = true;
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            const e = std.c.errno(-1);
            if (e == .INTR or e == .AGAIN) continue;
            return error.IoError;
        }
        if (n == 0) return error.IoError;
        off += @intCast(n);
    }
}

fn sendResizeIfAvailable(att: *client2.SessionAttachment, in_fd: c_int) void {
    if (c.isatty(in_fd) != 1) return;

    var ws: c.struct_winsize = undefined;
    if (c.ioctl(in_fd, c.TIOCGWINSZ, &ws) != 0) return;
    if (ws.ws_col == 0 or ws.ws_row == 0) return;

    att.sendOwnerResize(@intCast(ws.ws_col), @intCast(ws.ws_row)) catch {};
}

fn mapAttachRequestError(err: anyerror) core.ErrorCode {
    return switch (err) {
        client2.Error.AttachConflict,
        client2.Error.AttachRejected,
        => .attach_conflict,

        client2.Error.InvalidArgs,
        client2.Error.ConnectFailed,
        client2.Error.PathTooLong,
        client2.Error.ProtocolError,
        client2.Error.IoError,
        client2.Error.Timeout,
        client2.Error.UnexpectedEof,
        => .invalid_args,

        else => .invalid_args,
    };
}

fn executeForwardRequest(
    allocator: std.mem.Allocator,
    current_att: *client2.SessionAttachment,
    req: wire.ForwardRequest,
) !BridgeTransition {
    switch (req.action) {
        .detach => {
            try current_att.replyOwnerRequest(req.request_id, true, null);
            return .exit;
        },
        .attach => |path| {
            var next_cli = client2.SessionClient.init(allocator, path) catch {
                try current_att.replyOwnerRequest(req.request_id, false, .invalid_args);
                return .stay;
            };
            defer next_cli.deinit();

            const next_att = next_cli.attach(.takeover) catch |e| {
                try current_att.replyOwnerRequest(req.request_id, false, mapAttachRequestError(e));
                return .stay;
            };

            try current_att.replyOwnerRequest(req.request_id, true, null);
            return .{ .replace_attachment = next_att };
        },
    }
}

fn handleAttachmentReadable(
    allocator: std.mem.Allocator,
    att: *client2.SessionAttachment,
    out_fd: c_int,
) !BridgeTransition {
    var msg = att.readMessage() catch |e| switch (e) {
        client2.Error.UnexpectedEof => return error.UnexpectedEof,
        else => return e,
    };
    defer msg.deinit(allocator);

    switch (msg) {
        .stdout_bytes => |bytes| {
            writeAll(out_fd, bytes) catch return error.StdoutUnavailable;
            return .stay;
        },
        .owner_req => |req| {
            return try executeForwardRequest(allocator, att, req);
        },
        else => return error.UnsupportedMessage,
    }
}

pub fn runAttachBridge(
    allocator: std.mem.Allocator,
    attachment: *client2.SessionAttachment,
    in_fd: c_int,
    out_fd: c_int,
) !BridgeExit {
    var stdin_open = true;
    var in_buf: [32768]u8 = undefined;

    const old_winch = c.signal(c.SIGWINCH, handleSigwinch);
    defer _ = c.signal(c.SIGWINCH, old_winch);
    winch_changed = false;

    var raw_enabled = false;
    var saved_termios: c.struct_termios = undefined;
    if (c.isatty(in_fd) == 1) {
        if (c.tcgetattr(in_fd, &saved_termios) == 0) {
            var raw = saved_termios;
            c.cfmakeraw(&raw);
            if (c.tcsetattr(in_fd, c.TCSANOW, &raw) == 0) {
                raw_enabled = true;
            }
        }
    }
    defer if (raw_enabled) {
        _ = c.tcsetattr(in_fd, c.TCSANOW, &saved_termios);
    };

    try attachment.sendOwnerReady();
    sendResizeIfAvailable(attachment, in_fd);

    while (true) {
        var pfds = [2]c.struct_pollfd{
            .{
                .fd = if (stdin_open) in_fd else -1,
                .events = if (stdin_open) c.POLLIN else 0,
                .revents = 0,
            },
            .{
                .fd = attachment.fd,
                .events = c.POLLIN,
                .revents = 0,
            },
        };

        while (true) {
            const pr = c.poll(&pfds, 2, -1);
            if (pr >= 0) break;
            const e = std.c.errno(-1);
            if (e == .INTR) continue;
            return error.IoError;
        }

        if (stdin_open and (pfds[0].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            stdin_open = false;
        }

        if (stdin_open and (pfds[0].revents & c.POLLIN) != 0) {
            const n = c.read(in_fd, &in_buf, in_buf.len);
            if (n < 0) {
                const e = std.c.errno(-1);
                if (e == .INTR or e == .AGAIN) {} else return error.IoError;
            } else if (n == 0) {
                stdin_open = false;
            } else {
                try attachment.write(in_buf[0..@intCast(n)]);
            }
        }

        if ((pfds[1].revents & c.POLLIN) != 0) {
            const transition = handleAttachmentReadable(allocator, attachment, out_fd) catch |e| switch (e) {
                error.UnexpectedEof => return .remote_closed,
                error.StdoutUnavailable => return .stdout_unavailable,
                else => return .remote_error,
            };

            switch (transition) {
                .stay => {},
                .exit => return .clean,
                .replace_attachment => |next_attachment| {
                    attachment.close();
                    attachment.* = next_attachment;
                    try attachment.sendOwnerReady();
                    sendResizeIfAvailable(attachment, in_fd);
                },
            }
        }

        if ((pfds[1].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            if ((pfds[1].revents & c.POLLHUP) != 0 and (pfds[1].revents & (c.POLLERR | c.POLLNVAL)) == 0) {
                return .remote_closed;
            }
            return .remote_error;
        }

        if (winch_changed) {
            winch_changed = false;
            sendResizeIfAvailable(attachment, in_fd);
        }
    }
}

test "forward detach replies success and exits" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    var att = client2.SessionAttachment{
        .allocator = std.testing.allocator,
        .fd = fds[1],
    };

    const transition = try executeForwardRequest(
        std.testing.allocator,
        &att,
        .{
            .request_id = 7,
            .action = .detach,
        },
    );

    try std.testing.expect(transition == .exit);

    var msg = try wire.readMessage(std.testing.allocator, fds[0], 1024);
    defer msg.deinit(std.testing.allocator);

    switch (msg) {
        .owner_res => |res| {
            try std.testing.expectEqual(@as(u32, 7), res.request_id);
            try std.testing.expect(res.ok);
            try std.testing.expect(res.code == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "stdout message writes raw bytes to local output" {
    var att_pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&att_pipe));
    defer {
        _ = c.close(att_pipe[0]);
        _ = c.close(att_pipe[1]);
    }

    var out_pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&out_pipe));
    defer {
        _ = c.close(out_pipe[0]);
        _ = c.close(out_pipe[1]);
    }

    try wire.writeStdoutBytes(att_pipe[1], "hello");

    var att = client2.SessionAttachment{
        .allocator = std.testing.allocator,
        .fd = att_pipe[0],
    };

    const transition = try handleAttachmentReadable(std.testing.allocator, &att, out_pipe[1]);
    try std.testing.expect(transition == .stay);

    var buf: [16]u8 = undefined;
    const n = c.read(out_pipe[0], &buf, buf.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings("hello", buf[0..@intCast(n)]);
}
