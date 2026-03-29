const std = @import("std");
const msr = @import("msr");
const rpc = msr.rpc;
const client = @import("client");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("poll.h");
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
        \\Notes:
        \\  - attach uses one socket plus an explicit attach handshake.
        \\  - attach stdin is optional; EOF on stdin does not detach by itself.
        \\  - wait is host-lifetime only in v0; no durable post-cleanup retrieval.
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

fn rpcCall(allocator: std.mem.Allocator, path: []const u8, req_msg: rpc.ControlReq) !rpc.ControlRes {
    return client.rpcCall(allocator, path, req_msg);
}

fn freeControlRes(allocator: std.mem.Allocator, res: *rpc.ControlRes) void {
    if (res.signal) |s| allocator.free(@constCast(s));
    if (res.err) |*e| {
        allocator.free(@constCast(e.code));
        if (e.message) |m| allocator.free(@constCast(m));
    }
}

fn connectUnix(path: []const u8) !c_int {
    return client.connectUnix(path);
}

fn rpcExists(allocator: std.mem.Allocator, path: []const u8) !bool {
    return client.rpcExists(allocator, path);
}

fn printRpcError(res: rpc.ControlRes) void {
    const code = if (res.err) |e| e.code else "error";
    const code_s = code;
    if (std.mem.eql(u8, code_s, "session_not_found")) {
        std.debug.print("msr: session not found\n", .{});
    } else if (std.mem.eql(u8, code_s, "session_running")) {
        std.debug.print("msr: session already attached (use --takeover to replace)\n", .{});
    } else if (std.mem.eql(u8, code_s, "permission_denied")) {
        std.debug.print("msr: permission denied\n", .{});
    } else if (std.mem.eql(u8, code_s, "invalid_args")) {
        std.debug.print("msr: invalid arguments\n", .{});
    } else {
        std.debug.print("msr: {s}\n", .{code_s});
    }
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

    if (std.mem.eql(u8, cmd, "status")) {
        if (argv.items.len != 3) {
            usage();
            return 1;
        }
        if (rt.status(argv.items[2])) |st| {
            std.debug.print("{s}\n", .{@tagName(st)});
            return if (st == .running or st == .exited_pending_wait or st == .stale) 0 else 1;
        } else |_| {
            std.debug.print("msr: invalid arguments\n", .{});
            return 1;
        }
    }

    if (std.mem.eql(u8, cmd, "resize")) {
        if (argv.items.len != 5) {
            usage();
            return 1;
        }
        const cols = parseU16(argv.items[3]) catch return 1;
        const rows = parseU16(argv.items[4]) catch return 1;
        var res = rpcCall(std.heap.page_allocator, argv.items[2], .{ .op = "resize", .path = argv.items[2], .cols = cols, .rows = rows }) catch {
            std.debug.print("msr: failed to contact session\n", .{});
            return 1;
        };
        defer freeControlRes(std.heap.page_allocator, &res);
        if (!res.ok) {
            printRpcError(res);
            return 1;
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd, "terminate")) {
        if (argv.items.len != 3 and argv.items.len != 4) {
            usage();
            return 1;
        }
        const sig = if (argv.items.len == 4) argv.items[3] else null;
        var res = rpcCall(std.heap.page_allocator, argv.items[2], .{ .op = "terminate", .path = argv.items[2], .signal = sig }) catch {
            std.debug.print("msr: failed to contact session\n", .{});
            return 1;
        };
        defer freeControlRes(std.heap.page_allocator, &res);
        if (!res.ok) {
            printRpcError(res);
            return 1;
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd, "wait")) {
        if (argv.items.len != 3) {
            usage();
            return 1;
        }
        var res = rpcCall(std.heap.page_allocator, argv.items[2], .{ .op = "wait", .path = argv.items[2] }) catch {
            std.debug.print("msr: failed to contact session\n", .{});
            return 1;
        };
        defer freeControlRes(std.heap.page_allocator, &res);
        if (!res.ok) {
            printRpcError(res);
            return 1;
        }

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
        const mode = if (argv.items.len == 4 and std.mem.eql(u8, argv.items[3], "--takeover")) msr.AttachMode.takeover else msr.AttachMode.exclusive;
        client.attachPath(std.heap.page_allocator, argv.items[2], mode, c.STDIN_FILENO, c.STDOUT_FILENO) catch |e| {
            switch (e) {
                error.ConnectFailed => {
                    std.debug.print("msr: failed to contact session\n", .{});
                    return 1;
                },
                error.AttachRejected => {
                    // Don't make a second RPC call here; the session may reject attach for many reasons.
                    // Keep the error boundary simple and avoid relying on parsing/freeing details.
                    std.debug.print("msr: attach rejected\n", .{});
                    return 1;
                },
                error.UnexpectedEof => return 0,
                else => {
                    std.debug.print("msr: attach stream failed\n", .{});
                    return 1;
                },
            }
        };
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

                _ = rt.pollExit(path) catch |e| switch (e) {
                    msr.RuntimeError.SessionNotFound => break,
                    else => null,
                };

                if (!rt.sessions.contains(path)) break;
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
