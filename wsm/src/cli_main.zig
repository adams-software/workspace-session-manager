const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
});
const global_io = std.Io.Threaded.global_single_threaded.io();
const policy = @import("policy.zig");
const service_mod = @import("service.zig");
const argv_parse = @import("argv_parse");

pub const ToolPaths = struct {
    host_bin: []u8,
    vpty_bin: []u8,
    ptylog_bin: []u8,
    logs_viewer_bin: []u8,

    pub fn deinit(self: ToolPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.host_bin);
        allocator.free(self.vpty_bin);
        allocator.free(self.ptylog_bin);
        allocator.free(self.logs_viewer_bin);
    }
};

pub fn resolveToolPaths(allocator: std.mem.Allocator) !ToolPaths {
    const exe_path = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(exe_path);
    const exe_len = c.readlink("/proc/self/exe", exe_path.ptr, exe_path.len);
    if (exe_len < 0) return error.FileNotFound;
    const exe_path_slice = exe_path[0..@intCast(exe_len)];
    const exe_dir_owned = try allocator.dupe(u8, std.fs.path.dirname(exe_path_slice) orelse ".");
    defer allocator.free(exe_dir_owned);
    const exe_dir = exe_dir_owned;
    const exe_parent = std.fs.path.dirname(exe_dir) orelse exe_dir;

    const private_host = try std.fs.path.join(allocator, &.{ exe_parent, "libexec", "wsm", "host" });
    defer allocator.free(private_host);
    const private_vpty = try std.fs.path.join(allocator, &.{ exe_parent, "libexec", "wsm", "vpty" });
    defer allocator.free(private_vpty);
    const private_ptylog = try std.fs.path.join(allocator, &.{ exe_parent, "libexec", "wsm", "ptylog" });
    defer allocator.free(private_ptylog);
    const private_logs = try std.fs.path.join(allocator, &.{ exe_parent, "libexec", "wsm", "wsm_logs_viewer" });
    defer allocator.free(private_logs);
    const sibling_host = try std.fs.path.join(allocator, &.{ exe_dir, "host" });
    defer allocator.free(sibling_host);
    const sibling_vpty = try std.fs.path.join(allocator, &.{ exe_dir, "vpty" });
    defer allocator.free(sibling_vpty);
    const sibling_ptylog = try std.fs.path.join(allocator, &.{ exe_dir, "ptylog" });
    defer allocator.free(sibling_ptylog);
    const sibling_logs = try std.fs.path.join(allocator, &.{ exe_dir, "wsm_logs_viewer" });
    defer allocator.free(sibling_logs);

    return .{
        .host_bin = try resolveToolPath(allocator, "WSM_HOST_BIN", &.{ private_host, sibling_host, "zig-out/bin/host" }),
        .vpty_bin = try resolveToolPath(allocator, "WSM_VPTY_BIN", &.{ private_vpty, sibling_vpty, "zig-out/bin/vpty" }),
        .ptylog_bin = try resolveToolPath(allocator, "WSM_PTYLOG_BIN", &.{ private_ptylog, sibling_ptylog, "zig-out/bin/ptylog" }),
        .logs_viewer_bin = try resolveToolPath(allocator, "WSM_LOGS_VIEWER_BIN", &.{ private_logs, sibling_logs, "wsm/scripts/wsm_logs_viewer" }),
    };
}

fn resolveToolPath(allocator: std.mem.Allocator, env_name: []const u8, candidates: []const []const u8) ![]u8 {
    const env_name_z = try allocator.dupeZ(u8, env_name);
    defer allocator.free(env_name_z);
    if (std.c.getenv(env_name_z.ptr)) |override| return try allocator.dupe(u8, std.mem.span(override));

    for (candidates) |candidate| {
        if (candidate.len == 0) continue;
        const candidate_z = try allocator.dupeZ(u8, candidate);
        defer allocator.free(candidate_z);
        if (c.access(candidate_z.ptr, c.X_OK) != 0) continue;
        return try allocator.dupe(u8, candidate);
    }
    return try allocator.dupe(u8, candidates[candidates.len - 1]);
}

