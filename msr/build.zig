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

    const ptyio_tty_size_mod = b.addModule("ptyio_tty_size", .{
        .root_source_file = b.path("../ptyio/src/tty/tty_size.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const host_mod = b.addModule("host", .{
        .root_source_file = b.path("../ptyio/src/pty/child_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_mod.linkSystemLibrary("util", .{});

    const ctlwire_mod = b.addModule("ctlwire", .{
        .root_source_file = b.path("../ctlwire/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const host_runtime_mod = b.addModule("host_runtime", .{
        .root_source_file = b.path("src/host_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const host_control_mod = b.addModule("host_control", .{
        .root_source_file = b.path("src/host_control.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_control_mod.addImport("host_runtime", host_runtime_mod);

    const host_client_mod = b.addModule("host_client", .{
        .root_source_file = b.path("src/host_client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_client_mod.addImport("host_control", host_control_mod);
    host_client_mod.addImport("host_runtime", host_runtime_mod);

    const host_repl_mod = b.addModule("host_repl", .{
        .root_source_file = b.path("src/host_repl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_repl_mod.addImport("host_control", host_control_mod);
    host_repl_mod.addImport("host_runtime", host_runtime_mod);
    host_repl_mod.addImport("fd_stream", fd_stream_mod);
    host_repl_mod.addImport("ctlwire", ctlwire_mod);

    const server_mod = b.addModule("server", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_mod.addImport("host", host_mod);
    server_mod.addImport("host_runtime", host_runtime_mod);
    server_mod.addImport("byte_queue", byte_queue_mod);
    server_mod.addImport("fd_stream", fd_stream_mod);

    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_root.linkSystemLibrary("util", .{});
    exe_root.addImport("host", host_mod);
    exe_root.addImport("host_runtime", host_runtime_mod);
    exe_root.addImport("host_control", host_control_mod);
    exe_root.addImport("host_repl", host_repl_mod);
    exe_root.addImport("server", server_mod);
    exe_root.addImport("ptyio_tty_size", ptyio_tty_size_mod);

    const exe = b.addExecutable(.{
        .name = "msr",
        .root_module = exe_root,
    });
    b.installArtifact(exe);

    const host_exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_exe_root.linkSystemLibrary("util", .{});
    host_exe_root.addImport("host", host_mod);
    host_exe_root.addImport("host_runtime", host_runtime_mod);
    host_exe_root.addImport("host_control", host_control_mod);
    host_exe_root.addImport("host_repl", host_repl_mod);
    host_exe_root.addImport("server", server_mod);
    host_exe_root.addImport("ptyio_tty_size", ptyio_tty_size_mod);

    const host_exe = b.addExecutable(.{
        .name = "host",
        .root_module = host_exe_root,
    });
    b.installArtifact(host_exe);

    const host_runtime_tests = b.addTest(.{ .root_module = host_runtime_mod });
    const run_host_runtime_tests = b.addRunArtifact(host_runtime_tests);

    const host_control_tests = b.addTest(.{ .root_module = host_control_mod });
    const run_host_control_tests = b.addRunArtifact(host_control_tests);

    const host_client_tests = b.addTest(.{ .root_module = host_client_mod });
    const run_host_client_tests = b.addRunArtifact(host_client_tests);

    const run_cmd = b.addRunArtifact(host_exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the host executable");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run host runtime unit tests");
    test_step.dependOn(&run_host_runtime_tests.step);
    test_step.dependOn(&run_host_control_tests.step);
    test_step.dependOn(&run_host_client_tests.step);
}
