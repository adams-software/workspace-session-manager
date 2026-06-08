const std = @import("std");
const global_io = std.Io.Threaded.global_single_threaded.io();
const policy = @import("policy.zig");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("time.h");
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

    if (std.fs.path.dirname(paths.data_path)) |dir| std.Io.Dir.createDirAbsolute(global_io, dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    const size_arg = if (spec.cols != null and spec.rows != null)
        try std.fmt.allocPrint(allocator, "{d}x{d}", .{ spec.cols.?, spec.rows.? })
    else
        null;
    defer if (size_arg) |arg| allocator.free(arg);
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
        "--log",
        log_path,
        "--",
        "/bin/bash",
        "-lc",
        inner_cmd,
    });

    var spawn_runtime = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer spawn_runtime.deinit();
    const spawn_io = spawn_runtime.io();

    var child = try std.process.spawn(spawn_io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        // Detached sessions must not keep the launching terminal as a live stderr
        // dependency; otherwise SSH hangups can still tear down the runtime.
        .stderr = .ignore,
        // Keep a separate process group even when setsid is unavailable.
        .pgid = 0,
    });
    _ = &child;
    try waitSocketPathExists(paths.data_path, 2000);
    try waitSocketPathExists(paths.control_path, 2000);

    return paths;
}


fn waitSocketPathExists(path: []const u8, timeout_ms: u64) !void {
    const deadline = monotonicMs() + timeout_ms;
    while (monotonicMs() < deadline) {
        if (pathExists(path)) return;
        _ = c.usleep(20_000);
    }
    return error.SessionNotReady;
}

fn monotonicMs() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ms_per_s + @as(u64, @intCast(@divTrunc(ts.tv_nsec, std.time.ns_per_ms)));
}

fn appendDetachedHostPrefix(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), host_bin: []const u8) !void {
    const setsid_candidates = [_][]const u8{
        "/usr/bin/setsid",
        "/bin/setsid",
    };

    for (setsid_candidates) |candidate| {
        std.Io.Dir.accessAbsolute(global_io, candidate, .{}) catch continue;
        try argv.appendSlice(allocator, &.{ candidate, host_bin });
        return;
    }

    try argv.append(allocator, host_bin);
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(global_io, path, .{}) catch return false;
    return true;
}