pub const Mode = union(enum) {
    help,
    interactive_attach: []const u8,
    interactive_create_attach: []const u8,
    create_detached: []const u8,
    create_detached_alias: []const u8,
    list,
    inspect: []const u8,
    log: ?[]const u8,
    cleanup: bool,
    kill: struct { id: []const u8, force: bool },

    pub fn deinit(self: Mode, allocator: std.mem.Allocator) void {
        switch (self) {
            .interactive_attach => |id| allocator.free(id),
            .interactive_create_attach => |id| allocator.free(id),
            .create_detached => |id| allocator.free(id),
            .create_detached_alias => |id| allocator.free(id),
            .inspect => |id| allocator.free(id),
            .log => |maybe_id| if (maybe_id) |id| allocator.free(id),
            .kill => |args| allocator.free(args.id),
            else => {},
        }
    }
};

pub fn parseMode(allocator: std.mem.Allocator, argv: []const []const u8) !Mode {
    const parsed = try argv_parse.parseArgv(allocator, argv);
    defer allocator.free(parsed.options);
    defer allocator.free(parsed.positionals);
    defer if (parsed.literal_tail) |tail| allocator.free(tail);

    const command = parsed.command orelse return .help;
    if (std.mem.eql(u8, command, "help")) return .help;
    if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "ls")) return .list;
    if (std.mem.eql(u8, command, "log") or std.mem.eql(u8, command, "g")) {
        if (parsed.positionals.len >= 1) return .{ .log = try allocator.dupe(u8, parsed.positionals[0]) };
        return .{ .log = null };
    }
    if (std.mem.eql(u8, command, "cleanup")) return .{ .cleanup = argv_parse.hasOption(parsed, &.{"apply"}) };
    if (std.mem.eql(u8, command, "kill") or std.mem.eql(u8, command, "x")) {
        if (parsed.positionals.len < 1) return .help;
        return .{ .kill = .{ .id = try allocator.dupe(u8, parsed.positionals[0]), .force = argv_parse.hasOption(parsed, &.{ "f", "force" }) } };
    }
    if (std.mem.eql(u8, command, "inspect")) {
        if (parsed.positionals.len < 1) return .help;
        return .{ .inspect = try allocator.dupe(u8, parsed.positionals[0]) };
    }
    if (std.mem.eql(u8, command, "attach") or std.mem.eql(u8, command, "a")) {
        if (parsed.positionals.len < 1) return .help;
        return .{ .interactive_attach = try allocator.dupe(u8, parsed.positionals[0]) };
    }
    if (std.mem.eql(u8, command, "cd")) {
        if (parsed.positionals.len < 1) return .help;
        return .{ .create_detached_alias = try allocator.dupe(u8, parsed.positionals[0]) };
    }
    if (std.mem.eql(u8, command, "create") or std.mem.eql(u8, command, "c")) {
        if (parsed.positionals.len < 1) return .help;
        if (argv_parse.hasOption(parsed, &.{ "d", "detached" })) {
            return .{ .create_detached = try allocator.dupe(u8, parsed.positionals[0]) };
        }
        return .{ .interactive_create_attach = try allocator.dupe(u8, parsed.positionals[0]) };
    }
    return .help;
}

pub fn printHelp(allocator: std.mem.Allocator, writer: anytype, workspace_root: ?[]const u8, current_session: ?[]const u8) !void {
    try writer.writeAll(
        "wsm - workspace session manager\n\n" ++
            "USAGE\n" ++
            "  wsm <command> [args]\n\n" ++
            "COMMANDS\n" ++
            "  help                      Show help\n" ++
            "  create | c <id>           Create and attach\n" ++
            "  create -d <id>            Create detached\n" ++
            "  cd <id>                   Create detached (alias)\n" ++
            "  attach | a <id>           Attach interactively\n" ++
            "  list | ls                 List sessions\n" ++
            "  inspect <id>              Inspect one session\n" ++
            "  log | g [id]              View log for a session\n" ++
            "  cleanup                   Dry-run stale socket cleanup\n" ++
            "  cleanup --apply           Apply stale socket cleanup\n" ++
            "  kill | x <id>             Send TERM to session child\n" ++
            "  kill | x -f <id>          Send KILL to session child\n\n" ++
            "NOTES\n" ++
            "  Status-bar letters map to CLI aliases where that makes sense: a/c/g/x.\n" ++
            "  The bar's [d]etach action is UI-local and does not have a top-level CLI alias.\n\n" ++
            "GLOBAL OPTIONS\n" ++
            "  --workspace <path>        Workspace root (fallback: WSM_ROOT)\n\n",
    );

    if (workspace_root) |root| {
        const line = try std.fmt.allocPrint(allocator, "WORKSPACE: {s}\n", .{root});
        defer allocator.free(line);
        try writer.writeAll(line);
    }
    if (current_session) |session| {
        const line = try std.fmt.allocPrint(allocator, "SESSION:   {s}\n", .{session});
        defer allocator.free(line);
        try writer.writeAll(line);
    }
}

