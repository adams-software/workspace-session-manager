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

    const session_core_mod = b.addModule("session_core", .{
        .root_source_file = b.path("src/session_core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const session_wire_mod = b.addModule("session_wire", .{
        .root_source_file = b.path("src/session_wire.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_wire_mod.addImport("session_core", session_core_mod);

    const session_stream_codec_mod = b.addModule("session_stream_codec", .{
        .root_source_file = b.path("src/session_stream_codec.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_stream_codec_mod.addImport("byte_queue", byte_queue_mod);
    session_stream_codec_mod.addImport("session_wire", session_wire_mod);
    session_stream_codec_mod.addImport("session_core", session_core_mod);

    const session_stream_transport_mod = b.addModule("session_stream_transport", .{
        .root_source_file = b.path("src/session_stream_transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_stream_transport_mod.addImport("byte_queue", byte_queue_mod);
    session_stream_transport_mod.addImport("fd_stream", fd_stream_mod);
    session_stream_transport_mod.addImport("session_stream_codec", session_stream_codec_mod);
    session_stream_transport_mod.addImport("session_wire", session_wire_mod);

    const client_mod = b.addModule("client", .{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client_mod.addImport("session_core", session_core_mod);
    client_mod.addImport("session_wire", session_wire_mod);
    client_mod.addImport("session_stream_transport", session_stream_transport_mod);

    const server_mod = b.addModule("server", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_mod.addImport("host", host_mod);
    server_mod.addImport("client", client_mod);
    server_mod.addImport("byte_queue", byte_queue_mod);
    server_mod.addImport("fd_stream", fd_stream_mod);
    server_mod.addImport("session_core", session_core_mod);
    server_mod.addImport("session_wire", session_wire_mod);
    server_mod.addImport("session_stream_transport", session_stream_transport_mod);

    const wake_pipe_mod = b.addModule("wake_pipe", .{
        .root_source_file = b.path("../vpty/src/wake_pipe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const attach_bridge_mod = b.addModule("attach_bridge", .{
        .root_source_file = b.path("src/attach_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attach_bridge_mod.addImport("client", client_mod);
    attach_bridge_mod.addImport("session_core", session_core_mod);
    attach_bridge_mod.addImport("session_wire", session_wire_mod);
    attach_bridge_mod.addImport("byte_queue", byte_queue_mod);
    attach_bridge_mod.addImport("fd_stream", fd_stream_mod);
    attach_bridge_mod.addImport("session_stream_transport", session_stream_transport_mod);
    attach_bridge_mod.addImport("wake_pipe", wake_pipe_mod);

    const argv_parse_mod = b.addModule("argv_parse", .{
        .root_source_file = b.path("../shared/src/cli/argv_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const command_spec_mod = b.addModule("command_spec", .{
        .root_source_file = b.path("../msr/src/cli/command_spec.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const cli_parse_mod = b.addModule("cli_parse", .{
        .root_source_file = b.path("../msr/src/cli/cli_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_parse_mod.addImport("argv_parse", argv_parse_mod);
    cli_parse_mod.addImport("command_spec", command_spec_mod);

    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_root.linkSystemLibrary("util", .{});
    exe_root.addImport("client", client_mod);
    exe_root.addImport("host", host_mod);
    exe_root.addImport("server", server_mod);
    exe_root.addImport("attach_bridge", attach_bridge_mod);
    exe_root.addImport("cli_parse", cli_parse_mod);
    exe_root.addImport("command_spec", command_spec_mod);

    const exe = b.addExecutable(.{
        .name = "msr",
        .root_module = exe_root,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the msr executable");
    run_step.dependOn(&run_cmd.step);
}
