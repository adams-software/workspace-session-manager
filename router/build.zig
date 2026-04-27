const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const byte_queue_mod = b.addModule("byte_queue", .{
        .root_source_file = b.path("../ptyio/src/stream/byte_queue.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const fd_stream_mod = b.addModule("fd_stream", .{
        .root_source_file = b.path("../ptyio/src/stream/fd_stream.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fd_stream_mod.addImport("byte_queue", byte_queue_mod);

    const raw_mode_mod = b.addModule("ptyio_raw_mode", .{
        .root_source_file = b.path("../ptyio/src/tty/raw_mode.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const tty_size_mod = b.addModule("ptyio_tty_size", .{
        .root_source_file = b.path("../ptyio/src/tty/tty_size.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const host_runtime_mod = b.addModule("host_runtime", .{
        .root_source_file = b.path("../msr/src/host_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const host_control_mod = b.addModule("host_control", .{
        .root_source_file = b.path("../msr/src/host_control.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_control_mod.addImport("host_runtime", host_runtime_mod);

    const host_client_mod = b.addModule("host_client", .{
        .root_source_file = b.path("../msr/src/host_client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_client_mod.addImport("host_control", host_control_mod);
    host_client_mod.addImport("host_runtime", host_runtime_mod);

    const router_runtime_mod = b.addModule("router_runtime", .{
        .root_source_file = b.path("src/router_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const router_control_mod = b.addModule("router_control", .{
        .root_source_file = b.path("src/router_control.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    router_control_mod.addImport("router_runtime", router_runtime_mod);

    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_root.linkSystemLibrary("util", .{});
    exe_root.addImport("router_runtime", router_runtime_mod);
    exe_root.addImport("router_control", router_control_mod);
    exe_root.addImport("byte_queue", byte_queue_mod);
    exe_root.addImport("fd_stream", fd_stream_mod);
    exe_root.addImport("ptyio_raw_mode", raw_mode_mod);
    exe_root.addImport("ptyio_tty_size", tty_size_mod);
    exe_root.addImport("host_client", host_client_mod);
    exe_root.addImport("host_runtime", host_runtime_mod);

    const exe = b.addExecutable(.{
        .name = "router",
        .root_module = exe_root,
    });
    b.installArtifact(exe);

    const router_runtime_tests = b.addTest(.{ .root_module = router_runtime_mod });
    const run_router_runtime_tests = b.addRunArtifact(router_runtime_tests);

    const router_control_tests = b.addTest(.{ .root_module = router_control_mod });
    const run_router_control_tests = b.addRunArtifact(router_control_tests);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the router executable");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run router unit tests");
    test_step.dependOn(&run_router_runtime_tests.step);
    test_step.dependOn(&run_router_control_tests.step);
}
