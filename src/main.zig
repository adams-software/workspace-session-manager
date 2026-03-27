const std = @import("std");
const msr = @import("msr");
const rpc = msr.rpc;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
});

fn usage() void {
    std.debug.print(
        \\msr v0 (draft)
        \\Usage:
        \\  msr create <path> -- <cmd...>
        \\  msr attach <path> [--takeover]
        \\  msr resize <path> <cols> <rows>
        \\  msr terminate <path> [TERM|INT|KILL]
        \\  msr wait <path>
        \\  msr exists <path>
        \\
        \\Internal:
        \\  msr _host <path> -- <cmd...>
        \\
    , .{});
}

fn parseU16(s: []const u8) !u16 {
    return std.fmt.parseInt(u16, s, 10);
}

fn spawnHostDetached(argv0: []const u8, path: []const u8, child_argv: []const []const u8) !void {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        _ = c.setsid();

        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const n = 4 + child_argv.len + 1;
        const av = a.alloc(?[*:0]u8, n) catch c._exit(127);

        av[0] = (a.dupeZ(u8, argv0) catch c._exit(127)).ptr;
        av[1] = (a.dupeZ(u8, "_host") catch c._exit(127)).ptr;
        av[2] = (a.dupeZ(u8, path) catch c._exit(127)).ptr;
        av[3] = (a.dupeZ(u8, "--") catch c._exit(127)).ptr;
        for (child_argv, 0..) |arg, i| {
            av[4 + i] = (a.dupeZ(u8, arg) catch c._exit(127)).ptr;
        }
        av[n - 1] = null;

        _ = c.execvp(av[0].?, @ptrCast(av.ptr));
        c._exit(127);
    }
}

fn waitForReady(rt: *msr.Runtime, path: []const u8, timeout_ms: u32) bool {
    _ = rt;
    const step_us: u32 = 10_000;
    const loops = timeout_ms / 10;
    var i: u32 = 0;
    while (i < loops) : (i += 1) {
        const fd = connectUnix(path) catch {
            _ = c.usleep(step_us);
            continue;
        };
        _ = c.close(fd);
        return true;
    }
    return false;
}

fn connectUnix(path: []const u8) !c_int {
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

fn rpcCall(allocator: std.mem.Allocator, path: []const u8, req_msg: rpc.ControlReq) !rpc.ControlRes {
    const fd = try connectUnix(path);
    defer _ = c.close(fd);

    const req = try rpc.encodeControlReq(allocator, req_msg);
    defer allocator.free(req);
    try rpc.writeFrame(fd, req);

    const res_bytes = try rpc.readFrame(allocator, fd, 64 * 1024);
    defer allocator.free(res_bytes);

    return try rpc.parseControlRes(allocator, res_bytes);
}

fn rpcExists(allocator: std.mem.Allocator, path: []const u8) !bool {
    const res = try rpcCall(allocator, path, .{ .op = "exists", .path = path });
    if (!res.ok) return error.RemoteError;
    return res.exists orelse false;
}

pub fn main(init: std.process.Init) !u8 {
    var it = std.process.Args.Iterator.init(init.minimal.args);

    var argv = try std.ArrayList([]const u8).initCapacity(init.gpa, 8);
    defer argv.deinit(init.gpa);
    while (it.next()) |a| try argv.append(init.gpa, a);

    if (argv.items.len < 2) {
        usage();
        return 1;
    }

    const cmd = argv.items[1];

    var rt = msr.Runtime.init(std.heap.page_allocator);
    defer rt.deinit();

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        usage();
        return 0;
    }

    if (std.mem.eql(u8, cmd, "exists")) {
        if (argv.items.len != 3) {
            usage();
            return 1;
        }
        const ok = rpcExists(std.heap.page_allocator, argv.items[2]) catch false;
        std.debug.print("{s}\n", .{if (ok) "true" else "false"});
        return if (ok) 0 else 1;
    }

    if (std.mem.eql(u8, cmd, "resize")) {
        if (argv.items.len != 5) {
            usage();
            return 1;
        }
        const cols = parseU16(argv.items[3]) catch return 1;
        const rows = parseU16(argv.items[4]) catch return 1;
        const res = rpcCall(std.heap.page_allocator, argv.items[2], .{ .op = "resize", .path = argv.items[2], .cols = cols, .rows = rows }) catch return 1;
        return if (res.ok) 0 else 1;
    }

    if (std.mem.eql(u8, cmd, "terminate")) {
        if (argv.items.len != 3 and argv.items.len != 4) {
            usage();
            return 1;
        }
        const sig = if (argv.items.len == 4) argv.items[3] else null;
        const res = rpcCall(std.heap.page_allocator, argv.items[2], .{ .op = "terminate", .path = argv.items[2], .signal = sig }) catch return 1;
        return if (res.ok) 0 else 1;
    }

    if (std.mem.eql(u8, cmd, "wait")) {
        if (argv.items.len != 3) {
            usage();
            return 1;
        }
        const res = rpcCall(std.heap.page_allocator, argv.items[2], .{ .op = "wait", .path = argv.items[2] }) catch return 1;
        if (!res.ok) return 1;

        if (res.code) |code| {
            std.debug.print("exit_code={d}\n", .{code});
            return @intCast(@min(@as(i32, 255), @max(@as(i32, 0), code)));
        }
        std.debug.print("exit_signal={s}\n", .{res.signal orelse "unknown"});
        return 1;
    }

    if (std.mem.eql(u8, cmd, "attach")) {
        if (argv.items.len != 3 and argv.items.len != 4) {
            usage();
            return 1;
        }
        const mode: msr.AttachMode = if (argv.items.len == 4 and std.mem.eql(u8, argv.items[3], "--takeover")) .takeover else .exclusive;
        rt.attach(argv.items[2], mode) catch return 1;
        return 0;
    }

    if (std.mem.eql(u8, cmd, "create") or std.mem.eql(u8, cmd, "_host")) {
        if (argv.items.len < 5) {
            usage();
            return 1;
        }
        if (!std.mem.eql(u8, argv.items[3], "--")) return 1;

        const path = argv.items[2];
        const child_argv = argv.items[4..];

        if (std.mem.eql(u8, cmd, "_host")) {
            try rt.create(path, .{ .argv = child_argv });

            while (true) {
                _ = rt.serveControlOnce(std.heap.page_allocator, path, 100) catch {};

                const polled = rt.pollExit(path) catch |e| switch (e) {
                    msr.RuntimeError.SessionNotFound => break,
                    else => null,
                };
                if (polled != null) break;
            }
            return 0;
        }

        spawnHostDetached(argv.items[0], path, child_argv) catch return 1;
        if (!waitForReady(&rt, path, 2000)) return 1;
        return 0;
    }

    usage();
    return 1;
}
