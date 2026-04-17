const std = @import("std");
const client = @import("client");
const core = @import("session_core");
const wire = @import("session_wire");

const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const streaming = @import("session_stream_transport");
const WakePipe = @import("wake_pipe").WakePipe;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("termios.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
});

pub const Error = client.Error || streaming.Error || fd_stream.Error || error{
    IoError,
    UnsupportedMessage,
    StdoutUnavailable,
};

pub const BridgeExit = enum {
    clean,
    remote_closed,
    remote_error,
    stdout_unavailable,
};

const PendingTransition = union(enum) {
    exit,
    replace_attachment: client.SessionAttachment,
};

var winch_changed: bool = false;
var wake_pipe: WakePipe = .{};

fn handleSigwinch(_: c_int) callconv(.c) void {
    winch_changed = true;
    wake_pipe.notify();
}

fn mapAttachRequestError(err: anyerror) core.ErrorCode {
    return switch (err) {
        client.Error.AttachConflict,
        client.Error.AttachRejected,
        => .attach_conflict,

        client.Error.InvalidArgs,
        client.Error.ConnectFailed,
        client.Error.PathTooLong,
        client.Error.ProtocolError,
        client.Error.IoError,
        client.Error.Timeout,
        client.Error.UnexpectedEof,
        => .invalid_args,

        else => .invalid_args,
    };
}

fn queueOwnerReady(att_transport: *streaming.FramedTransport) !void {
    try att_transport.queueMessage(.owner_ready);
}

fn queueResizeIfAvailable(att_transport: *streaming.FramedTransport, in_fd: c_int) !void {
    if (c.isatty(in_fd) != 1) return;

    var ws: c.struct_winsize = undefined;
    if (c.ioctl(in_fd, c.TIOCGWINSZ, &ws) != 0) return;
    if (ws.ws_col == 0 or ws.ws_row == 0) return;

    try att_transport.queueMessage(.{
        .owner_resize = .{
            .cols = @intCast(ws.ws_col),
            .rows = @intCast(ws.ws_row),
        },
    });
}

fn queueOwnerResponse(
    att_transport: *streaming.FramedTransport,
    request_id: u32,
    ok: bool,
    code: ?core.ErrorCode,
) !void {
    try att_transport.queueMessage(.{
        .owner_res = .{
            .request_id = request_id,
            .ok = ok,
            .code = if (ok) null else (code orelse .invalid_args),
        },
    });
}

fn executeForwardRequest(
    allocator: std.mem.Allocator,
    att_transport: *streaming.FramedTransport,
    req: wire.ForwardRequest,
) !?PendingTransition {
    switch (req.action) {
        .detach => {
            try queueOwnerResponse(att_transport, req.request_id, true, null);
            return .exit;
        },
        .attach => |path| {
            var next_cli = client.SessionClient.init(allocator, path) catch {
                try queueOwnerResponse(att_transport, req.request_id, false, .invalid_args);
                return null;
            };
            defer next_cli.deinit();

            const next_att = next_cli.attach(.takeover) catch |e| {
                try queueOwnerResponse(att_transport, req.request_id, false, mapAttachRequestError(e));
                return null;
            };

            try queueOwnerResponse(att_transport, req.request_id, true, null);
            return .{ .replace_attachment = next_att };
        },
    }
}

fn queueRawInputToAttachment(
    allocator: std.mem.Allocator,
    stdin_rx: *ByteQueue,
    att_transport: *streaming.FramedTransport,
    byte_budget: usize,
) !void {
    var remaining = byte_budget;

    while (remaining > 0 and !stdin_rx.isEmpty()) {
        const readable = stdin_rx.readableSlice();
        const n = @min(readable.len, @min(remaining, 16 * 1024));

        const owned = try allocator.dupe(u8, readable[0..n]);
        defer allocator.free(owned);

        try att_transport.queueMessage(.{
            .stdin_bytes = owned,
        });

        stdin_rx.discard(n);
        remaining -= n;
    }
}

fn pumpAttachmentMessages(
    allocator: std.mem.Allocator,
    att_transport: *streaming.FramedTransport,
    stdout_tx: *ByteQueue,
    pending_transition: *?PendingTransition,
) !void {
    while (try att_transport.nextMessage()) |msg| {
        defer {
            var owned = msg;
            owned.deinit(allocator);
        }

        switch (msg) {
            .stdout_bytes => |bytes| {
                try stdout_tx.append(allocator, bytes);
            },
            .owner_req => |req| {
                if (pending_transition.* != null) return error.UnsupportedMessage;
                pending_transition.* = try executeForwardRequest(allocator, att_transport, req);
            },
            .control_res => {
                // Benign on the attachment stream during initial owner_ready/resize
                // handshake and other transitional moments. The bridge has no action
                // to take here, so just ignore it.
            },
            else => return error.UnsupportedMessage,
        }
    }
}

