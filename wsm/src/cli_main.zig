const std = @import("std");
const policy = @import("policy.zig");
const service_mod = @import("service.zig");
const argv_parse = @import("argv_parse");

pub const ToolPaths = struct {
    host_bin: []u8,
    vpty_bin: []u8,
    logs_viewer_bin: []u8,

    pub fn deinit(self: ToolPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.host_bin);
        allocator.free(self.vpty_bin);
        allocator.free(self.logs_viewer_bin);
    }
};

pub fn resolveToolPaths(allocator: std.mem.Allocator) !ToolPaths {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
    const exe_parent = std.fs.path.dirname(exe_dir) orelse exe_dir;

    const private_host = try std.fs.path.join(allocator, &.{ exe_parent, "libexec", "wsm", "host" });
    defer allocator.free(private_host);
    const private_vpty = try std.fs.path.join(allocator, &.{ exe_parent, "libexec", "wsm", "vpty" });
    defer allocator.free(private_vpty);
    const private_logs = try std.fs.path.join(allocator, &.{ exe_parent, "libexec", "wsm", "wsm_logs_viewer" });
    defer allocator.free(private_logs);
    const sibling_host = try std.fs.path.join(allocator, &.{ exe_dir, "host" });
    defer allocator.free(sibling_host);
    const sibling_vpty = try std.fs.path.join(allocator, &.{ exe_dir, "vpty" });
    defer allocator.free(sibling_vpty);
    const sibling_logs = try std.fs.path.join(allocator, &.{ exe_dir, "wsm_logs_viewer" });
    defer allocator.free(sibling_logs);

    return .{
        .host_bin = try resolveToolPath(allocator, "WSM_HOST_BIN", &.{ private_host, sibling_host, "zig-out/bin/host" }),
        .vpty_bin = try resolveToolPath(allocator, "WSM_VPTY_BIN", &.{ private_vpty, sibling_vpty, "zig-out/bin/vpty" }),
        .logs_viewer_bin = try resolveToolPath(allocator, "WSM_LOGS_VIEWER_BIN", &.{ private_logs, sibling_logs, "wsm/scripts/wsm_logs_viewer" }),
    };
}

fn resolveToolPath(allocator: std.mem.Allocator, env_name: []const u8, candidates: []const []const u8) ![]u8 {
    if (std.posix.getenv(env_name)) |override| return try allocator.dupe(u8, override);

    for (candidates) |candidate| {
        if (candidate.len == 0) continue;
        if (std.fs.path.isAbsolute(candidate)) {
            std.fs.accessAbsolute(candidate, .{}) catch continue;
        } else {
            std.fs.cwd().access(candidate, .{}) catch continue;
        }
        return try allocator.dupe(u8, candidate);
    }
    return try allocator.dupe(u8, candidates[candidates.len - 1]);
}

pub const Mode = union(enum) {
    help,
    interactive_attach: []const u8,
    interactive_create_attach: []const u8,
    create_detached: []const u8,
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
    if (std.mem.eql(u8, command, "list")) return .list;
    if (std.mem.eql(u8, command, "log")) {
        if (parsed.positionals.len >= 1) return .{ .log = try allocator.dupe(u8, parsed.positionals[0]) };
        return .{ .log = null };
    }
    if (std.mem.eql(u8, command, "cleanup")) return .{ .cleanup = argv_parse.hasOption(parsed, &.{"apply"}) };
    if (std.mem.eql(u8, command, "kill")) {
        if (parsed.positionals.len < 1) return .help;
        return .{ .kill = .{ .id = try allocator.dupe(u8, parsed.positionals[0]), .force = argv_parse.hasOption(parsed, &.{ "f", "force" }) } };
    }
    if (std.mem.eql(u8, command, "inspect")) {
        if (parsed.positionals.len < 1) return .help;
        return .{ .inspect = try allocator.dupe(u8, parsed.positionals[0]) };
    }
    if (std.mem.eql(u8, command, "attach")) {
        if (parsed.positionals.len < 1) return .help;
        return .{ .interactive_attach = try allocator.dupe(u8, parsed.positionals[0]) };
    }
    if (std.mem.eql(u8, command, "create")) {
        if (parsed.positionals.len < 1) return .help;
        if (argv_parse.hasOption(parsed, &.{ "d", "detached" })) {
            return .{ .create_detached = try allocator.dupe(u8, parsed.positionals[0]) };
        }
        return .{ .interactive_create_attach = try allocator.dupe(u8, parsed.positionals[0]) };
    }
    return .help;
}

pub fn printHelp(allocator: std.mem.Allocator, file: std.fs.File, workspace_root: ?[]const u8, current_session: ?[]const u8) !void {
    try file.writeAll(
        "wsm - workspace session manager\n\n" ++
            "USAGE\n" ++
            "  wsm <command> [args]\n\n" ++
            "COMMANDS\n" ++
            "  help                      Show help\n" ++
            "  create <id>               Create and attach\n" ++
            "  create -d <id>            Create detached\n" ++
            "  attach <id>               Attach interactively\n" ++
            "  list                      List sessions\n" ++
            "  inspect <id>              Inspect one session\n" ++
            "  log [id]                  View transcript for a session\n" ++
            "  cleanup                   Dry-run stale socket cleanup\n" ++
            "  cleanup --apply           Apply stale socket cleanup\n" ++
            "  kill <id>                 Send TERM to session child\n" ++
            "  kill -f <id>              Send KILL to session child\n\n" ++
            "GLOBAL OPTIONS\n" ++
            "  --workspace <path>        Workspace root (fallback: WSM_ROOT)\n\n",
    );

    if (workspace_root) |root| {
        const line = try std.fmt.allocPrint(allocator, "WORKSPACE: {s}\n", .{root});
        defer allocator.free(line);
        try file.writeAll(line);
    }
    if (current_session) |session| {
        const line = try std.fmt.allocPrint(allocator, "SESSION:   {s}\n", .{session});
        defer allocator.free(line);
        try file.writeAll(line);
    }
}

