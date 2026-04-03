const std = @import("std");
const host = @import("host");
const server = @import("server");
const client = @import("client");
const nested_client = @import("nested_client");
const attach_runtime = @import("attach_runtime");
const cli_parse = @import("cli_parse");
const command_spec = @import("command_spec");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
});

fn usage() void {
    out(
        "NAME\n" ++
            "  msr - minimal session runtime for persistent PTY-backed sessions\n\n" ++
            "DESCRIPTION\n" ++
            "  msr runs a command inside a persistent PTY-backed session identified by\n" ++
            "  a socket path. Sessions can be created, attached, detached, and\n" ++
            "  re-attached.\n\n" ++
            "  A current session can be selected with --session=<path> or\n" ++
            "  MSR_SESSION. In that context, attach and detach operate on the\n" ++
            "  current session owner. All other commands keep their normal\n" ++
            "  explicit-argument behavior.\n\n" ++
            "USAGE\n",
        .{},
    );
    for (command_spec.commands) |cmd| {
        if (cmd.id == .help) continue;
        out("{s}", .{command_spec.usageLine(&cmd)});
    }
    out("\nCOMMANDS\n", .{});
    for (command_spec.commands) |cmd| {
        if (cmd.id == .help) continue;
        const line = command_spec.aliasSummary(std.heap.page_allocator, &cmd) catch continue;
        defer std.heap.page_allocator.free(line);
        out("{s}", .{line});
    }
    out(
        "\nCURRENT SESSION\n" ++
            "  --session=<path> or --session <path> overrides MSR_SESSION\n\n" ++
            "NESTED MODE\n" ++
            "  When a current session is selected, only these commands change:\n" ++
            "    msr a <target>   route attach through the current session owner\n" ++
            "    msr d            detach the current session\n\n" ++
            "  All other commands keep their normal explicit-argument behavior.\n",
        .{},
    );
}

fn usageCreate() void { out("{s}", .{command_spec.shortUsage(.create)}); }
fn usageAttachDirect() void { out("{s}", .{command_spec.shortUsage(.attach)}); }
fn usageAttachNested() void { out("usage: msr a <target>\n", .{}); }
fn usageDetach() void { out("{s}", .{command_spec.shortUsage(.detach)}); }
fn usageCurrent() void { out("{s}", .{command_spec.shortUsage(.current)}); }
fn usageResize() void { out("{s}", .{command_spec.shortUsage(.resize)}); }
fn usageTerminate() void { out("{s}", .{command_spec.shortUsage(.terminate)}); }
fn usageWait() void { out("{s}", .{command_spec.shortUsage(.wait)}); }
fn usageStatus() void { out("{s}", .{command_spec.shortUsage(.status)}); }
fn usageExists() void { out("{s}", .{command_spec.shortUsage(.exists)}); }

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
        "NESTED MODE\n" ++
            "  current session: {s}\n\n" ++
            "  In this context:\n" ++
            "    a <target>      routes through the current session owner\n" ++
            "    d               detaches the current session\n" ++
            "    current         prints the current session path\n" ++
            "    all other commands keep their normal explicit-argument behavior\n\n",
        .{current_session},
    );
    usage();
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

