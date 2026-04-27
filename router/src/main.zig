const std = @import("std");
const fd_stream = @import("fd_stream");
const router_runtime = @import("router_runtime");
const router_control = @import("router_control");
const router_session = @import("router_session");
const ctlwire = @import("ctlwire");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

const ControlConn = struct {
    fd: c_int,
    conn: ctlwire.server.Connection,
    ready_emitted: bool,

    fn init(fd: c_int) ControlConn {
        return .{
            .fd = fd,
            .conn = .init(fd),
            .ready_emitted = false,
        };
    }

    fn deinit(self: *ControlConn, allocator: std.mem.Allocator) void {
        self.conn.deinit(allocator);
        _ = c.close(self.fd);
    }
};

fn createListener(path: []const u8) !c_int {
    var addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);

    const max_path_len = addr.sun_path.len - 1;
    if (path.len == 0 or path.len > max_path_len) return error.InvalidArgs;

    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;

    _ = c.unlink(addr.sun_path[0..path.len :0]);

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.ListenFailed;
    errdefer _ = c.close(fd);

    if (c.bind(fd, @as(*const c.struct_sockaddr, @ptrCast(&addr)), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) {
        return error.ListenFailed;
    }
    if (c.listen(fd, 4) != 0) return error.ListenFailed;
    try fd_stream.setNonBlocking(fd);
    return fd;
}

fn printControlResponse(file: std.fs.File, result: router_control.Result) !void {
    var writer = file.writer(&.{});
    router_control.printResult(&writer.interface, result) catch |err| switch (err) {
        error.WriteFailed => return,
        else => return err,
    };
}

fn acceptControlConn(listener_fd: c_int, allocator: std.mem.Allocator, current: *?ControlConn) !void {
    const fd = c.accept(listener_fd, null, null);
    if (fd < 0) return;
    try fd_stream.setNonBlocking(fd);
    if (current.*) |*existing| {
        existing.deinit(allocator);
        current.* = null;
    }
    current.* = ControlConn.init(fd);
}

fn handleControlLine(
    conn: *ControlConn,
    runtime: *router_runtime.RouterRuntime,
    session: *router_session.Session,
    trimmed: []const u8,
) !bool {
    const parsed = router_control.parse(trimmed);
    const result: router_control.Result = switch (parsed) {
        .command => |cmd| blk: {
            switch (cmd) {
                .attach => |spec| {
                    if (session.active != null) break :blk .{ .err_runtime = .already_attached };
                    session.attach(spec) catch break :blk .{ .err_runtime = .connect_failed };
                    const res = router_control.applyAttach(runtime, spec);
                    if (res != .ok) session.detach();
                    break :blk res;
                },
                .detach => {
                    const res = router_control.applyDetach(runtime);
                    if (res == .ok) session.detach();
                    break :blk res;
                },
                else => break :blk router_control.executeRuntimeOnly(runtime, cmd),
            }
        },
        .err => |err| router_control.Result{ .err_parse = err },
    };
    try printControlResponse(conn.conn.file, result);
    return !runtime.should_exit;
}

fn stepControlConn(
    allocator: std.mem.Allocator,
    conn: *ControlConn,
    runtime: *router_runtime.RouterRuntime,
    session: *router_session.Session,
) !bool {
    if (!conn.ready_emitted) {
        var writer = conn.conn.file.writer(&.{});
        try ctlwire.message.writeEvent(&writer.interface, .{ .kind = "ready", .payload = "app=router version=1" });
        conn.ready_emitted = true;
    }

    var keep = true;
    while (true) {
        const next = try conn.conn.nextLine(allocator);
        const line_text = next orelse return keep;
        keep = try handleControlLine(conn, runtime, session, line_text);
        if (!keep) return false;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const control_path = args.next() orelse {
        std.debug.print("usage: router <control-socket-path>\n", .{});
        return error.InvalidArgs;
    };
    if (args.next() != null) {
        std.debug.print("usage: router <control-socket-path>\n", .{});
        return error.InvalidArgs;
    }

    var runtime = try router_runtime.RouterRuntime.init(allocator, control_path);
    defer runtime.deinit();

    const listener_fd = try createListener(control_path);
    defer {
        _ = c.close(listener_fd);
        _ = c.unlink(control_path.ptr);
    }

    const stdin_is_tty = c.isatty(c.STDIN_FILENO) == 1;
    if (stdin_is_tty) try fd_stream.setNonBlocking(c.STDIN_FILENO);
    if (c.isatty(c.STDOUT_FILENO) == 1) try fd_stream.setNonBlocking(c.STDOUT_FILENO);

    var session = router_session.Session.init(allocator, stdin_is_tty);
    defer session.deinit();

    var control_conn: ?ControlConn = null;
    defer if (control_conn) |*conn| conn.deinit(allocator);

    while (!runtime.should_exit) {
        try acceptControlConn(listener_fd, allocator, &control_conn);
        if (control_conn) |*conn| {
            const keep = try stepControlConn(allocator, conn, &runtime, &session);
            if (!keep) {
                conn.deinit(allocator);
                control_conn = null;
            }
        }

        if (session.active != null) {
            const stream_lost = try session.stepDataPump();
            if (stream_lost) {
                session.onStreamLost();
                runtime.detach() catch {};
                continue;
            }
        }

        var pfds = [_]c.struct_pollfd{
            .{ .fd = listener_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (control_conn) |conn| conn.fd else -1, .events = if (control_conn != null) c.POLLIN else 0, .revents = 0 },
            .{ .fd = c.STDIN_FILENO, .events = if (stdin_is_tty and session.active != null) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (session.active) |a| a.data_fd else -1, .events = if (session.active != null) @as(c_short, c.POLLIN) | (if (!session.sock_tx.isEmpty()) @as(c_short, c.POLLOUT) else 0) else 0, .revents = 0 },
            .{ .fd = c.STDOUT_FILENO, .events = if (!session.stdout_tx.isEmpty()) c.POLLOUT else 0, .revents = 0 },
        };
        _ = c.poll(&pfds, pfds.len, 25);
    }
}