fn applyPendingTransition(
    allocator: std.mem.Allocator,
    attachment: *client.SessionAttachment,
    att_transport: *streaming.FramedTransport,
    pending_transition: *?PendingTransition,
    in_fd: c_int,
) !?BridgeExit {
    if (pending_transition.* == null) return null;
    if (!att_transport.tx.isEmpty()) return null;

    const transition = pending_transition.*.?;
    pending_transition.* = null;

    switch (transition) {
        .exit => {
            return .clean;
        },
        .replace_attachment => |next_attachment| {
            att_transport.deinit();
            attachment.close();
            attachment.* = next_attachment;

            att_transport.* = try streaming.FramedTransport.init(
                allocator,
                attachment.fd,
                client.DEFAULT_STREAM_FRAME_MAX,
            );

            try queueOwnerReady(att_transport);
            try queueResizeIfAvailable(att_transport, in_fd);
            return null;
        },
    }
}

pub fn runAttachBridge(
    allocator: std.mem.Allocator,
    attachment: *client.SessionAttachment,
    in_fd: c_int,
    out_fd: c_int,
) !BridgeExit {
    var stdin_open = true;
    var stdin_rx = ByteQueue.init();
    defer stdin_rx.deinit(allocator);

    var stdout_tx = ByteQueue.init();
    defer stdout_tx.deinit(allocator);

    var att_transport = try streaming.FramedTransport.init(
        allocator,
        attachment.fd,
        client.DEFAULT_STREAM_FRAME_MAX,
    );
    defer att_transport.deinit();

    var pending_transition: ?PendingTransition = null;
    defer {
        if (pending_transition) |*p| {
            switch (p.*) {
                .exit => {},
                .replace_attachment => |*att| att.close(),
            }
        }
    }

    wake_pipe = try WakePipe.init();
    defer wake_pipe.deinit();
    try fd_stream.setNonBlocking(wake_pipe.readFd());
    try fd_stream.setNonBlocking(wake_pipe.writeFd());

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

    fd_stream.setNonBlocking(in_fd) catch {
        stdin_open = false;
    };
    _ = fd_stream.setNonBlocking(out_fd) catch {};

    try queueOwnerReady(&att_transport);
    try queueResizeIfAvailable(&att_transport, in_fd);

    if (att_transport.wantsWrite()) {
        _ = try att_transport.pumpWrite(64 * 1024);
    }

    while (true) {
        if (try applyPendingTransition(
            allocator,
            attachment,
            &att_transport,
            &pending_transition,
            in_fd,
        )) |exit_kind| {
            return exit_kind;
        }

        var pfds = [4]c.struct_pollfd{
            .{
                .fd = if (stdin_open and pending_transition == null) in_fd else -1,
                .events = if (stdin_open and pending_transition == null) c.POLLIN else 0,
                .revents = 0,
            },
            .{
                .fd = attachment.fd,
                .events = att_transport.pollEvents(),
                .revents = 0,
            },
            .{
                .fd = if (!stdout_tx.isEmpty()) out_fd else -1,
                .events = if (!stdout_tx.isEmpty()) c.POLLOUT else 0,
                .revents = 0,
            },
            .{
                .fd = wake_pipe.readFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
        };

        while (true) {
            const pr = c.poll(&pfds, pfds.len, -1);
            if (pr >= 0) break;
            const e = std.posix.errno(-1);
            if (e == .INTR) continue;
            return error.IoError;
        }

        if ((pfds[3].revents & c.POLLIN) != 0) {
            wake_pipe.drain();
        }

        if (stdin_open and (pfds[0].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            stdin_open = false;
        }

        if (stdin_open and (pfds[0].revents & c.POLLIN) != 0) {
            const status = try fd_stream.readIntoQueue(allocator, in_fd, &stdin_rx, 64 * 1024);
            switch (status) {
                .progress => {
                    try queueRawInputToAttachment(allocator, &stdin_rx, &att_transport, 64 * 1024);
                },
                .would_block => {},
                .eof => stdin_open = false,
            }
        }

        if ((pfds[1].revents & c.POLLIN) != 0) {
            const read_result = try att_transport.pumpRead(64 * 1024);
            try pumpAttachmentMessages(allocator, &att_transport, &stdout_tx, &pending_transition);
            if (read_result.hit_eof) return .remote_closed;
        }

        if ((pfds[1].revents & c.POLLOUT) != 0) {
            _ = try att_transport.pumpWrite(64 * 1024);
        }

        if ((pfds[1].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0 and
            (pfds[1].revents & c.POLLIN) == 0)
        {
            if ((pfds[1].revents & c.POLLHUP) != 0 and
                (pfds[1].revents & (c.POLLERR | c.POLLNVAL)) == 0)
            {
                return .remote_closed;
            }
            return .remote_error;
        }

        if ((pfds[2].revents & c.POLLOUT) != 0) {
            _ = fd_stream.writeFromQueue(out_fd, &stdout_tx, 64 * 1024) catch {
                return .stdout_unavailable;
            };
        }

        if (winch_changed) {
            winch_changed = false;
            if (pending_transition == null) {
                try queueResizeIfAvailable(&att_transport, in_fd);
            }
        }
    }
}

test "transported forward detach queues success and exits after flush" {
    _ = runAttachBridge;
}
