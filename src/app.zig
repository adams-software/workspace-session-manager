const std = @import("std");
const session = @import("msr");
const client = @import("client");
const manager = @import("manager");
const manager_v2 = @import("manager_v2");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("pwd.h");
    @cInclude("sys/socket.h");
});

pub const Error = error{ InvalidArgs } || manager_v2.Error;

pub const Env = struct {
    // cwd is allocated as [:0]u8 by std.process.currentPathAlloc in Zig 0.16-dev.
    // Keep the sentinel type so we can free it with the same slice shape.
    working_dir: [:0]const u8,
    current_name: ?[]const u8,
};

fn basename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..];
    }
    return path;
}

fn dirname(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return if (i - 1 == 0) "/" else path[0 .. i - 1];
    }
    return ".";
}

fn getCwd(init: std.process.Init, allocator: std.mem.Allocator) ![:0]u8 {
    return std.process.currentPathAlloc(init.io, allocator);
}

pub fn acquireEnv(init: std.process.Init, allocator: std.mem.Allocator, environ: std.process.Environ) !Env {
    // If MSR_SESSION is set, treat it as authoritative session context.
    const msr_session = std.process.Environ.getAlloc(environ, allocator, "MSR_SESSION") catch null;
    if (msr_session) |p| {
        defer allocator.free(p);
        // Derive working dir + current name.
        const wd = dirname(p);
        const bn = basename(p);
        const wd_dupe = try allocator.dupeZ(u8, wd);
        const bn_dupe = try allocator.dupe(u8, bn);
        return .{ .working_dir = wd_dupe, .current_name = bn_dupe };
    }

    const cwd = try getCwd(init, allocator);
    return .{ .working_dir = cwd, .current_name = null };
}

fn freeEnv(allocator: std.mem.Allocator, env: Env) void {
    // env.working_dir may come from std.process.currentPathAlloc(), which uses
    // allocator.dupeZ() (sentinel-terminated) internally. Free it as [:0]u8 to
    // match the allocation size (len+1).
    allocator.free(@as([:0]u8, @ptrCast(@alignCast(@constCast(env.working_dir)))));
    if (env.current_name) |n| allocator.free(@constCast(n));
}

fn parseAlias(cmd: []const u8) []const u8 {
    if (std.mem.eql(u8, cmd, "ls")) return "list";
    if (std.mem.eql(u8, cmd, "gn")) return "go-next";
    if (std.mem.eql(u8, cmd, "gb")) return "go-prev";
    return cmd;
}

fn usage() void {
    std.debug.print(
        \\msr-app (draft)
        \\Usage:
        \\  msr-app cwd
        \\  msr-app current
        \\  msr-app list|ls
        \\  msr-app exists <name>
        \\  msr-app status <name>
        \\  msr-app create <name> -- <cmd...>
        \\  msr-app attach <name>
        \\  msr-app terminate <name> [TERM|INT|KILL]
        \\  msr-app wait <name>
        \\  msr-app next
        \\  msr-app prev
        \\  msr-app go-next|gn
        \\  msr-app go-prev|gb
        \\
        \\Context:
        \\  - If MSR_SESSION is set, default working dir is dirname(MSR_SESSION)
        \\    and current is basename(MSR_SESSION).
        \\  - Otherwise working dir is shell cwd and current is null.
        \\
    , .{});
}

fn missingArgs(msg: []const u8) u8 {
    std.debug.print("msr-app: {s}\n", .{msg});
    usage();
    return 1;
}

const DefaultCmd = struct {
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
};

