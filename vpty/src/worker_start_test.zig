const std = @import("std");
const StdoutThread = @import("stdout_thread").StdoutThread;
const render = @import("render_thread");
const TerminalModel = @import("terminal_model").TerminalModel;

var active_fds: *const [2]c_int = undefined;
var spawned_fds: [2]c_int = undefined;
var spawn_calls: usize = 0;

// This override is linked only into this test executable. Exercise the real
// worker start methods without relying on OS thread limits or resource pressure.
export fn pthread_create(
    _: *std.c.pthread_t,
    _: ?*const std.c.pthread_attr_t,
    _: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    _: ?*anyopaque,
) std.c.E {
    spawned_fds = active_fds.*;
    spawn_calls += 1;
    return .AGAIN;
}

fn expectStartupCleanup(worker: anytype) !void {
    active_fds = &worker.wake_pipe.fds;
    for (0..32) |_| {
        const calls_before = spawn_calls;
        try std.testing.expectError(error.SystemResources, worker.start());
        try std.testing.expectEqual(calls_before + 1, spawn_calls);
        try std.testing.expect(worker.thread == null);
        for (spawned_fds) |fd| {
            try std.testing.expect(fd >= 0);
            try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(fd, std.c.F.GETFD));
            try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(-1));
        }
        try std.testing.expectEqual([2]c_int{ -1, -1 }, worker.wake_pipe.fds);
    }
}

test "stdout worker closes wake pipe when thread creation fails" {
    var worker = StdoutThread.init(std.testing.allocator, {});
    defer worker.deinit();
    try expectStartupCleanup(&worker);
}

test "render worker closes wake pipe when thread creation fails" {
    var stdout_worker = StdoutThread.init(std.testing.allocator, {});
    defer stdout_worker.deinit();
    var model = render.SharedTerminalModel.init({}, try TerminalModel.init(24, 80));
    defer model.model.deinit();
    var worker = render.RenderThread.init(std.testing.allocator, &model, &stdout_worker, .{
        .origin_row = 1,
        .origin_col = 1,
        .rows = 24,
        .cols = 80,
    });
    defer worker.deinit();
    try expectStartupCleanup(&worker);
}
