const std = @import("std");
const host = @import("host");
const server = @import("server");
const client = @import("client");
const nested_client = @import("nested_client");
const attach_runtime = @import("attach_runtime");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
});

fn usage() void {
    out(
        "msr v0 (draft)\n" ++
            "Usage:\n" ++
            "  msr create <path>\n" ++
            "  msr create -a <path>\n" ++
            "  msr create <path> -- <cmd...>\n" ++
            "  msr create -a <path> -- <cmd...>\n" ++
            "  msr attach <path> [--takeover]\n" ++
            "  msr [--session=<current>] attach <target>\n" ++
            "  msr [--session=<current>] detach\n" ++
            "  msr resize <path> <cols> <rows> [--takeover]\n" ++
            "  msr terminate <path> [TERM|INT|KILL]\n" ++
            "  msr wait <path>\n" ++
            "  msr status <path>\n" ++
            "  msr exists <path>\n\n" ++
            "Current-session selection:\n" ++
            "  1. --session=<path>\n" ++
            "  2. MSR_SESSION\n" ++
            "  3. no current-session context\n\n" ++
            "Behavior:\n" ++
            "  - With a current-session context, attach/detach use nested passthrough.\n" ++
            "  - Nested passthrough does not silently fall back to direct behavior.\n" ++
            "  - detach is only available with a current-session context.\n\n" ++
            "Examples:\n" ++
            "  msr create /tmp/a.sock\n" ++
            "  msr create -a /tmp/a.sock\n" ++
            "  msr create /tmp/a.sock -- /usr/bin/top\n" ++
            "  msr attach /tmp/a.sock\n" ++
            "  msr --session=/tmp/current.sock detach\n" ++
            "  msr --session=/tmp/current.sock attach /tmp/other.sock\n\n" ++
            "Notes:\n" ++
            "  - create with no explicit command starts the default interactive shell ($SHELL -i, else /bin/sh -i).\n" ++
            "  - create is detached by default; use -a/--attach to attach immediately after creation.\n" ++
            "  - attach uses one socket plus an explicit attach handshake.\n" ++
            "  - attach stdin is optional; EOF on stdin does not detach by itself.\n" ++
            "  - wait is host-lifetime only in v0; no durable post-cleanup retrieval.\n" ++
            "  - resize is owner-scoped and may require --takeover to claim ownership.\n\n" ++
            "Internal:\n" ++
            "  msr _host <path> -- <cmd...>\n",
        .{},
    );
}

