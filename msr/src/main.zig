const std = @import("std");
const host = @import("host");
const session_server = @import("server");
const client = @import("client");
const attach_bridge = @import("attach_bridge");
const cli_parse = @import("cli_parse");
const command_spec = @import("command_spec");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn usageLineForKind(kind: cli_parse.CommandKind) []const u8 {
    return switch (kind) {
        .help => "  msr help\n",
        .current => "  msr current\n",
        .create => "  msr create [-a|--attach] <path> [-- <cmd...>]\n",
        .attach => "  msr attach [-f|--force] <path>\n",
        .detach => "  msr detach\n",
        .resize => "  msr resize [-f|--force] <path> <cols> <rows>\n",
        .terminate => "  msr terminate [-f|--force] <path> [TERM|INT|KILL]\n",
        .wait => "  msr wait <path>\n",
        .status => "  msr status <path>\n",
        .exists => "  msr exists <path>\n",
    };
}

fn usage() void {
    out(
        "NAME\n" ++
            "  msr - minimal session runtime\n\n" ++
            "USAGE\n" ++
            "  [MSR_SESSION=<path>] msr [--session <path>] <command> [args]\n\n" ++
            "COMMANDS\n" ++
            "  create [-a|--attach] <path> [-- <cmd...>]  create a session\n" ++
            "  attach [-f|--force] <path>                 attach to a session\n" ++
            "  detach                                     detach the current session\n" ++
            "  current                                    print the current session path\n" ++
            "  resize [-f|--force] <path> <cols> <rows>   resize a session\n" ++
            "  terminate [-f|--force] <path> [signal]     send TERM, INT, or KILL\n" ++
            "  wait <path>                                wait for session exit\n" ++
            "  status <path>                              print session status\n" ++
            "  exists <path>                              test whether a session is reachable\n" ++
            "  help                                       show this help\n\n" ++
            "CONTEXT\n" ++
            "  --session=<path> or --session <path> overrides MSR_SESSION.\n" ++
            "  In current-session mode, attach and detach route through the current\n" ++
            "  session owner; other commands keep explicit-argument behavior.\n",
        .{},
    );
}

fn usageCreate() void { out("{s}", .{usageLineForKind(.create)}); }
fn usageAttachDirect() void { out("{s}", .{usageLineForKind(.attach)}); }
fn usageAttachNested() void { out("usage: msr a <target>\n", .{}); }
fn usageDetach() void { out("{s}", .{usageLineForKind(.detach)}); }
fn usageCurrent() void { out("{s}", .{usageLineForKind(.current)}); }
fn usageResize() void { out("{s}", .{usageLineForKind(.resize)}); }
fn usageTerminate() void { out("{s}", .{usageLineForKind(.terminate)}); }
fn usageWait() void { out("{s}", .{usageLineForKind(.wait)}); }
fn usageStatus() void { out("{s}", .{usageLineForKind(.status)}); }
fn usageExists() void { out("{s}", .{usageLineForKind(.exists)}); }

fn usageForCommandKind(kind: cli_parse.CommandKind) void {
    switch (kind) {
        .help => usage(),
        .current => usageCurrent(),
        .create => usageCreate(),
        .attach => usageAttachDirect(),
        .detach => usageDetach(),
        .resize => usageResize(),
        .terminate => usageTerminate(),
        .wait => usageWait(),
        .status => usageStatus(),
        .exists => usageExists(),
    }
}

fn nestedUsage(current_session: []const u8) void {
    out(
        "SESSION\n" ++
            "  {s}\n\n",
        .{current_session},
    );
    usage();
}

fn defaultShellArgv() [2][]const u8 {
    const raw = c.getenv("SHELL");
    const shell = if (raw) |p| std.mem.span(p) else "/bin/sh";
    return .{ shell, "-i" };
}

fn signalFromCli(sig: cli_parse.SignalSpec) client.Signal {
    return switch (sig) {
        .term => .term,
        .int => .int,
        .kill => .kill,
    };
}