pub fn resolveWorkspace(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const parsed = try argv_parse.parseArgv(allocator, argv);
    defer allocator.free(parsed.options);
    defer allocator.free(parsed.positionals);
    defer if (parsed.literal_tail) |tail| allocator.free(tail);
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    if (argv_parse.findOptionValue(parsed, &.{"workspace"})) |v| {
        const n = try std.Io.Dir.realPathFile(.cwd(), io, v, &buf);
        return try allocator.dupe(u8, buf[0..n]);
    }
    const env_root = std.c.getenv("WSM_ROOT") orelse return error.MissingWorkspace;
    const n = try std.Io.Dir.realPathFile(.cwd(), io, std.mem.span(env_root), &buf);
    return try allocator.dupe(u8, buf[0..n]);
}

fn presentSummary(allocator: std.mem.Allocator, info: service_mod.SessionInfo) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    if (info.data_path_exists) try parts.append(allocator, "data");
    if (info.control_path_exists) try parts.append(allocator, "ctl");
    std.Io.Dir.accessAbsolute(global_io, info.log_path, .{}) catch {
        return try std.mem.join(allocator, ",", parts.items);
    };
    try parts.append(allocator, "log");
    return try std.mem.join(allocator, ",", parts.items);
}

pub fn runCommand(allocator: std.mem.Allocator, root: []const u8, mode: Mode, writer: anytype) !u8 {
    var provider = try policy.Provider.init(allocator, root, null);
    defer provider.deinit();
    const tool_paths = try resolveToolPaths(allocator);
    defer tool_paths.deinit(allocator);
    var service = service_mod.WorkspaceService.init(allocator, tool_paths.host_bin, tool_paths.vpty_bin, tool_paths.ptylog_bin);

    switch (mode) {
        .help => {
            try printHelp(allocator, writer, root, if (std.c.getenv("WSM_SESSION_ID")) |value| std.mem.span(value) else null);
            return 0;
        },
        .list => {
            const ids = try service.listSessionIds(&provider);
            defer {
                for (ids) |id| allocator.free(id);
                allocator.free(ids);
            }
            for (ids) |id| {
                const line = try std.fmt.allocPrint(allocator, "{s}\n", .{id});
                defer allocator.free(line);
                try writer.writeAll(line);
            }
            return 0;
        },
        .inspect => |id| {
            const info = try service.sessionInfo(&provider, id);
            defer info.deinit(allocator);
            const health = try service.health(&provider, id);
            const present = try presentSummary(allocator, info);
            defer allocator.free(present);
            const health_label = switch (health) {
                .missing_data => "not_found",
                else => @tagName(health),
            };
            const header = try std.fmt.allocPrint(allocator, "{s:<20} {s:<20} {s}\n", .{ "SESSION", "HEALTH", "PRESENT" });
            defer allocator.free(header);
            try writer.writeAll(header);
            const line = try std.fmt.allocPrint(allocator, "{s:<20} {s:<20} {s}\n", .{ info.session.id, health_label, if (present.len == 0) "-" else present });
            defer allocator.free(line);
            try writer.writeAll(line);
            return 0;
        },
        .log => |maybe_id| {
            const session_id = maybe_id orelse if (std.c.getenv("WSM_SESSION_ID")) |value| std.mem.span(value) else null orelse {
                try writer.writeAll("log failed: session id required (pass an id or run from inside a session)\n");
                return 1;
            };
            const log_path = try service.logPath(&provider, session_id);
            defer allocator.free(log_path);
            std.Io.Dir.accessAbsolute(global_io, log_path, .{}) catch {
                const msg = try std.fmt.allocPrint(allocator, "log failed for {s}: log not found\n", .{session_id});
                defer allocator.free(msg);
                try writer.writeAll(msg);
                return 1;
            };

            const argv = [_][]const u8{ tool_paths.logs_viewer_bin, log_path };
            var spawn_runtime = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer spawn_runtime.deinit();
            const spawn_io = spawn_runtime.io();
            var child = try std.process.spawn(spawn_io, .{
                .argv = &argv,
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            });
            defer child.kill(spawn_io);
            const term = try child.wait(spawn_io);
            return switch (term) {
                .exited => |code| code,
                .signal => 128,
                else => 1,
            };
        },
        .cleanup => |apply| {
            const header = try std.fmt.allocPrint(allocator, "{s:<20} {s:<20} {s:<14} {s}\n", .{ "SESSION", "HEALTH", "PRESENT", "ACTION" });
            defer allocator.free(header);
            try writer.writeAll(header);

            if (apply) {
                const summary = try service.cleanupReport(&provider);
                defer summary.deinit(allocator);
                for (summary.entries) |entry| {
                    const present = try presentSummary(allocator, entry.info);
                    defer allocator.free(present);
                    const apply_result = service.applyCleanupEntry(entry);
                    defer apply_result.deinit(allocator);
                    const action = if (entry.cleanup == .remove) "removed" else "kept";
                    const line = try std.fmt.allocPrint(allocator, "{s:<20} {s:<20} {s:<14} {s}\n", .{ entry.info.session.id, @tagName(entry.health), present, action });
                    defer allocator.free(line);
                    try writer.writeAll(line);
                }
            } else {
                const summary = try service.cleanupReport(&provider);
                defer summary.deinit(allocator);
                for (summary.entries) |entry| {
                    const present = try presentSummary(allocator, entry.info);
                    defer allocator.free(present);
                    const line = try std.fmt.allocPrint(allocator, "{s:<20} {s:<20} {s:<14} {s}\n", .{ entry.info.session.id, @tagName(entry.health), present, @tagName(entry.cleanup) });
                    defer allocator.free(line);
                    try writer.writeAll(line);
                }
            }
            return 0;
        },
        .create_detached, .create_detached_alias => |id| {
            const shell = if (std.c.getenv("SHELL")) |value| std.mem.span(value) else "/bin/sh";
            const session = try service.create(&provider, id, shell, null, null);
            defer session.deinit(allocator);
            const line = try std.fmt.allocPrint(allocator, "created {s}\n", .{session.id});
            defer allocator.free(line);
            try writer.writeAll(line);
            return 0;
        },
        .kill => |args| {
            service.killSession(&provider, args.id, if (args.force) .kill else .term) catch |err| {
                const msg = switch (err) {
                    error.NoControl => try std.fmt.allocPrint(allocator, "kill failed for {s}: session has no control socket\n", .{args.id}),
                    else => try std.fmt.allocPrint(allocator, "kill failed for {s}: {s}\n", .{ args.id, @errorName(err) }),
                };
                defer allocator.free(msg);
                try writer.writeAll(msg);
                return 1;
            };
            const line = try std.fmt.allocPrint(allocator, "signaled {s} ({s})\n", .{ args.id, if (args.force) "KILL" else "TERM" });
            defer allocator.free(line);
            try writer.writeAll(line);
            return 0;
        },
        .interactive_attach, .interactive_create_attach => return 2,
    }
}

test "parseMode accepts attach alias" {
    const argv = [_][]const u8{ "a", "demo" };
    const mode = try parseMode(std.testing.allocator, &argv);
    defer mode.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("demo", mode.interactive_attach);
}

test "parseMode accepts ls alias for list" {
    const argv = [_][]const u8{ "ls" };
    const mode = try parseMode(std.testing.allocator, &argv);
    defer mode.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.list, mode);
}

test "parseMode accepts detached create alias" {
    const argv = [_][]const u8{ "cd", "demo" };
    const mode = try parseMode(std.testing.allocator, &argv);
    defer mode.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("demo", mode.create_detached_alias);
}
