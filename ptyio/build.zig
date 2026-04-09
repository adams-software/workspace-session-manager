const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.addModule("ptyio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const byte_queue_test_root = b.createModule(.{
        .root_source_file = b.path("src/stream/byte_queue.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const byte_queue_tests = b.addTest(.{ .root_module = byte_queue_test_root });

    const fd_stream_test_root = b.createModule(.{
        .root_source_file = b.path("src/stream/fd_stream.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fd_stream_test_root.addImport("byte_queue", b.addModule("byte_queue", .{
        .root_source_file = b.path("src/stream/byte_queue.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    const fd_stream_tests = b.addTest(.{ .root_module = fd_stream_test_root });

    const raw_mode_test_root = b.createModule(.{
        .root_source_file = b.path("src/tty/raw_mode.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const raw_mode_tests = b.addTest(.{ .root_module = raw_mode_test_root });

    const tty_size_test_root = b.createModule(.{
        .root_source_file = b.path("src/tty/tty_size.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const tty_size_tests = b.addTest(.{ .root_module = tty_size_test_root });

    const child_host_test_root = b.createModule(.{
        .root_source_file = b.path("src/pty/child_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const child_host_tests = b.addTest(.{ .root_module = child_host_test_root });

    const run_byte_queue_tests = b.addRunArtifact(byte_queue_tests);
    const run_fd_stream_tests = b.addRunArtifact(fd_stream_tests);
    const run_raw_mode_tests = b.addRunArtifact(raw_mode_tests);
    const run_tty_size_tests = b.addRunArtifact(tty_size_tests);
    const run_child_host_tests = b.addRunArtifact(child_host_tests);

    const test_step = b.step("test", "Run ptyio tests");
    test_step.dependOn(&run_byte_queue_tests.step);
    test_step.dependOn(&run_fd_stream_tests.step);
    test_step.dependOn(&run_raw_mode_tests.step);
    test_step.dependOn(&run_tty_size_tests.step);
    test_step.dependOn(&run_child_host_tests.step);

    _ = root_mod;
}
