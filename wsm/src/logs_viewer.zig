const std = @import("std");

pub fn run(logs_viewer_bin: []const u8, log_path: []const u8) !u8 {
    const argv = [_][]const u8{ logs_viewer_bin, log_path };
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
}