pub fn resolveWorkspace(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const parsed = try argv_parse.parseArgv(allocator, argv);
    defer allocator.free(parsed.options);
    defer allocator.free(parsed.positionals);
    defer if (parsed.literal_tail) |tail| allocator.free(tail);

    if (argv_parse.findOptionValue(parsed, &.{"workspace"})) |v| {
        return try std.fs.realpathAlloc(allocator, v);
    }
    const env_root = std.posix.getenv("WSM_ROOT") orelse return error.MissingWorkspace;
    return try std.fs.realpathAlloc(allocator, env_root);
}

fn presentSummary(allocator: std.mem.Allocator, info: service_mod.SessionInfo) ![]u8 {
    var parts = std.ArrayList([]const u8){};
    defer parts.deinit(allocator);
    if (info.data_path_exists) try parts.append(allocator, "data");
    if (info.control_path_exists) try parts.append(allocator, "ctl");
    std.fs.accessAbsolute(info.transcript_path, .{}) catch {
        return try std.mem.join(allocator, ",", parts.items);
    };
    try parts.append(allocator, "log");
    return try std.mem.join(allocator, ",", parts.items);
}

pub fn runCommand(allocator: std.mem.Allocator, root: []const u8, mode: Mode, stdout_file: std.fs.File) !u8 {
    var provider = try policy.Provider.init(allocator, root, null);
    defer provider.deinit();
    const tool_paths = try resolveToolPaths(allocator);
    defer tool_paths.deinit(allocator);
    var service = service_mod.WorkspaceService.init(allocator, tool_paths.host_bin, tool_paths.vpty_bin);

    switch (mode) {
        .help => {
            try printHelp(allocator, stdout_file, root, std.posix.getenv("WSM_SESSION_ID"));
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
                try stdout_file.writeAll(line);
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
            try stdout_file.writeAll(header);
            const line = try std.fmt.allocPrint(allocator, "{s:<20} {s:<20} {s}\n", .{ info.session.id, health_label, if (present.len == 0) "-" else present });
            defer allocator.free(line);
            try stdout_file.writeAll(line);
            return 0;
        },
        .log => |maybe_id| {
            const session_id = maybe_id orelse std.posix.getenv("WSM_SESSION_ID") orelse {
                try stdout_file.writeAll("log failed: session id required (pass an id or run from inside a session)\n");
                return 1;
            };
            const transcript = try service.transcriptPath(&provider, session_id);
            defer allocator.free(transcript);
            std.fs.accessAbsolute(transcript, .{}) catch {
                const msg = try std.fmt.allocPrint(allocator, "log failed for {s}: transcript not found\n", .{session_id});
                defer allocator.free(msg);
                try stdout_file.writeAll(msg);
                return 1;
            };

            const argv = [_][]const u8{ tool_paths.logs_viewer_bin, transcript };
            var child = std.process.Child.init(&argv, allocator);
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
            const term = try child.spawnAndWait();
            return switch (term) {
                .Exited => |code| code,
                .Signal => 128,
                else => 1,
            };
        },
        .cleanup => |apply| {
            const header = try std.fmt.allocPrint(allocator, "{s:<20} {s:<20} {s:<14} {s}\n", .{ "SESSION", "HEALTH", "PRESENT", "ACTION" });
            defer allocator.free(header);
            try stdout_file.writeAll(header);

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
                    try stdout_file.writeAll(line);
                }
            } else {
                const summary = try service.cleanupReport(&provider);
                defer summary.deinit(allocator);
                for (summary.entries) |entry| {
                    const present = try presentSummary(allocator, entry.info);
                    defer allocator.free(present);
                    const line = try std.fmt.allocPrint(allocator, "{s:<20} {s:<20} {s:<14} {s}\n", .{ entry.info.session.id, @tagName(entry.health), present, @tagName(entry.cleanup) });
                    defer allocator.free(line);
                    try stdout_file.writeAll(line);
                }
            }
            return 0;
        },
        .create_detached => |id| {
            const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
            const session = try service.create(&provider, id, shell, null, null);
            defer session.deinit(allocator);
            const line = try std.fmt.allocPrint(allocator, "created {s}\n", .{session.id});
            defer allocator.free(line);
            try stdout_file.writeAll(line);
            return 0;
        },
        .kill => |args| {
            service.killSession(&provider, args.id, if (args.force) .kill else .term) catch |err| {
                const msg = switch (err) {
                    error.NoControl => try std.fmt.allocPrint(allocator, "kill failed for {s}: session has no control socket\n", .{args.id}),
                    else => try std.fmt.allocPrint(allocator, "kill failed for {s}: {s}\n", .{ args.id, @errorName(err) }),
                };
                defer allocator.free(msg);
                try stdout_file.writeAll(msg);
                return 1;
            };
            const line = try std.fmt.allocPrint(allocator, "signaled {s} ({s})\n", .{ args.id, if (args.force) "KILL" else "TERM" });
            defer allocator.free(line);
            try stdout_file.writeAll(line);
            return 0;
        },
        .interactive_attach, .interactive_create_attach => return 2,
    }
}