fn defaultCmd(allocator: std.mem.Allocator, environ: std.process.Environ) !DefaultCmd {
    // Mirror atch behavior: if no command is given, use $SHELL, else fall back to pw_shell, else /bin/sh.
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const shell_env = std.process.Environ.getAlloc(environ, a, "SHELL") catch null;
    if (shell_env) |s| {
        if (s.len != 0) {
            const argv = try a.alloc([]const u8, 1);
            argv[0] = s;
            return .{ .arena = arena, .argv = argv };
        }
    }

    const pw = c.getpwuid(c.getuid());
    if (pw != null and pw.*.pw_shell != null and pw.*.pw_shell[0] != 0) {
        const shell_c = std.mem.span(pw.*.pw_shell);
        const shell = try a.dupe(u8, shell_c);
        const argv = try a.alloc([]const u8, 1);
        argv[0] = shell;
        return .{ .arena = arena, .argv = argv };
    }

    const argv = try a.alloc([]const u8, 1);
    argv[0] = "/bin/sh";
    return .{ .arena = arena, .argv = argv };
}

fn spawnHostDetached(argv0: []const u8, sock_path: []const u8, child_argv: []const []const u8) !void {
    // msr-app is an entrypoint; the persistent host loop lives in the `msr` binary as `_host`.
    // We expect msr-app and msr to be installed next to each other.
    var msr_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const msr_bin = blk: {
        if (std.mem.lastIndexOfScalar(u8, argv0, '/')) |slash| {
            const dir = argv0[0..slash];
            const candidate = std.fmt.bufPrint(&msr_bin_buf, "{s}/msr", .{dir}) catch break :blk "msr";
            break :blk candidate;
        }
        break :blk "msr";
    };

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        _ = c.setsid();

        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const n = 4 + child_argv.len + 1;
        const av = a.alloc(?[*:0]u8, n) catch c._exit(127);

        av[0] = (a.dupeZ(u8, msr_bin) catch c._exit(127)).ptr;
        av[1] = (a.dupeZ(u8, "_host") catch c._exit(127)).ptr;
        av[2] = (a.dupeZ(u8, sock_path) catch c._exit(127)).ptr;
        av[3] = (a.dupeZ(u8, "--") catch c._exit(127)).ptr;
        for (child_argv, 0..) |arg, i| {
            av[4 + i] = (a.dupeZ(u8, arg) catch c._exit(127)).ptr;
        }
        av[n - 1] = null;

        _ = c.execvp(av[0].?, @ptrCast(av.ptr));
        c._exit(127);
    }
}

