const std = @import("std");
const fd_stream = @import("fd_stream");
const router_runtime = @import("router_runtime");
const router_control = @import("router_control");
const router_session = @import("router_session");
const router_core = @import("router_core");
const ctlwire = @import("ctlwire");

const c = @cImport({
    @cInclude("errno.h");
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
    core: *router_core.RouterCore,
    trimmed: []const u8,
) !bool {
    const parsed = router_control.parse(trimmed);
    const result: router_control.Result = switch (parsed) {
        .command => |cmd| core.handleCommand(cmd),
        .err => |err| router_control.Result{ .err_parse = err },
    };
    try printControlResponse(conn.conn.file, result);
    return !core.runtime.should_exit;
}

fn stepControlConn(
    allocator: std.mem.Allocator,
    conn: *ControlConn,
    core: *router_core.RouterCore,
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
        keep = try handleControlLine(conn, core, line_text);
        if (!keep) return false;
    }
}

const ControlMode = union(enum) {
    socket_path: []const u8,
    fd: c_int,
};

fn usage() void {
    std.debug.print("usage: router <control-socket-path> | router --control-fd <fd>\n", .{});
}

fn parseControlMode(args: *std.process.ArgIterator) !ControlMode {
    const first = args.next() orelse return error.InvalidArgs;
    if (std.mem.eql(u8, first, "--control-fd")) {
        const fd_text = args.next() orelse return error.InvalidArgs;
        if (args.next() != null) return error.InvalidArgs;
        const fd = try std.fmt.parseInt(c_int, fd_text, 10);
        if (fd < 0) return error.InvalidArgs;
        return .{ .fd = fd };
    }
    if (args.next() != null) return error.InvalidArgs;
    return .{ .socket_path = first };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const mode = parseControlMode(&args) catch {
        usage();
        return error.InvalidArgs;
    };

    const runtime_control_name = switch (mode) {
        .socket_path => |path| path,
        .fd => "fd:control",
    };
    var runtime = try router_runtime.RouterRuntime.init(allocator, runtime_control_name);
    defer runtime.deinit();

    var listener_fd: ?c_int = null;
    var control_conn: ?ControlConn = null;
    switch (mode) {
        .socket_path => |control_path| {
            listener_fd = try createListener(control_path);
            defer {
                _ = c.close(listener_fd.?);
                _ = c.unlink(control_path.ptr);
            };
        },
        .fd => |fd| {
            try fd_stream.setNonBlocking(fd);
            control_conn = ControlConn.init(fd);
        },
    }

    const stdin_is_tty = c.isatty(c.STDIN_FILENO) == 1;
    if (stdin_is_tty) try fd_stream.setNonBlocking(c.STDIN_FILENO);
    if (c.isatty(c.STDOUT_FILENO) == 1) try fd_stream.setNonBlocking(c.STDOUT_FILENO);

    var session = router_session.Session.init(allocator, stdin_is_tty);
    defer session.deinit();
    var core = router_core.RouterCore.init(&runtime, &session);

    defer if (control_conn) |*conn| conn.deinit(allocator);

    while (!runtime.should_exit) {
        if (listener_fd) |fd| try acceptControlConn(fd, allocator, &control_conn);
        if (control_conn) |*conn| {
            const keep = try stepControlConn(allocator, conn, &core);
            if (!keep) {
                conn.deinit(allocator);
                control_conn = null;
            }
        }

        if (session.active != null) {
            const stream_lost = try session.stepDataPump();
            if (stream_lost) {
                core.onStreamLost();
                continue;
            }
            try session.syncResizeFromTty();
        }

        var pfds = [_]c.struct_pollfd{
            .{ .fd = listener_fd orelse -1, .events = if (listener_fd != null) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (control_conn) |conn| conn.fd else -1, .events = if (control_conn != null) c.POLLIN else 0, .revents = 0 },
            .{ .fd = c.STDIN_FILENO, .events = if (stdin_is_tty and session.active != null) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (session.active) |a| a.data_fd else -1, .events = if (session.active != null) @as(c_short, c.POLLIN) | (if (!session.sock_tx.isEmpty()) @as(c_short, c.POLLOUT) else 0) else 0, .revents = 0 },
            .{ .fd = c.STDOUT_FILENO, .events = if (!session.stdout_tx.isEmpty()) c.POLLOUT else 0, .revents = 0 },
        };
        _ = c.poll(&pfds, pfds.len, 25);
    }
}
