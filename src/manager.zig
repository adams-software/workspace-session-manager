const std = @import("std");
const session = @import("msr");
const client = @import("client");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
});

pub const Error = error{
    InvalidArgs,
    OutOfMemory,
    AccessDenied,
    Canceled,
    SystemResources,
    Unexpected,
} || session.RuntimeError || client.Error;

fn freeControlRes(allocator: std.mem.Allocator, res: *session.rpc.ControlRes) void {
    if (res.signal) |s| allocator.free(@constCast(s));
    if (res.err) |*e| {
        allocator.free(@constCast(e.code));
        if (e.message) |m| allocator.free(@constCast(m));
    }
}

pub fn resolve(allocator: std.mem.Allocator, state_dir: []const u8, name: []const u8) Error![]u8 {
    if (state_dir.len == 0 or name.len == 0) return Error.InvalidArgs;
    return std.fs.path.join(allocator, &.{ state_dir, name }) catch Error.OutOfMemory;
}

pub fn list(allocator: std.mem.Allocator, state_dir: []const u8) Error![][]u8 {
    if (state_dir.len == 0) return Error.InvalidArgs;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var dir = std.Io.Dir.openDirAbsolute(io, state_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return Error.InvalidArgs,
        else => return Error.InvalidArgs,
    };
    defer dir.close(io);

    var out = try std.ArrayList([]u8).initCapacity(allocator, 0);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .unix_domain_socket) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, out.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return out.toOwnedSlice(allocator);
}

pub fn exists(rt: *session.Runtime, allocator: std.mem.Allocator, state_dir: []const u8, name: []const u8) Error!bool {
    const path = try resolve(allocator, state_dir, name);
    defer allocator.free(path);
    return rt.exists(path);
}

pub fn status(rt: *session.Runtime, allocator: std.mem.Allocator, state_dir: []const u8, name: []const u8) Error!session.Status {
    const path = try resolve(allocator, state_dir, name);
    defer allocator.free(path);
    return rt.status(path);
}

pub fn create(rt: *session.Runtime, allocator: std.mem.Allocator, state_dir: []const u8, name: []const u8, opts: session.SpawnOptions) Error!void {
    const path = try resolve(allocator, state_dir, name);
    defer allocator.free(path);
    return rt.create(path, opts);
}

pub fn terminate(rt: *session.Runtime, allocator: std.mem.Allocator, state_dir: []const u8, name: []const u8, signal: ?[]const u8) Error!void {
    _ = rt;
    const path = try resolve(allocator, state_dir, name);
    defer allocator.free(path);

    // Manager is directory-scoped and filesystem-truth. Session lifecycle is owned by the host.
    // Use host-routed RPC for terminate.
    var res = client.rpcCall(allocator, path, .{ .op = "terminate", .path = path, .signal = signal }) catch return Error.ConnectFailed;
    defer freeControlRes(allocator, &res);
    if (!res.ok) {
        // Bubble underlying core error set rather than inventing new mapping.
        return Error.InvalidArgs;
    }
    return;
}

pub fn wait(rt: *session.Runtime, allocator: std.mem.Allocator, state_dir: []const u8, name: []const u8) Error!session.ExitStatus {
    _ = rt;
    const path = try resolve(allocator, state_dir, name);
    defer allocator.free(path);

    // Use host-routed RPC for wait; host owns cleanup and linger semantics.
    var res = client.rpcCall(allocator, path, .{ .op = "wait", .path = path }) catch return Error.ConnectFailed;
    defer freeControlRes(allocator, &res);
    if (!res.ok) return Error.InvalidArgs;
    return .{ .code = res.code, .signal = res.signal };
}

pub fn attach(allocator: std.mem.Allocator, state_dir: []const u8, name: []const u8, mode: session.AttachMode, in_fd: c_int, out_fd: c_int) Error!void {
    const path = try resolve(allocator, state_dir, name);
    defer allocator.free(path);
    return client.attachPath(allocator, path, mode, in_fd, out_fd);
}

test "resolve joins state dir and name" {
    const out = try resolve(std.testing.allocator, "/tmp/sessions", "alpha.sock");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("/tmp/sessions/alpha.sock", out);
}