fn waitForReady(sock_path: []const u8, timeout_ms: u32) bool {
    const step_us: u32 = 10_000;
    const loops = timeout_ms / 10;
    var i: u32 = 0;
    while (i < loops) : (i += 1) {
        const fd = client.connectUnix(sock_path) catch {
            _ = c.usleep(step_us);
            continue;
        };
        _ = c.close(fd);
        return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;

    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer argv.deinit(allocator);

    var args_it = std.process.Args.Iterator.init(init.minimal.args);

    // include argv0 so indexing matches normal conventions
    if (args_it.next()) |arg0_z| {
        try argv.append(allocator, std.mem.sliceTo(arg0_z, 0));
    }

    while (args_it.next()) |arg_z| {
        // Args iterator returns [:0]const u8; we store it as []const u8.
        const arg: []const u8 = std.mem.sliceTo(arg_z, 0);
        try argv.append(allocator, arg);
    }

    if (argv.items.len < 2) {
        usage();
        return 0;
    }

    const raw_cmd = argv.items[1];
    if (std.mem.eql(u8, raw_cmd, "help") or std.mem.eql(u8, raw_cmd, "--help") or std.mem.eql(u8, raw_cmd, "-h")) {
        usage();
        return 0;
    }

    const cmd = parseAlias(raw_cmd);

    const env = try acquireEnv(init, allocator, init.minimal.environ);
    defer freeEnv(allocator, env);

    var ctx = try manager_v2.Context.init(allocator, env.working_dir, env.current_name);
    defer ctx.deinit();

    var rt = session.Runtime.init(allocator);
    defer rt.deinit();

    if (std.mem.eql(u8, cmd, "cwd")) {
        std.debug.print("{s}\n", .{ctx.cwd()});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "current")) {
        if (ctx.current()) |n| {
            std.debug.print("{s}\n", .{n});
            return 0;
        }
        return 1;
    }
    if (std.mem.eql(u8, cmd, "list")) {
        const names = try ctx.list();
        defer {
            for (names) |n| allocator.free(n);
            allocator.free(names);
        }
        for (names) |n| std.debug.print("{s}\n", .{n});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "exists")) {
        if (argv.items.len != 3) return missingArgs("exists: missing <name>");
        const ok = try ctx.exists(&rt, argv.items[2]);
        std.debug.print("{s}\n", .{if (ok) "true" else "false"});
        return if (ok) 0 else 1;
    }
    if (std.mem.eql(u8, cmd, "status")) {
        if (argv.items.len != 3) return missingArgs("status: missing <name>");
        const st = try ctx.status(&rt, argv.items[2]);
        std.debug.print("{s}\n", .{@tagName(st)});
        return if (st == .not_found) 1 else 0;
    }
    if (std.mem.eql(u8, cmd, "create")) {
        // msr-app create <name> -- <cmd...>
        if (argv.items.len < 3) return missingArgs("create: missing <name>");
        const name = argv.items[2];

        var cmd_argv: []const []const u8 = &.{};
        var cmd_arena: ?std.heap.ArenaAllocator = null;
        defer if (cmd_arena) |*a| a.deinit();

        if (argv.items.len >= 4 and std.mem.eql(u8, argv.items[3], "--")) {
            if (argv.items.len >= 5) {
                cmd_argv = argv.items[4..];
            } else {
                // Explicit "--" but no cmd: fall back to default shell.
                var d = try defaultCmd(allocator, init.minimal.environ);
                cmd_arena = d.arena;
                cmd_argv = d.argv;
            }
        } else if (argv.items.len == 3) {
            // No "--" and no cmd: fall back to default shell.
            var d = try defaultCmd(allocator, init.minimal.environ);
            cmd_arena = d.arena;
            cmd_argv = d.argv;
        } else {
            return missingArgs("create: expected '--' before <cmd...> (or omit and default to shell)");
        }

        std.debug.print("msr-app: create {s}\n", .{name});

        // Mirror msr CLI behavior: spawn a detached host process that owns the socket.
        const sock_path = try manager.resolve(allocator, ctx.cwd(), name);
        defer allocator.free(sock_path);
        spawnHostDetached(argv.items[0], sock_path, cmd_argv) catch |e| {
            std.debug.print("msr-app: create failed to spawn host: {s}\n", .{@errorName(e)});
            return 1;
        };
        if (!waitForReady(sock_path, 2000)) {
            std.debug.print("msr-app: create timed out waiting for host\n", .{});
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "terminate")) {
        if (argv.items.len < 3) return missingArgs("terminate: missing <name>");
        if (argv.items.len > 4) return missingArgs("terminate: too many arguments");
        const name = argv.items[2];
        const sig = if (argv.items.len == 4) argv.items[3] else null;
        try ctx.terminate(&rt, name, sig);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "wait")) {
        if (argv.items.len != 3) return missingArgs("wait: missing <name>");
        const st = try ctx.wait(&rt, argv.items[2]);
        if (st.code) |code| {
            std.debug.print("exit_code={d}\n", .{code});
            return @intCast(@min(@as(i32, 255), @max(@as(i32, 0), code)));
        }
        std.debug.print("exit_signal={s}\n", .{st.signal orelse "unknown"});
        return 1;
    }
    if (std.mem.eql(u8, cmd, "attach")) {
        if (argv.items.len != 3) return missingArgs("attach: missing <name>");
        try ctx.attach(argv.items[2], .exclusive, c.STDIN_FILENO, c.STDOUT_FILENO);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "next")) {
        const name = try ctx.next();
        defer allocator.free(name);
        std.debug.print("{s}\n", .{name});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "prev")) {
        const name = try ctx.prev();
        defer allocator.free(name);
        std.debug.print("{s}\n", .{name});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "go-next")) {
        try ctx.goNext();
        return 0;
    }
    if (std.mem.eql(u8, cmd, "go-prev")) {
        try ctx.goPrev();
        return 0;
    }

    usage();
    return 1;
}
