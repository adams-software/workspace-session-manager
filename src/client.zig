const std = @import("std");
const session = @import("msr");
const rpc = session.rpc;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("poll.h");
});

pub const Error = error{
    ConnectFailed,
    AttachRejected,
    IoError,
    ProtocolError,
    UnexpectedEof,
    OutOfMemory,
};

pub fn connectUnix(path: []const u8) Error!c_int {
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.ConnectFailed;

    if (c.connect(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) {
        _ = c.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

pub fn rpcCall(allocator: std.mem.Allocator, path: []const u8, req_msg: rpc.ControlReq) Error!rpc.ControlRes {
    const fd = try connectUnix(path);
    defer _ = c.close(fd);

    const req = rpc.encodeControlReq(allocator, req_msg) catch return error.ProtocolError;
    defer allocator.free(req);
    rpc.writeFrame(fd, req) catch return error.IoError;

    const res_bytes = rpc.readFrame(allocator, fd, 64 * 1024) catch |e| switch (e) {
        error.UnexpectedEof => return error.UnexpectedEof,
        else => return error.ProtocolError,
    };
    defer allocator.free(res_bytes);

    // NOTE: std.json.parseFromSlice allocates backing storage owned by the Parsed value.
    // Returning slices out of it would be use-after-free if we deinit(). So keep the
    // parsed object alive for this function and deep-copy the result.
    const Env = struct { type: []const u8, payload: rpc.ControlRes };
    var parsed = std.json.parseFromSlice(Env, allocator, res_bytes, .{ .ignore_unknown_fields = true }) catch return error.ProtocolError;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "control_res")) return error.ProtocolError;

    // Deep copy the payload (strings) so caller can safely use it after we deinit.
    const p = parsed.value.payload;
    var out: rpc.ControlRes = .{ .ok = p.ok };
    out.exists = p.exists;
    out.code = p.code;
    if (p.signal) |sig| out.signal = try allocator.dupe(u8, sig) else out.signal = null;
    if (p.err) |eb| {
        var err_body: rpc.ControlRes.ErrBody = .{ .code = try allocator.dupe(u8, eb.code), .message = null };
        if (eb.message) |m| err_body.message = try allocator.dupe(u8, m);
        out.err = err_body;
    }
    return out;
}

pub fn rpcExists(allocator: std.mem.Allocator, path: []const u8) Error!bool {
    const res = try rpcCall(allocator, path, .{ .op = "exists", .path = path });
    if (!res.ok) return error.AttachRejected;
    return res.exists orelse false;
}

fn writeAll(fd: c_int, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) return error.IoError;
        if (n == 0) return error.IoError;
        off += @intCast(n);
    }
}

pub fn bridgeAttachClient(allocator: std.mem.Allocator, fd: c_int, in_fd: c_int, out_fd: c_int) Error!void {
    var stdin_open = true;
    var fds = [2]c.struct_pollfd{
        .{ .fd = in_fd, .events = c.POLLIN, .revents = 0 },
        .{ .fd = fd, .events = c.POLLIN, .revents = 0 },
    };
    var stdin_buf: [4096]u8 = undefined;
    var b64_buf: [8192]u8 = undefined;

    while (true) {
        fds[0].events = if (stdin_open) c.POLLIN else 0;
        const pr = c.poll(&fds, 2, -1);
        if (pr < 0) return error.IoError;

        if (stdin_open and (fds[0].revents & c.POLLIN) != 0) {
            const n = c.read(in_fd, &stdin_buf, stdin_buf.len);
            if (n < 0) return error.IoError;
            if (n == 0) {
                stdin_open = false;
            } else {
                const enc_len = std.base64.standard.Encoder.calcSize(@intCast(n));
                _ = std.base64.standard.Encoder.encode(b64_buf[0..enc_len], stdin_buf[0..@intCast(n)]);
                const payload = rpc.encodeDataMsg(allocator, .{ .stream = "stdin", .bytes_b64 = b64_buf[0..enc_len] }) catch return error.ProtocolError;
                defer allocator.free(payload);
                rpc.writeFrame(fd, payload) catch return error.IoError;
            }
        }

        if ((fds[1].revents & c.POLLIN) != 0) {
            const frame = rpc.readFrame(allocator, fd, 256 * 1024) catch |e| switch (e) {
                error.UnexpectedEof => return error.UnexpectedEof,
                else => return error.ProtocolError,
            };
            defer allocator.free(frame);

            const parsed = std.json.parseFromSlice(struct {
                type: []const u8,
            }, allocator, frame, .{ .ignore_unknown_fields = true }) catch return error.ProtocolError;
            defer parsed.deinit();

            if (std.mem.eql(u8, parsed.value.type, "data")) {
                const msg = rpc.parseDataMsg(allocator, frame) catch return error.ProtocolError;
                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(msg.bytes_b64) catch return error.ProtocolError;
                const decoded = allocator.alloc(u8, decoded_len) catch return error.ProtocolError;
                defer allocator.free(decoded);
                std.base64.standard.Decoder.decode(decoded, msg.bytes_b64) catch return error.ProtocolError;
                try writeAll(out_fd, decoded);
            } else if (std.mem.eql(u8, parsed.value.type, "event")) {
                const ev = rpc.parseEventMsg(allocator, frame) catch return error.ProtocolError;
                if (std.mem.eql(u8, ev.kind, "session_end")) return;
            } else {
                return error.ProtocolError;
            }
        }

        if (stdin_open and (fds[0].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) {
            stdin_open = false;
        }
        if ((fds[1].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) return;
    }
}

pub fn attachPath(allocator: std.mem.Allocator, path: []const u8, mode: session.AttachMode, in_fd: c_int, out_fd: c_int) Error!void {
    const mode_str = switch (mode) {
        .exclusive => "exclusive",
        .takeover => "takeover",
    };

    const fd = try connectUnix(path);
    defer _ = c.close(fd);

    const req = rpc.encodeControlReq(allocator, .{ .op = "attach", .path = path, .mode = mode_str }) catch return error.ProtocolError;
    defer allocator.free(req);
    rpc.writeFrame(fd, req) catch return error.IoError;

    const res_bytes = rpc.readFrame(allocator, fd, 64 * 1024) catch |e| switch (e) {
        error.UnexpectedEof => return error.UnexpectedEof,
        else => return error.ProtocolError,
    };
    defer allocator.free(res_bytes);
    var parsed = std.json.parseFromSlice(struct { type: []const u8, payload: rpc.ControlRes }, allocator, res_bytes, .{ .ignore_unknown_fields = true }) catch return error.ProtocolError;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "control_res")) return error.ProtocolError;
    const res = parsed.value.payload;
    if (!res.ok) return error.AttachRejected;

    try bridgeAttachClient(allocator, fd, in_fd, out_fd);
}
