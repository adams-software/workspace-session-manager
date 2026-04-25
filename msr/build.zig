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

    const host_mod = b.addModule("host", .{
        .root_source_file = b.path("../ptyio/src/pty/child_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_mod.linkSystemLibrary("util", .{});

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

    const host_repl_mod = b.addModule("host_repl", .{
        .root_source_file = b.path("src/host_repl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_repl_mod.addImport("host_control", host_control_mod);
    host_repl_mod.addImport("host_runtime", host_runtime_mod);

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

    const exe = b.addExecutable(.{
        .name = "msr",
        .root_module = exe_root,
    });
    b.installArtifact(exe);

    const raw_mode_mod = b.addModule("ptyio_raw_mode", .{
        .root_source_file = b.path("../ptyio/src/tty/raw_mode.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const attach_root = b.createModule(.{
        .root_source_file = b.path("src/attach_raw.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attach_root.addImport("byte_queue", byte_queue_mod);
    attach_root.addImport("fd_stream", fd_stream_mod);
    attach_root.addImport("ptyio_raw_mode", raw_mode_mod);

    const attach_exe = b.addExecutable(.{
        .name = "msr-attach",
        .root_module = attach_root,
    });
    b.installArtifact(attach_exe);

    const host_runtime_tests = b.addTest(.{ .root_module = host_runtime_mod });
    const run_host_runtime_tests = b.addRunArtifact(host_runtime_tests);

    const host_control_tests = b.addTest(.{ .root_module = host_control_mod });
    const run_host_control_tests = b.addRunArtifact(host_control_tests);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the msr executable");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run msr unit tests");
    test_step.dependOn(&run_host_runtime_tests.step);
    test_step.dependOn(&run_host_control_tests.step);
}
