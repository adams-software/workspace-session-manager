const std = @import("std");
const host = @import("host");
const server = @import("server");
const client = @import("client");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("poll.h");
});

fn usage() void {
    out(
        "msr v0 (draft)\n" ++
            "Usage:\n" ++
            "  msr create <path> -- <cmd...>\n" ++
            "  msr attach <path> [--takeover]\n" ++
            "  msr resize <path> <cols> <rows> [--takeover]\n" ++
            "  msr terminate <path> [TERM|INT|KILL]\n" ++
            "  msr wait <path>\n" ++
            "  msr status <path>\n" ++
            "  msr exists <path>\n\n" ++
            "Notes:\n" ++
            "  - attach uses one socket plus an explicit attach handshake.\n" ++
            "  - attach stdin is optional; EOF on stdin does not detach by itself.\n" ++
            "  - wait is host-lifetime only in v0; no durable post-cleanup retrieval.\n" ++
            "  - resize is owner-scoped and may require --takeover to claim ownership.\n\n" ++
            "Internal:\n" ++
            "  msr _host <path> -- <cmd...>\n",
        .{},
    );
}

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
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

fn waitForReady(path: []const u8, timeout_ms: u32) bool {
    const step_us: u32 = 10_000;
    const loops = timeout_ms / 10;
    var i: u32 = 0;
    while (i < loops) : (i += 1) {
        const fd = client.connectUnix(path) catch {
            _ = c.usleep(step_us);
            continue;
        };
        _ = c.close(fd);
        return true;
    }
    return false;
}

fn attachBridge(allocator: std.mem.Allocator, attachment: *client.SessionAttachment, in_fd: c_int, out_fd: c_int) !void {
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

        const decoded = attachment.readDataFrame() catch |e| switch (e) {
            error.UnexpectedEof => return,
            else => return e,
        };
        defer allocator.free(decoded);
        _ = c.write(out_fd, decoded.ptr, decoded.len);
    }
}

fn openAttachmentForOwnerScopedOp(path: []const u8, takeover: bool) !struct { cli: client.SessionClient, att: client.SessionAttachment } {
    var cli = try client.SessionClient.init(std.heap.page_allocator, path);
    errdefer cli.deinit();
    const att = cli.attach(if (takeover) .takeover else .exclusive) catch |e| {
        cli.deinit();
        return e;
    };
    return .{ .cli = cli, .att = att };
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

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        usage();
        return 0;
    }

    if (std.mem.eql(u8, cmd, "status")) {
        if (argv.items.len != 3) {
            usage();
            return 1;
        }
        var cli = client.SessionClient.init(std.heap.page_allocator, argv.items[2]) catch {
            err("msr: failed to create client\n", .{});
            return 1;
        };
        defer cli.deinit();
        const st = cli.status() catch {
            err("msr: failed to contact session\n", .{});
            return 1;
        };
        defer std.heap.page_allocator.free(@constCast(st.status));
        out("{s}\n", .{st.status});
        return if (std.mem.eql(u8, st.status, "running") or std.mem.eql(u8, st.status, "starting") or std.mem.eql(u8, st.status, "exited")) 0 else 1;
    }

    if (std.mem.eql(u8, cmd, "terminate")) {
        if (argv.items.len != 3 and argv.items.len != 4) {
            usage();
            return 1;
        }
        const sig = if (argv.items.len == 4) argv.items[3] else null;
        var cli = client.SessionClient.init(std.heap.page_allocator, argv.items[2]) catch return 1;
        defer cli.deinit();
        cli.terminate(sig) catch {
            err("msr: failed to contact session\n", .{});
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, cmd, "wait")) {
        if (argv.items.len != 3) {
            usage();
            return 1;
        }
        var cli = client.SessionClient.init(std.heap.page_allocator, argv.items[2]) catch return 1;
        defer cli.deinit();
        const st = cli.wait() catch {
            err("msr: failed to contact session\n", .{});
            return 1;
        };
        defer if (st.signal) |s| std.heap.page_allocator.free(@constCast(s));

        if (st.code) |code| {
            out("exit_code={d}\n", .{code});
            return @intCast(@min(@as(i32, 255), @max(@as(i32, 0), code)));
        }
        out("exit_signal={s}\n", .{st.signal orelse "unknown"});
        return 1;
    }

    if (std.mem.eql(u8, cmd, "attach")) {
        if (argv.items.len != 3 and argv.items.len != 4) {
            usage();
            return 1;
        }
        const mode = if (argv.items.len == 4 and std.mem.eql(u8, argv.items[3], "--takeover")) client.AttachMode.takeover else client.AttachMode.exclusive;
        var cli = client.SessionClient.init(std.heap.page_allocator, argv.items[2]) catch return 1;
        defer cli.deinit();
        var att = cli.attach(mode) catch {
            err("msr: attach rejected\n", .{});
            return 1;
        };
        defer att.close();
        attachBridge(std.heap.page_allocator, &att, c.STDIN_FILENO, c.STDOUT_FILENO) catch {
            err("msr: attach stream failed\n", .{});
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, cmd, "resize")) {
        if (argv.items.len != 5 and argv.items.len != 6) {
            usage();
            return 1;
        }
        const cols = parseU16(argv.items[3]) catch return 1;
        const rows = parseU16(argv.items[4]) catch return 1;
        const takeover = argv.items.len == 6 and std.mem.eql(u8, argv.items[5], "--takeover");

        var owner = openAttachmentForOwnerScopedOp(argv.items[2], takeover) catch {
            err("msr: resize requires current ownership or --takeover\n", .{});
            return 1;
        };
        defer owner.att.close();
        defer owner.cli.deinit();

        owner.att.resize(cols, rows) catch {
            err("msr: resize failed\n", .{});
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, cmd, "exists")) {
        if (argv.items.len != 3) {
            usage();
            return 1;
        }
        const fd = client.connectUnix(argv.items[2]) catch {
            out("false\n", .{});
            return 1;
        };
        _ = c.close(fd);
        out("true\n", .{});
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
            var session_host = try host.SessionHost.init(std.heap.page_allocator, .{ .argv = child_argv });
            defer session_host.deinit();
            try session_host.start();

            var session_server = server.SessionServer.init(std.heap.page_allocator, &session_host);
            defer session_server.deinit();
            try session_server.listen(path);

            while (true) {
                _ = session_server.step() catch {};
                switch (session_host.getState()) {
                    .running, .starting => {
                        _ = c.usleep(10_000);
                        continue;
                    },
                    .exited => break,
                    .idle, .closed => break,
                }
            }
            return 0;
        }

        spawnHostDetached(argv.items[0], path, child_argv) catch return 1;
        if (!waitForReady(path, 2000)) return 1;
        return 0;
    }

    usage();
    return 1;
}
