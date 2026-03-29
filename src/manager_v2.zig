const std = @import("std");
const manager = @import("manager");
const session = @import("msr");
const c = @cImport({
    @cInclude("unistd.h");
});

pub const Error = manager.Error;

fn lessName(_: void, a: []u8, b: []u8) bool {
    const a_num = std.fmt.parseInt(u64, a, 10) catch null;
    const b_num = std.fmt.parseInt(u64, b, 10) catch null;
    if (a_num != null and b_num != null) return a_num.? < b_num.?;
    return std.mem.order(u8, a, b) == .lt;
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    working_dir: []u8,
    current_session: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, working_dir: []const u8, current_session: ?[]const u8) Error!Context {
        if (working_dir.len == 0) return Error.InvalidArgs;
        return .{
            .allocator = allocator,
            .working_dir = try allocator.dupe(u8, working_dir),
            .current_session = if (current_session) |name| try allocator.dupe(u8, name) else null,
        };
    }

    pub fn deinit(self: *Context) void {
        self.allocator.free(self.working_dir);
        if (self.current_session) |name| self.allocator.free(name);
    }

    pub fn cwd(self: *const Context) []const u8 {
        return self.working_dir;
    }

    pub fn current(self: *const Context) ?[]const u8 {
        return self.current_session;
    }

    pub fn list(self: *const Context) Error![][]u8 {
        return manager.list(self.allocator, self.working_dir);
    }

    pub fn exists(self: *const Context, rt: *session.Runtime, name: []const u8) Error!bool {
        return manager.exists(rt, self.allocator, self.working_dir, name);
    }

    pub fn status(self: *const Context, rt: *session.Runtime, name: []const u8) Error!session.Status {
        return manager.status(rt, self.allocator, self.working_dir, name);
    }

    pub fn create(self: *const Context, rt: *session.Runtime, name: []const u8, opts: session.SpawnOptions) Error!void {
        return manager.create(rt, self.allocator, self.working_dir, name, opts);
    }

    pub fn attach(self: *const Context, name: []const u8, mode: session.AttachMode, in_fd: c_int, out_fd: c_int) Error!void {
        return manager.attach(self.allocator, self.working_dir, name, mode, in_fd, out_fd);
    }

    pub fn terminate(self: *const Context, rt: *session.Runtime, name: []const u8, signal: ?[]const u8) Error!void {
        return manager.terminate(rt, self.allocator, self.working_dir, name, signal);
    }

    pub fn wait(self: *const Context, rt: *session.Runtime, name: []const u8) Error!session.ExitStatus {
        return manager.wait(rt, self.allocator, self.working_dir, name);
    }

    fn sortedNames(self: *const Context) Error![][]u8 {
        const names = try manager.list(self.allocator, self.working_dir);
        std.mem.sort([]u8, names, {}, lessName);
        return names;
    }

    pub fn next(self: *const Context) Error![]u8 {
        const current_name = self.current_session orelse return Error.InvalidArgs;
        const names = try self.sortedNames();
        defer {
            for (names) |n| self.allocator.free(n);
            self.allocator.free(names);
        }

        var idx_opt: ?usize = null;
        for (names, 0..) |n, i| {
            if (std.mem.eql(u8, n, current_name)) {
                idx_opt = i;
                break;
            }
        }
        const idx = idx_opt orelse return Error.InvalidArgs;
        const next_idx = if (idx + 1 < names.len) idx + 1 else 0;
        return self.allocator.dupe(u8, names[next_idx]);
    }

    pub fn prev(self: *const Context) Error![]u8 {
        const current_name = self.current_session orelse return Error.InvalidArgs;
        const names = try self.sortedNames();
        defer {
            for (names) |n| self.allocator.free(n);
            self.allocator.free(names);
        }

        var idx_opt: ?usize = null;
        for (names, 0..) |n, i| {
            if (std.mem.eql(u8, n, current_name)) {
                idx_opt = i;
                break;
            }
        }
        const idx = idx_opt orelse return Error.InvalidArgs;
        const prev_idx = if (idx == 0) names.len - 1 else idx - 1;
        return self.allocator.dupe(u8, names[prev_idx]);
    }

    pub fn goNext(self: *const Context) Error!void {
        const name = try self.next();
        defer self.allocator.free(name);
        return self.attach(name, .takeover, c.STDIN_FILENO, c.STDOUT_FILENO);
    }

    pub fn goPrev(self: *const Context) Error!void {
        const name = try self.prev();
        defer self.allocator.free(name);
        return self.attach(name, .takeover, c.STDIN_FILENO, c.STDOUT_FILENO);
    }
};

test "context init exposes cwd/current" {
    var ctx = try Context.init(std.testing.allocator, "/tmp/sessions", "alpha.sock");
    defer ctx.deinit();

    try std.testing.expectEqualStrings("/tmp/sessions", ctx.cwd());
    try std.testing.expect(ctx.current() != null);
    try std.testing.expectEqualStrings("alpha.sock", ctx.current().?);
}

test "context with null current session" {
    var ctx = try Context.init(std.testing.allocator, "/tmp/sessions", null);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("/tmp/sessions", ctx.cwd());
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.current());
}

test "context lifts manager operations" {
    var rt = session.Runtime.init(std.testing.allocator);
    defer rt.deinit();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const base = "/tmp/msr-manager-v2-test";
    cwd.createDirPath(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    var ctx = try Context.init(std.testing.allocator, base, null);
    defer ctx.deinit();

    const opts = session.SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } };
    try ctx.create(&rt, "0", opts);
    try std.testing.expectEqual(true, try ctx.exists(&rt, "0"));
    try std.testing.expectEqual(session.Status.running, try ctx.status(&rt, "0"));
}

test "next/prev use local sorted sibling order" {
    var rt = session.Runtime.init(std.testing.allocator);
    defer rt.deinit();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const base = "/tmp/msr-manager-v2-next-prev-test";
    cwd.createDirPath(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    const opts = session.SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } };
    var seed = try Context.init(std.testing.allocator, base, null);
    defer seed.deinit();
    try seed.create(&rt, "10", opts);
    try seed.create(&rt, "2", opts);
    try seed.create(&rt, "a", opts);

    var ctx = try Context.init(std.testing.allocator, base, "2");
    defer ctx.deinit();

    const next_name = try ctx.next();
    defer std.testing.allocator.free(next_name);
    try std.testing.expectEqualStrings("10", next_name);

    const prev_name = try ctx.prev();
    defer std.testing.allocator.free(prev_name);
    try std.testing.expectEqualStrings("a", prev_name);
}

test "flow: create -> terminate -> wait -> status not_found" {
    var rt = session.Runtime.init(std.testing.allocator);
    defer rt.deinit();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const base = "/tmp/msr-manager-v2-flow-test";
    cwd.createDirPath(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    var ctx = try Context.init(std.testing.allocator, base, null);
    defer ctx.deinit();

    const opts = session.SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 5" } };
    try ctx.create(&rt, "t1", opts);
    try std.testing.expectEqual(session.Status.running, try ctx.status(&rt, "t1"));

    const path = try manager.resolve(std.testing.allocator, base, "t1");
    defer std.testing.allocator.free(path);
    try rt.terminate(path, "KILL");
    _ = try rt.wait(path);

    try std.testing.expectEqual(session.Status.not_found, try rt.status(path));
    try std.testing.expectEqual(false, try rt.exists(path));
}