fn spawnHostDetached(argv0: []const u8, path: []const u8, child_argv: []const []const u8) !void {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        _ = c.setsid();

        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const n: usize = 4 + child_argv.len + 1;
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
        var cli = client.SessionClient.init(std.heap.page_allocator, path) catch {
            _ = c.usleep(step_us);
            continue;
        };
        defer cli.deinit();

        _ = cli.status() catch {
            _ = c.usleep(step_us);
            continue;
        };
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

fn runAttachDirect(path: []const u8, mode: client.AttachMode) u8 {
    var cli = client.SessionClient.init(std.heap.page_allocator, path) catch {
        err("msr: failed to create client\n", .{});
        return 1;
    };
    defer cli.deinit();

    var att = cli.attach(mode) catch |e| {
        err("msr: attach failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer att.close();

    const bridge_exit = attach_bridge.runAttachBridge(std.heap.page_allocator, &att, c.STDIN_FILENO, c.STDOUT_FILENO) catch |e| {
        err("msr: attach bridge failed: {s}\n", .{@errorName(e)});
        return 1;
    };

    switch (bridge_exit) {
        .clean => {},
        .remote_closed => {
            if (c.isatty(c.STDERR_FILENO) == 1) {
                err("msr: session closed the current attachment\n", .{});
            }
        },
        .stdout_unavailable => {
            if (c.isatty(c.STDERR_FILENO) == 1) {
                err("msr: local terminal output became unavailable; session is still running\n", .{});
            }
        },
        .remote_error => {
            err("msr: attach stream failed\n", .{});
            return 1;
        },
    }

    if (c.isatty(c.STDOUT_FILENO) == 1) {
        out("\r\n", .{});
    }
    return 0;
}

fn ownerForwardWithRetry(current_session: []const u8, action: client.ForwardAction) !void {
    var cli = try client.SessionClient.init(std.heap.page_allocator, current_session);
    defer cli.deinit();

    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        cli.ownerForward(action) catch |e| switch (e) {
            client.Error.OwnerNotReady => {
                if (attempts >= 39) return e;
                _ = c.usleep(50_000);
                continue;
            },
            else => return e,
        };
        return;
    }
}

fn runAttachNested(current_session: []const u8, target: []const u8, force_requested: bool) u8 {
    if (force_requested) {
        err("msr: nested attach does not support -f|--force; use direct attach for ownership takeover\n", .{});
        return 1;
    }
    if (std.mem.eql(u8, current_session, target)) {
        err("msr: cannot attach current session to itself\n", .{});
        return 1;
    }

    ownerForwardWithRetry(current_session, .{ .attach = @constCast(target) }) catch |e| {
        err("msr: nested attach passthrough failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn runDetachNested(current_session: []const u8) u8 {
    ownerForwardWithRetry(current_session, .detach) catch |e| {
        err("msr: nested detach passthrough failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn runHost(path: []const u8, child_argv: []const []const u8) !u8 {

    const env_entry = try std.fmt.allocPrint(std.heap.page_allocator, "MSR_SESSION={s}", .{path});
    defer std.heap.page_allocator.free(env_entry);
    const env = [_][]const u8{env_entry};

    var session_host = try host.PtyChildHost.init(std.heap.page_allocator, .{
        .argv = child_argv,
        .env = env[0..],
        .rows = 24,
        .cols = 80,
    });
    defer session_host.deinit();

    try session_host.start();

    var server_state = session_server.SessionServer.init(std.heap.page_allocator, &session_host);
    defer server_state.deinit();

    server_state.listen(path) catch |e| {
        switch (e) {
            session_server.Error.AlreadyExists => err("msr: session already exists at {s}\n", .{path}),
            session_server.Error.PermissionDenied => err("msr: permission denied creating session socket at {s}\n", .{path}),
            session_server.Error.PathTooLong => err("msr: session socket path is too long: {s}\n", .{path}),
            else => err("msr: failed to create session at {s}\n", .{path}),
        }
        return 1;
    };

    while (true) {
        const progressed = blk: {
            const value = server_state.step() catch |e| {
                switch (e) {
                    session_server.Error.Unsupported => {
                        err("msr: ignoring client protocol error\n", .{});
                        break :blk false;
                    },
                    else => {
                        err("msr: internal server step failed: {s}\n", .{@errorName(e)});
                        _ = server_state.stop() catch {};
                        _ = session_host.close() catch {};
                        return 1;
                    },
                }
            };
            break :blk value;
        };

        _ = session_host.refresh() catch {};

        switch (session_host.currentState()) {
            .running, .starting => {
                if (!progressed) _ = c.usleep(1_000);
                continue;
            },
            .exited => {
                _ = server_state.stop() catch {};
                _ = session_host.close() catch {};
                break;
            },
            .idle, .closed => break,
        }
    }

    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    var argv_list = std.ArrayList([]const u8){};
    defer argv_list.deinit(init.gpa);

    while (it.next()) |a| try argv_list.append(init.gpa, a);
    const argv = argv_list.items;

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "_host")) {
        if (argv.len < 4) {
            err("msr: invalid _host arguments\n", .{});
            return 1;
        }

        const path = argv[2];

        if (argv.len < 5 or !std.mem.eql(u8, argv[3], "--")) {
            err("msr: invalid _host arguments\n", .{});
            return 1;
        }

        return try runHost(path, argv[4..]);
    }

    const parsed = try cli_parse.parseArgv(init.gpa, if (argv.len > 1) argv[1..] else &.{});
    switch (parsed) {
        .fail => |failure| {
            const raw_current_session = blk: {
                var explicit_session: ?[]const u8 = null;
                var idx: usize = 1;
                while (idx < argv.len) : (idx += 1) {
                    const tok = argv[idx];
                    if (std.mem.startsWith(u8, tok, "--session=")) {
                        explicit_session = tok[10..];
                        break;
                    }
                    if (std.mem.eql(u8, tok, "--session") and idx + 1 < argv.len) {
                        explicit_session = argv[idx + 1];
                        break;
                    }
                }
                if (explicit_session) |s| break :blk s;
                const raw = c.getenv("MSR_SESSION") orelse break :blk null;
                break :blk std.mem.span(raw);
            };

            switch (failure.kind) {
                .no_command => {
                    if (raw_current_session) |session| nestedUsage(session) else usage();
                    return 1;
                },
                .unknown_command => {
                    usage();
                    return 1;
                },
                else => {
                    if (failure.command) |cmd_kind| {
                        switch (cmd_kind) {
                            .help => usageForCommandKind(.help),
                            .current => {
                                err("msr: current does not take additional arguments\n", .{});
                                usageForCommandKind(.current);
                            },
                            .create => {
                                err("msr: invalid create arguments\n", .{});
                                usageForCommandKind(.create);
                            },
                            .attach => {
                                if (raw_current_session != null) {
                                    err("msr: nested attach requires <target> and does not support -f|--force\n", .{});
                                    usageAttachNested();
                                } else {
                                    err("msr: attach requires <path> and optional -f|--force\n", .{});
                                    usageForCommandKind(.attach);
                                }
                            },
                            .detach => {
                                err("msr: detach does not take additional arguments\n", .{});
                                usageForCommandKind(.detach);
                            },
                            .resize => {
                                err("msr: resize requires <path> <cols> <rows> and optional -f|--force\n", .{});
                                usageForCommandKind(.resize);
                            },
                            .terminate => {
                                err("msr: terminate requires <path> and optional signal or -f|--force\n", .{});
                                usageForCommandKind(.terminate);
                            },
                            .wait => {
                                err("msr: wait requires <path>\n", .{});
                                usageForCommandKind(.wait);
                            },
                            .status => {
                                err("msr: status requires <path>\n", .{});
                                usageForCommandKind(.status);
                            },
                            .exists => {
                                err("msr: exists requires <path>\n", .{});
                                usageForCommandKind(.exists);
                            },
                        }
                    } else {
                        usage();
                    }
                    return 1;
                },
            }
        },
        .ok => |ok| {
            var owned_ok = ok;
            defer owned_ok.deinit(init.gpa);

            const current_session = owned_ok.current_session;
            switch (owned_ok.command) {
                .help => {
                    usage();
                    return 0;
                },
                .current => {
                    if (current_session) |session| {
                        out("{s}\n", .{session});
                        return 0;
                    }
                    err("msr: current requires a current session context (--session or MSR_SESSION)\n", .{});
                    usageCurrent();
                    return 1;
                },
                .status => |args| {
                    var cli = client.SessionClient.init(std.heap.page_allocator, args.path) catch {
                        err("msr: failed to create client\n", .{});
                        return 1;
                    };
                    defer cli.deinit();

                    const st = cli.status() catch |e| {
                        err("msr: status failed: {s}\n", .{@errorName(e)});
                        return 1;
                    };

                    out("{s}\n", .{client.statusText(st)});
                    return switch (st) {
                        .running, .starting, .exited => 0,
                        else => 1,
                    };
                },
                .wait => |args| {
                    var cli = client.SessionClient.init(std.heap.page_allocator, args.path) catch {
                        err("msr: failed to create client\n", .{});
                        return 1;
                    };
                    defer cli.deinit();

                    var st = cli.wait() catch |e| {
                        err("msr: wait failed: {s}\n", .{@errorName(e)});
                        return 1;
                    };
                    defer st.deinit(std.heap.page_allocator);

                    switch (st) {
                        .code => |code| {
                            out("exit_code={d}\n", .{code});
                            return @intCast(@min(@as(i32, 255), @max(@as(i32, 0), code)));
                        },
                        .signal_text => |sig| {
                            out("exit_signal={s}\n", .{sig});
                            return 1;
                        },
                    }
                },
                .attach => |args| {
                    if (current_session) |session| {
                        return runAttachNested(session, args.target, args.force);
                    }
                    return runAttachDirect(args.target, if (args.force) .takeover else .exclusive);
                },
                .detach => {
                    if (current_session) |session| {
                        return runDetachNested(session);
                    }
                    err("msr: detach requires a current session context (--session or MSR_SESSION)\n", .{});
                    usageDetach();
                    return 1;
                },
                .resize => |args| {
                    var owner = openAttachmentForOwnerScopedOp(args.path, args.force) catch |e| {
                        err("msr: resize requires current ownership or -f|--force ({s})\n", .{@errorName(e)});
                        return 1;
                    };
                    defer owner.att.close();
                    defer owner.cli.deinit();

                    owner.att.resize(args.cols, args.rows) catch |e| {
                        err("msr: resize failed: {s}\n", .{@errorName(e)});
                        return 1;
                    };
                    return 0;
                },
                .exists => |args| {
                    var cli = client.SessionClient.init(std.heap.page_allocator, args.path) catch {
                        out("false\n", .{});
                        return 1;
                    };
                    defer cli.deinit();

                    _ = cli.status() catch {
                        out("false\n", .{});
                        return 1;
                    };

                    out("true\n", .{});
                    return 0;
                },
                .terminate => |args| {
                    var cli = client.SessionClient.init(std.heap.page_allocator, args.path) catch {
                        err("msr: failed to create client\n", .{});
                        return 1;
                    };
                    defer cli.deinit();

                    cli.terminate(signalFromCli(args.signal)) catch |e| {
                        err("msr: terminate failed: {s}\n", .{@errorName(e)});
                        return 1;
                    };
                    return 0;
                },
                .create => |args| {
                    const path = args.path;
                    const shell_argv = defaultShellArgv();
                    const child_argv = args.child_argv orelse shell_argv[0..];

                    var existing_cli = client.SessionClient.init(std.heap.page_allocator, path) catch null;
                    if (existing_cli) |*cli| {
                        defer cli.deinit();
                        const status_res = cli.status();
                        if (status_res) |_| {
                            err("msr: session already exists at {s}\n", .{path});
                            return 1;
                        } else |e| switch (e) {
                            client.Error.ConnectFailed => {},
                            else => {
                                err("msr: session already exists at {s} (status probe failed: {s})\n", .{ path, @errorName(e) });
                                return 1;
                            },
                        }
                    }

                    spawnHostDetached(argv[0], path, child_argv) catch {
                        err("msr: failed to spawn host\n", .{});
                        return 1;
                    };

                    if (!waitForReady(path, 2000)) {
                        err("msr: session did not become ready\n", .{});
                        return 1;
                    }

                    if (args.attach_after_create) {
                        if (current_session) |session| {
                            return runAttachNested(session, path, false);
                        }
                        return runAttachDirect(path, .exclusive);
                    }

                    return 0;
                },
            }
        },
    }
}
