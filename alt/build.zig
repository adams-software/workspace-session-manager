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

    const ptyio_tty_size_mod = b.addModule("ptyio_tty_size", .{
        .root_source_file = b.path("../ptyio/src/tty/tty_size.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const alt_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    alt_root.linkSystemLibrary("util", .{});
    alt_root.addImport("host", host_mod);
    alt_root.addImport("byte_queue", byte_queue_mod);
    alt_root.addImport("fd_stream", fd_stream_mod);
    alt_root.addImport("ptyio_tty_size", ptyio_tty_size_mod);

    const alt_exe = b.addExecutable(.{
        .name = "alt",
        .root_module = alt_root,
    });
    b.installArtifact(alt_exe);

    const run_cmd = b.addRunArtifact(alt_exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the alt executable");
    run_step.dependOn(&run_cmd.step);
}