test "resolve rejects empty args" {
    try std.testing.expectError(Error.InvalidArgs, resolve(std.testing.allocator, "", "a"));
    try std.testing.expectError(Error.InvalidArgs, resolve(std.testing.allocator, "/tmp", ""));
}

test "list returns socket names only" {
    const base = "/tmp/msr-manager-list-test";
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    var addr: std.os.linux.sockaddr.un = undefined;
    _ = &addr;

    const sock_path = try std.fs.path.join(std.testing.allocator, &.{ base, "alpha.sock" });
    defer std.testing.allocator.free(sock_path);
    const txt_path = try std.fs.path.join(std.testing.allocator, &.{ base, "note.txt" });
    defer std.testing.allocator.free(txt_path);

    var sock_addr: c.struct_sockaddr_un = undefined;
    @memset(std.mem.asBytes(&sock_addr), 0);
    sock_addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, sock_addr.sun_path[0..sock_path.len], sock_path);
    sock_addr.sun_path[sock_path.len] = 0;

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.bind(fd, @as(*const c.struct_sockaddr, @ptrCast(&sock_addr)), @intCast(@sizeOf(c.struct_sockaddr_un))));
    try std.testing.expectEqual(@as(c_int, 0), c.listen(fd, 1));
    defer _ = c.close(fd);

    try cwd.writeFile(io, .{ .sub_path = txt_path, .data = "x" });

    const names = try list(std.testing.allocator, base);
    defer {
        for (names) |n| std.testing.allocator.free(n);
        std.testing.allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("alpha.sock", names[0]);
}

test "manager exists/status mirror core" {
    var rt = session.Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const base = "/tmp/msr-manager-status-test";
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    const path = try resolve(std.testing.allocator, base, "beta.sock");
    defer std.testing.allocator.free(path);

    const opts = session.SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "exit 0" } };
    try rt.create(path, opts);
    try std.testing.expectEqual(true, try exists(&rt, std.testing.allocator, base, "beta.sock"));
    try std.testing.expectEqual(session.Status.running, try status(&rt, std.testing.allocator, base, "beta.sock"));
}

test "manager create creates namespaced session" {
    var rt = session.Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const base = "/tmp/msr-manager-create-test";
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    const opts = session.SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } };
    try create(&rt, std.testing.allocator, base, "gamma.sock", opts);
    try std.testing.expectEqual(true, try exists(&rt, std.testing.allocator, base, "gamma.sock"));
    try std.testing.expectEqual(session.Status.running, try status(&rt, std.testing.allocator, base, "gamma.sock"));
}

test "manager terminate and wait mirror core semantics" {
    var rt = session.Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const base = "/tmp/msr-manager-wait-test-2";
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    // Ensure a clean slate even if a prior run crashed before deleting.
    const path = try resolve(std.testing.allocator, base, "delta.sock");
    defer std.testing.allocator.free(path);
    _ = c.unlink(path.ptr);

    const opts = session.SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 5" } };
    try create(&rt, std.testing.allocator, base, "delta.sock", opts);
    try terminate(&rt, std.testing.allocator, base, "delta.sock", "KILL");

    var polled: ?session.ExitStatus = null;
    var i: usize = 0;
    while (i < 200 and polled == null) : (i += 1) {
        polled = try rt.pollExit(path);
        if (polled == null) _ = c.usleep(10_000);
    }

    try std.testing.expectEqual(session.Status.exited_pending_wait, try status(&rt, std.testing.allocator, base, "delta.sock"));
    const waited = try wait(&rt, std.testing.allocator, base, "delta.sock");
    try std.testing.expect(waited.code != null or waited.signal != null);
    try std.testing.expectEqual(false, try exists(&rt, std.testing.allocator, base, "delta.sock"));
}

test "manager attach mirrors core attach delegation" {
    var rt = session.Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const base = "/tmp/msr-manager-attach-test";
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    const opts = session.SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } };
    try create(&rt, std.testing.allocator, base, "attach.sock", opts);

    try std.testing.expectError(client.Error.ConnectFailed, attach(std.testing.allocator, base, "missing.sock", .exclusive, c.STDIN_FILENO, c.STDOUT_FILENO));
}