fn spawnHostDetached(argv0: []const u8, path: []const u8, child_argv: []const []const u8, enable_vterm: bool) !void {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        _ = c.setsid();

        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const n = 4 + (if (enable_vterm) @as(usize, 1) else 0) + child_argv.len + 1;
        const av = a.alloc(?[*:0]u8, n) catch c._exit(127);

        av[0] = (a.dupeZ(u8, argv0) catch c._exit(127)).ptr;
        av[1] = (a.dupeZ(u8, "_host") catch c._exit(127)).ptr;
        av[2] = (a.dupeZ(u8, path) catch c._exit(127)).ptr;
        var arg_base: usize = 3;
        if (enable_vterm) {
            av[arg_base] = (a.dupeZ(u8, "--vterm") catch c._exit(127)).ptr;
            arg_base += 1;
        }
        av[arg_base] = (a.dupeZ(u8, "--") catch c._exit(127)).ptr;
        arg_base += 1;
        for (child_argv, 0..) |arg, i| {
            av[arg_base + i] = (a.dupeZ(u8, arg) catch c._exit(127)).ptr;
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

fn defaultShellArgv() [2][]const u8 {
    const raw = c.getenv("SHELL");
    const shell = if (raw) |p| std.mem.span(p) else "/bin/sh";
    return .{ shell, "-i" };
}

fn renderSnapshot(snapshot: client.RemoteSnapshot) void {
    out("\x1b[?1049h\x1b[H\x1b[2J", .{});
    for (snapshot.snapshot.cells, 0..) |row, r| {
        for (row) |cell| out("{s}", .{cell.text});
        if (r + 1 < snapshot.snapshot.cells.len) out("\n", .{});
    }
    out("\x1b[{d};{d}H", .{ snapshot.snapshot.cursor_row + 1, snapshot.snapshot.cursor_col + 1 });
    if (snapshot.snapshot.cursor_visible) out("\x1b[?25h", .{}) else out("\x1b[?25l", .{});
}

fn runAttachDirect(path: []const u8, mode: client.AttachMode) u8 {
    var cli = client.SessionClient.init(std.heap.page_allocator, path) catch return 1;
    defer cli.deinit();

    // Plain attach is live-stream only. When terminal-state support is available,
    // upgrade attach to snapshot + after_seq replay so reattach can restore the
    // visible screen and then stream the missing tail.
    var used_snapshot = false;
    var att = blk: {
        const snap = cli.getScreenSnapshot() catch null;
        if (snap) |snapshot| {
            var owned_snapshot = snapshot;
            defer owned_snapshot.deinit(std.heap.page_allocator);
            if (cli.attachAfterSeq(mode, owned_snapshot.snapshot.seq)) |att_snapshot| {
                renderSnapshot(.{ .snapshot = owned_snapshot.snapshot });
                used_snapshot = true;
                break :blk att_snapshot;
            } else |_| {}
        }

        break :blk cli.attach(mode) catch {
            err("msr: attach rejected (session unavailable, ownership conflict, or takeover required)\n", .{});
            return 1;
        };
    };
    defer att.close();
    const bridge_exit = attach_runtime.runAttachBridge(std.heap.page_allocator, &att, c.STDIN_FILENO, c.STDOUT_FILENO) catch {
        err("msr: attach stream failed\n", .{});
        return 1;
    };
    switch (bridge_exit) {
        .clean => {},
        .remote_closed => {
            if (c.isatty(c.STDERR_FILENO) == 1) {
                err("msr: session closed the current attachment\n", .{});
            }
        },
        .stdin_closed => {},
        .stdin_suspended => {
            if (c.isatty(c.STDERR_FILENO) == 1) {
                err("msr: local terminal input became unavailable; session is still running\n", .{});
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

fn runAttachNested(current_session: []const u8, target: []const u8, force_requested: bool) u8 {
    if (force_requested) {
        err("msr: nested attach does not support -f|--force; use direct attach for ownership takeover\n", .{});
        return 1;
    }
    if (std.mem.eql(u8, current_session, target)) {
        err("msr: cannot attach current session to itself\n", .{});
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

fn runDetachNested(current_session: []const u8) u8 {
    var nested = nested_client.NestedClient.init(std.heap.page_allocator, current_session) catch return 1;
    defer nested.deinit();
    nested.detach() catch |e| {
        err("msr: nested detach passthrough failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn signalName(sig: cli_parse.SignalSpec) []const u8 {
    return switch (sig) {
        .term => "TERM",
        .int => "INT",
        .kill => "KILL",
    };
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
        var child_start: usize = 3;
        var enable_vterm = false;
        while (child_start < argv.len and !std.mem.eql(u8, argv[child_start], "--")) : (child_start += 1) {
            if (std.mem.eql(u8, argv[child_start], "--vterm")) enable_vterm = true;
        }
        if (child_start >= argv.len or !std.mem.eql(u8, argv[child_start], "--")) {
            err("msr: invalid _host arguments\n", .{});
            return 1;
        }
        const child_argv = argv[(child_start + 1)..];
        const env_entry = try std.fmt.allocPrint(std.heap.page_allocator, "MSR_SESSION={s}", .{path});
        defer std.heap.page_allocator.free(env_entry);
        const env = [_][]const u8{env_entry};
        var session_host = try host.SessionHost.init(std.heap.page_allocator, .{ .argv = child_argv, .env = env[0..], .enable_terminal_state = enable_vterm, .rows = 24, .cols = 80, .replay_capacity = 128 });
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
            _ = session_server.step() catch |e| {
                err("msr: internal server step failed: {s}\n", .{@errorName(e)});
                _ = session_server.stop() catch {};
                _ = session_host.close() catch {};
                return 1;
            };
            if (!session_server.hasOwner()) {
                const drained = session_host.drainObservedPtyOutput() catch &[_][]u8{};
                if (@TypeOf(drained) != *const [0][]u8) {
                    for (drained) |chunk| std.heap.page_allocator.free(chunk);
                    std.heap.page_allocator.free(drained);
                }
            }
            _ = session_host.refresh() catch {};
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
                    const st = cli.status() catch {
                        err("msr: failed to contact session\n", .{});
                        return 1;
                    };
                    defer std.heap.page_allocator.free(@constCast(st.status));
                    out("{s}\n", .{st.status});
                    return if (std.mem.eql(u8, st.status, "running") or std.mem.eql(u8, st.status, "starting") or std.mem.eql(u8, st.status, "exited")) 0 else 1;
                },
                .wait => |args| {
                    var cli = client.SessionClient.init(std.heap.page_allocator, args.path) catch return 1;
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
                    var owner = openAttachmentForOwnerScopedOp(args.path, args.force) catch {
                        err("msr: resize requires current ownership or -f|--force\n", .{});
                        return 1;
                    };
                    defer owner.att.close();
                    defer owner.cli.deinit();
                    owner.att.resize(args.cols, args.rows) catch {
                        err("msr: resize failed\n", .{});
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
                    var cli = client.SessionClient.init(std.heap.page_allocator, args.path) catch return 1;
                    defer cli.deinit();
                    cli.terminate(signalName(args.signal)) catch {
                        err("msr: failed to contact session\n", .{});
                        return 1;
                    };
                    return 0;
                },
                .create => |args| {
                    const path = args.path;
                    const shell_argv = defaultShellArgv();
                    const child_argv = args.child_argv orelse shell_argv[0..];

                    spawnHostDetached(argv[0], path, child_argv, args.vterm) catch return 1;
                    if (!waitForReady(path, 2000)) return 1;
                    if (args.attach_after_create) {
                        return runAttachDirect(path, .exclusive);
                    }
                    return 0;
                },
            }
        },
    }
}
