const std = @import("std");
const policy = @import("policy.zig");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

pub const SessionPaths = struct {
    id: []u8,
    data_path: []u8,
    control_path: []u8,

    pub fn deinit(self: SessionPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.data_path);
        allocator.free(self.control_path);
    }
};

pub const CreateSpec = struct {
    id: []const u8,
    shell: []const u8,
    vpty_bin: []const u8,
    ptylog_bin: []const u8,
    cols: ?u16 = null,
    rows: ?u16 = null,
};

pub fn pathsForId(allocator: std.mem.Allocator, provider: *policy.Provider, id: []const u8) !SessionPaths {
    try provider.validateCreateId(id);
    const data_path = try provider.socketPathForId(id);
    errdefer allocator.free(data_path);
    const control_path = try controlPathForDataPath(allocator, data_path);
    errdefer allocator.free(control_path);
    return .{
        .id = try allocator.dupe(u8, id),
        .data_path = data_path,
        .control_path = control_path,
    };
}

pub fn controlPathForDataPath(allocator: std.mem.Allocator, data_path: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, data_path, ".wsm")) return error.InvalidPath;
    return try std.fmt.allocPrint(allocator, "{s}.ctl", .{data_path[0 .. data_path.len - 4]});
}

pub fn createSession(allocator: std.mem.Allocator, host_bin: []const u8, provider: *policy.Provider, spec: CreateSpec) !SessionPaths {
    var paths = try pathsForId(allocator, provider, spec.id);
    errdefer paths.deinit(allocator);

    if (pathExists(paths.data_path) or pathExists(paths.control_path)) return error.SessionAlreadyExists;

    if (std.fs.path.dirname(paths.data_path)) |dir| std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);
    const size_arg = if (spec.cols != null and spec.rows != null)
        try std.fmt.allocPrint(allocator, "{d}x{d}", .{ spec.cols.?, spec.rows.? })
    else
        null;
    defer if (size_arg) |arg| allocator.free(arg);
    const transcript_path = try std.fmt.allocPrint(allocator, "{s}.typescript", .{paths.data_path[0 .. paths.data_path.len - 4]});
    defer allocator.free(transcript_path);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{paths.data_path[0 .. paths.data_path.len - 4]});
    defer allocator.free(log_path);
    const inner_cmd = try std.fmt.allocPrint(allocator, "WSM_SESSION_ID={s} exec {s} -i", .{ spec.id, spec.shell });
    defer allocator.free(inner_cmd);

    try appendDetachedHostPrefix(allocator, &argv, host_bin);
    try argv.appendSlice(allocator, &.{
        paths.control_path,
        "--headless",
        "--",
        host_bin,
        paths.data_path,
    });
    if (size_arg) |arg| try argv.appendSlice(allocator, &.{ "--size", arg });
    try argv.appendSlice(allocator, &.{
        "--",
        spec.vpty_bin,
        "--",
        spec.ptylog_bin,
        "--transcript",
        transcript_path,
        "--log",
        log_path,
        "--",
        "/bin/bash",
        "-lc",
        inner_cmd,
    });

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    // Detached sessions must not keep the launching terminal as a live stderr
    // dependency; otherwise SSH hangups can still tear down the runtime.
    child.stderr_behavior = .Ignore;
    // Keep a separate process group even when setsid is unavailable.
    child.pgid = 0;
    try child.spawn();
    try waitSocketPathExists(paths.data_path, 2000);
    try waitSocketPathExists(paths.control_path, 2000);

    return paths;
}


fn waitSocketPathExists(path: []const u8, timeout_ms: u64) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (pathExists(path)) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.SessionNotReady;
}

fn appendDetachedHostPrefix(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), host_bin: []const u8) !void {
    const setsid_candidates = [_][]const u8{
        "/usr/bin/setsid",
        "/bin/setsid",
    };

    for (setsid_candidates) |candidate| {
        std.fs.accessAbsolute(candidate, .{}) catch continue;
        try argv.appendSlice(allocator, &.{ candidate, host_bin });
        return;
    }

    try argv.append(allocator, host_bin);
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