fn nestedUsage(current_session: []const u8) void {
    out(
        "msr nested mode\n" ++
            "current session: {s}\n\n" ++
            "Available commands:\n" ++
            "  msr detach\n" ++
            "  msr attach <target>\n\n" ++
            "Session selection:\n" ++
            "  --session=<path> overrides MSR_SESSION\n",
        .{current_session},
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

        if (c.setenv("MSR_SESSION", av[2].?, 1) != 0) {
            c._exit(127);
        }

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

fn openAttachmentForOwnerScopedOp(path: []const u8, takeover: bool) !struct { cli: client.SessionClient, att: client.SessionAttachment } {
    var cli = try client.SessionClient.init(std.heap.page_allocator, path);
    errdefer cli.deinit();
    const att = try cli.attach(if (takeover) .takeover else .exclusive);
    return .{ .cli = cli, .att = att };
}

fn defaultShellArgv() [2][]const u8 {
    const raw = c.getenv("SHELL");
    const shell = if (raw) |p| std.mem.span(p) else "/bin/sh";
    return .{ shell, "-i" };
}


const CreateArgs = struct {
    path: []const u8,
    child_argv: []const []const u8,
    attach_after_create: bool,
};

fn parseCreateArgs(argv: [][]const u8) ?CreateArgs {
    if (argv.len < 3) return null;

    var idx: usize = 2;
    var attach_after_create = false;
    if (idx < argv.len and (std.mem.eql(u8, argv[idx], "-a") or std.mem.eql(u8, argv[idx], "--attach"))) {
        attach_after_create = true;
        idx += 1;
    }
    if (idx >= argv.len) return null;

    const path = argv[idx];
    idx += 1;

    const child_argv = blk: {
        if (idx == argv.len) {
            const shell = defaultShellArgv();
            break :blk shell[0..];
        }
        if (idx < argv.len and std.mem.eql(u8, argv[idx], "--") and idx + 1 < argv.len) {
            break :blk argv[(idx + 1)..];
        }
        return null;
    };

    return .{
        .path = path,
        .child_argv = child_argv,
        .attach_after_create = attach_after_create,
    };
}

fn runAttachDirect(path: []const u8, mode: client.AttachMode) u8 {
    var cli = client.SessionClient.init(std.heap.page_allocator, path) catch return 1;
    defer cli.deinit();
    var att = cli.attach(mode) catch {
        err("msr: attach rejected (session unavailable, ownership conflict, or takeover required)\n", .{});
        return 1;
    };
    defer att.close();
    attach_runtime.runAttachBridge(std.heap.page_allocator, &att, c.STDIN_FILENO, c.STDOUT_FILENO) catch {
        err("msr: attach stream failed\n", .{});
        return 1;
    };
    return 0;
}

fn runAttachNested(current_session: []const u8, target: []const u8, takeover_requested: bool) u8 {
    if (takeover_requested) {
        err("msr: nested attach does not support --takeover; use direct attach for ownership takeover\n", .{});
        return 1;
    }
    var nested = nested_client.NestedClient.init(std.heap.page_allocator, current_session) catch return 1;
    defer nested.deinit();
    nested.attach(target) catch |e| {
        err("msr: nested attach passthrough failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn runDetachDirect(path: []const u8) u8 {
    var owner = openAttachmentForOwnerScopedOp(path, false) catch {
        err("msr: detach requires current ownership\n", .{});
        return 1;
    };
    defer owner.att.close();
    defer owner.cli.deinit();

    owner.att.detach() catch {
        err("msr: detach failed\n", .{});
        return 1;
    };
    return 0;
}

fn runDetachNested(current_session: []const u8) u8 {
    var nested = nested_client.NestedClient.init(std.heap.page_allocator, current_session) catch return 1;
    defer nested.deinit();
    nested.detach() catch |e| {
        err("msr: nested detach passthrough failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

const ParsedArgs = struct {
    args: std.ArrayList([]const u8),
    session_override: ?[]const u8,
};

fn parseArgs(init: std.process.Init) !ParsedArgs {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    var args = try std.ArrayList([]const u8).initCapacity(init.gpa, 8);
    errdefer args.deinit(init.gpa);

    var session_override: ?[]const u8 = null;
    while (it.next()) |a| {
        if (std.mem.startsWith(u8, a, "--session=")) {
            session_override = a[10..];
            continue;
        }
        try args.append(init.gpa, a);
    }

    return .{ .args = args, .session_override = session_override };
}

fn resolveCurrentSession(init: std.process.Init, session_override: ?[]const u8) ?[]const u8 {
    _ = init;
    if (session_override) |s| return s;
    const raw = c.getenv("MSR_SESSION") orelse return null;
    return std.mem.span(raw);
}

pub fn main(init: std.process.Init) !u8 {
    var parsed = try parseArgs(init);
    defer parsed.args.deinit(init.gpa);
    const argv = parsed.args;
    const current_session = resolveCurrentSession(init, parsed.session_override);

    if (argv.items.len < 2) {
        if (current_session) |session| nestedUsage(session) else usage();
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
        const sig = if (argv.items.len == 4) argv.items[3] else "TERM";
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
        const takeover_requested = argv.items.len == 4 and std.mem.eql(u8, argv.items[3], "--takeover");
        if (current_session) |session| {
            return runAttachNested(session, argv.items[2], takeover_requested);
        }
        return runAttachDirect(argv.items[2], if (takeover_requested) .takeover else .exclusive);
    }

    if (std.mem.eql(u8, cmd, "detach")) {
        if (current_session) |session| {
            if (argv.items.len != 2) {
                err("msr: nested detach uses the current session context and does not take an explicit path\n", .{});
                nestedUsage(session);
                return 1;
            }
            return runDetachNested(session);
        }
        err("msr: detach requires --session=<path> or MSR_SESSION; external direct detach has been removed\n", .{});
        return 1;
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
        const parsed_create = parseCreateArgs(argv.items) orelse {
            usage();
            return 1;
        };

        const path = parsed_create.path;
        const child_argv = parsed_create.child_argv;

        if (std.mem.eql(u8, cmd, "_host")) {
            const env_entry = try std.fmt.allocPrint(std.heap.page_allocator, "MSR_SESSION={s}", .{path});
            defer std.heap.page_allocator.free(env_entry);
            const env = [_][]const u8{env_entry};
            var session_host = try host.SessionHost.init(std.heap.page_allocator, .{ .argv = child_argv, .env = env[0..] });
            defer session_host.deinit();
            try session_host.start();

            var session_server = server.SessionServer.init(std.heap.page_allocator, &session_host);
            defer session_server.deinit();
            session_server.listen(path) catch |e| {
                switch (e) {
                    server.Error.AlreadyExists => err("msr: session already exists at {s}\n", .{path}),
                    server.Error.PermissionDenied => err("msr: permission denied creating session socket at {s}\n", .{path}),
                    server.Error.PathTooLong => err("msr: session socket path is too long: {s}\n", .{path}),
                    else => err("msr: failed to create session at {s}\n", .{path}),
                }
                return 1;
            };

            while (true) {
                _ = session_host.refresh() catch {};
                _ = session_server.step() catch {};
                switch (session_host.getState()) {
                    .running, .starting => {
                        _ = c.usleep(10_000);
                        continue;
                    },
                    .exited => {
                        _ = session_server.stop() catch {};
                        _ = session_host.close() catch {};
                        break;
                    },
                    .idle, .closed => break,
                }
            }
            return 0;
        }

        spawnHostDetached(argv.items[0], path, child_argv) catch return 1;
        if (!waitForReady(path, 2000)) return 1;
        if (parsed_create.attach_after_create) {
            return runAttachDirect(path, .exclusive);
        }
        return 0;
    }

    if (current_session) |session| nestedUsage(session) else usage();
    return 1;
}
