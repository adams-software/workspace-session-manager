const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared modules
    const vterm_screen_types_mod = b.addModule("vterm_screen_types", .{
        .root_source_file = b.path("vpty/src/vterm_screen_types.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const terminal_state_vterm_mod = b.addModule("terminal_state_vterm", .{
        .root_source_file = b.path("vpty/src/terminal_state_vterm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    terminal_state_vterm_mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    terminal_state_vterm_mod.addIncludePath(b.path("vpty/src"));
    terminal_state_vterm_mod.addCSourceFile(.{ .file = b.path("vpty/src/vterm_shim.c") });
    terminal_state_vterm_mod.linkSystemLibrary("vterm", .{});
    terminal_state_vterm_mod.addImport("vterm_screen_types", vterm_screen_types_mod);

    const byte_queue_mod = b.addModule("byte_queue", .{
        .root_source_file = b.path("ptyio/src/stream/byte_queue.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const fd_stream_mod = b.addModule("fd_stream", .{
        .root_source_file = b.path("ptyio/src/stream/fd_stream.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fd_stream_mod.addImport("byte_queue", byte_queue_mod);

    const session_core_mod = b.addModule("session_core", .{
        .root_source_file = b.path("msr/src/session_core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const session_wire_mod = b.addModule("session_wire", .{
        .root_source_file = b.path("msr/src/session_wire.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_wire_mod.addImport("session_core", session_core_mod);

    const session_stream_codec_mod = b.addModule("session_stream_codec", .{
        .root_source_file = b.path("msr/src/session_stream_codec.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_stream_codec_mod.addImport("byte_queue", byte_queue_mod);
    session_stream_codec_mod.addImport("session_wire", session_wire_mod);
    session_stream_codec_mod.addImport("session_core", session_core_mod);

    const session_stream_transport_mod = b.addModule("session_stream_transport", .{
        .root_source_file = b.path("msr/src/session_stream_transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_stream_transport_mod.addImport("byte_queue", byte_queue_mod);
    session_stream_transport_mod.addImport("fd_stream", fd_stream_mod);
    session_stream_transport_mod.addImport("session_stream_codec", session_stream_codec_mod);
    session_stream_transport_mod.addImport("session_wire", session_wire_mod);

    const client_mod = b.addModule("client", .{
        .root_source_file = b.path("msr/src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client_mod.addImport("session_core", session_core_mod);
    client_mod.addImport("session_wire", session_wire_mod);
    client_mod.addImport("session_stream_transport", session_stream_transport_mod);

    const host_mod = b.addModule("host", .{
        .root_source_file = b.path("ptyio/src/pty/child_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    host_mod.linkSystemLibrary("util", .{});

    const server_mod = b.addModule("server", .{
        .root_source_file = b.path("msr/src/server.zig"),
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

    const attach_wake_pipe_mod = b.addModule("attach_wake_pipe", .{
        .root_source_file = b.path("vpty/src/wake_pipe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const attach_bridge_mod = b.addModule("attach_bridge", .{
        .root_source_file = b.path("msr/src/attach_bridge.zig"),
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
    attach_bridge_mod.addImport("wake_pipe", attach_wake_pipe_mod);

    const argv_parse_mod = b.addModule("argv_parse", .{
        .root_source_file = b.path("shared/src/cli/argv_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const command_spec_mod = b.addModule("command_spec", .{
        .root_source_file = b.path("msr/src/cli/command_spec.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const cli_parse_mod = b.addModule("cli_parse", .{
        .root_source_file = b.path("msr/src/cli/cli_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_parse_mod.addImport("argv_parse", argv_parse_mod);
    cli_parse_mod.addImport("command_spec", command_spec_mod);

    // msr
    const exe_root = b.createModule(.{
        .root_source_file = b.path("msr/src/main.zig"),
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

    const byte_queue_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("ptyio/src/stream/byte_queue.zig"), .target = target, .optimize = optimize, .link_libc = true,
    }) });
    const fd_stream_test_root = b.createModule(.{
        .root_source_file = b.path("ptyio/src/stream/fd_stream.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    fd_stream_test_root.addImport("byte_queue", byte_queue_mod);
    const fd_stream_tests = b.addTest(.{ .root_module = fd_stream_test_root });
    const session_core_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("msr/src/session_core.zig"), .target = target, .optimize = optimize, .link_libc = true,
    }) });
    const session_wire_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/session_wire.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    session_wire_test_root.addImport("session_core", session_core_mod);
    const session_wire_tests = b.addTest(.{ .root_module = session_wire_test_root });

    const session_stream_codec_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/session_stream_codec.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    session_stream_codec_test_root.addImport("byte_queue", byte_queue_mod);
    session_stream_codec_test_root.addImport("session_wire", session_wire_mod);
    session_stream_codec_test_root.addImport("session_core", session_core_mod);
    const session_stream_codec_tests = b.addTest(.{ .root_module = session_stream_codec_test_root });

    const session_stream_transport_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/session_stream_transport.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    session_stream_transport_test_root.addImport("byte_queue", byte_queue_mod);
    session_stream_transport_test_root.addImport("fd_stream", fd_stream_mod);
    session_stream_transport_test_root.addImport("session_stream_codec", session_stream_codec_mod);
    session_stream_transport_test_root.addImport("session_wire", session_wire_mod);
    const session_stream_transport_tests = b.addTest(.{ .root_module = session_stream_transport_test_root });

    const host_test_root = b.createModule(.{
        .root_source_file = b.path("ptyio/src/pty/child_host.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    const host_tests = b.addTest(.{ .root_module = host_test_root });

    const client_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/client.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    client_test_root.addImport("session_core", session_core_mod);
    client_test_root.addImport("session_wire", session_wire_mod);
    client_test_root.addImport("session_stream_transport", session_stream_transport_mod);
    const client_tests = b.addTest(.{ .root_module = client_test_root });

    const attach_bridge_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/attach_bridge.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    attach_bridge_test_root.addImport("client", client_mod);
    attach_bridge_test_root.addImport("session_core", session_core_mod);
    attach_bridge_test_root.addImport("session_wire", session_wire_mod);
    attach_bridge_test_root.addImport("byte_queue", byte_queue_mod);
    attach_bridge_test_root.addImport("fd_stream", fd_stream_mod);
    attach_bridge_test_root.addImport("session_stream_transport", session_stream_transport_mod);
    attach_bridge_test_root.addImport("wake_pipe", attach_wake_pipe_mod);
    const attach_bridge_tests = b.addTest(.{ .root_module = attach_bridge_test_root });

    const server_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/server.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    server_test_root.addImport("host", host_mod);
    server_test_root.addImport("client", client_mod);
    server_test_root.addImport("byte_queue", byte_queue_mod);
    server_test_root.addImport("fd_stream", fd_stream_mod);
    server_test_root.addImport("session_core", session_core_mod);
    server_test_root.addImport("session_wire", session_wire_mod);
    server_test_root.addImport("session_stream_transport", session_stream_transport_mod);
    const server_tests = b.addTest(.{ .root_module = server_test_root });


    // vpty
    const vpty_terminal_mod = b.addModule("vpty_terminal", .{
        .root_source_file = b.path("vpty/src/vpty_terminal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const session_host_vpty_mod = b.addModule("session_host_vpty", .{
        .root_source_file = b.path("vpty/src/session_host_vpty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_host_vpty_mod.addImport("host", host_mod);
    session_host_vpty_mod.addImport("vterm_screen_types", vterm_screen_types_mod);

    const terminal_model_mod = b.addModule("terminal_model", .{
        .root_source_file = b.path("vpty/src/terminal_model.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    terminal_model_mod.addImport("terminal_state_vterm", terminal_state_vterm_mod);
    terminal_model_mod.addImport("vterm_screen_types", vterm_screen_types_mod);

    const stdout_actor_mod = b.addModule("stdout_actor", .{
        .root_source_file = b.path("vpty/src/stdout_actor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const actor_mailboxes_mod = b.addModule("actor_mailboxes", .{
        .root_source_file = b.path("vpty/src/actor_mailboxes.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    terminal_model_mod.addImport("actor_mailboxes", actor_mailboxes_mod);
    stdout_actor_mod.addImport("actor_mailboxes", actor_mailboxes_mod);

    const wake_pipe_mod = b.addModule("wake_pipe", .{
        .root_source_file = b.path("vpty/src/wake_pipe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const stdout_thread_mod = b.addModule("stdout_thread", .{
        .root_source_file = b.path("vpty/src/stdout_thread.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stdout_thread_mod.addImport("stdout_actor", stdout_actor_mod);
    stdout_thread_mod.addImport("actor_mailboxes", actor_mailboxes_mod);
    stdout_thread_mod.addImport("wake_pipe", wake_pipe_mod);

    const vpty_render_mod = b.addModule("vpty_render", .{
        .root_source_file = b.path("vpty/src/vpty_render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vpty_render_mod.addImport("session_host_vpty", session_host_vpty_mod);
    vpty_render_mod.addImport("stdout_thread", stdout_thread_mod);
    vpty_render_mod.addImport("terminal_model", terminal_model_mod);
    vpty_render_mod.addImport("actor_mailboxes", actor_mailboxes_mod);

    const render_thread_mod = b.addModule("render_thread", .{
        .root_source_file = b.path("vpty/src/render_thread.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    render_thread_mod.addImport("vpty_render", vpty_render_mod);
    render_thread_mod.addImport("terminal_model", terminal_model_mod);
    render_thread_mod.addImport("stdout_thread", stdout_thread_mod);
    render_thread_mod.addImport("actor_mailboxes", actor_mailboxes_mod);
    render_thread_mod.addImport("wake_pipe", wake_pipe_mod);

    const vpty_root = b.createModule(.{
        .root_source_file = b.path("vpty/src/vpty_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const side_effects = b.createModule(.{
        .root_source_file = b.path("vpty/src/side_effects.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    side_effects.addImport("stdout_actor", stdout_actor_mod);
    side_effects.addImport("actor_mailboxes", actor_mailboxes_mod);
    vpty_root.linkSystemLibrary("util", .{});
    vpty_root.addImport("session_host_vpty", session_host_vpty_mod);
    vpty_root.addImport("byte_queue", byte_queue_mod);
    vpty_root.addImport("fd_stream", fd_stream_mod);
    vpty_root.addImport("vpty_terminal", vpty_terminal_mod);
    vpty_root.addImport("vpty_render", vpty_render_mod);
    vpty_root.addImport("render_thread", render_thread_mod);
    vpty_root.addImport("side_effects", side_effects);
    vpty_root.addImport("terminal_model", terminal_model_mod);
    vpty_root.addImport("stdout_actor", stdout_actor_mod);
    vpty_root.addImport("stdout_thread", stdout_thread_mod);
    vpty_root.addImport("actor_mailboxes", actor_mailboxes_mod);
    vpty_root.addImport("wake_pipe", wake_pipe_mod);

    const vpty_exe = b.addExecutable(.{
        .name = "vpty",
        .root_module = vpty_root,
    });
    b.installArtifact(vpty_exe);

    // alt
    const ptyio_tty_size_mod = b.addModule("ptyio_tty_size", .{
        .root_source_file = b.path("ptyio/src/tty/tty_size.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const alt_root = b.createModule(.{
        .root_source_file = b.path("alt/src/main.zig"),
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

    const alt_test_root = b.createModule(.{
        .root_source_file = b.path("alt/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    alt_test_root.linkSystemLibrary("util", .{});
    alt_test_root.addImport("host", host_mod);
    alt_test_root.addImport("byte_queue", byte_queue_mod);
    alt_test_root.addImport("fd_stream", fd_stream_mod);
    alt_test_root.addImport("ptyio_tty_size", ptyio_tty_size_mod);
    const alt_tests = b.addTest(.{ .root_module = alt_test_root });

    const terminal_state_vterm_test_root = b.createModule(.{
        .root_source_file = b.path("vpty/src/terminal_state_vterm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    terminal_state_vterm_test_root.addIncludePath(.{ .cwd_relative = "/usr/include" });
    terminal_state_vterm_test_root.addIncludePath(b.path("vpty/src"));
    terminal_state_vterm_test_root.addCSourceFile(.{ .file = b.path("vpty/src/vterm_shim.c") });
    terminal_state_vterm_test_root.linkSystemLibrary("vterm", .{});
    const terminal_state_vterm_tests = b.addTest(.{
        .root_module = terminal_state_vterm_test_root,
    });

    // Test runners and aliases
    const run_terminal_state_vterm_tests = b.addRunArtifact(terminal_state_vterm_tests);
    const run_alt_tests = b.addRunArtifact(alt_tests);
    const run_byte_queue_tests = b.addRunArtifact(byte_queue_tests);
    const run_fd_stream_tests = b.addRunArtifact(fd_stream_tests);
    const run_session_core_tests = b.addRunArtifact(session_core_tests);
    const run_session_wire_tests = b.addRunArtifact(session_wire_tests);
    const run_session_stream_codec_tests = b.addRunArtifact(session_stream_codec_tests);
    const run_session_stream_transport_tests = b.addRunArtifact(session_stream_transport_tests);
    const run_host_tests = b.addRunArtifact(host_tests);
    const run_client_tests = b.addRunArtifact(client_tests);
    const run_attach_bridge_tests = b.addRunArtifact(attach_bridge_tests);
    const run_server_tests = b.addRunArtifact(server_tests);

    const test_step = b.step("test", "Run msr tests");
    test_step.dependOn(&run_alt_tests.step);
    test_step.dependOn(&run_byte_queue_tests.step);
    test_step.dependOn(&run_fd_stream_tests.step);
    test_step.dependOn(&run_session_core_tests.step);
    test_step.dependOn(&run_session_wire_tests.step);
    test_step.dependOn(&run_session_stream_codec_tests.step);
    test_step.dependOn(&run_session_stream_transport_tests.step);
    test_step.dependOn(&run_host_tests.step);
    test_step.dependOn(&run_client_tests.step);
    test_step.dependOn(&run_attach_bridge_tests.step);
    test_step.dependOn(&run_server_tests.step);

    const test_terminal_state_vterm_step = b.step("test-vterm", "Run libvterm adapter tests");
    test_terminal_state_vterm_step.dependOn(&run_terminal_state_vterm_tests.step);

    const test_alt_step = b.step("test-alt", "Run alt tests");
    test_alt_step.dependOn(&run_alt_tests.step);

    const test_host_step = b.step("test-host", "Run host module tests");
    test_host_step.dependOn(&run_host_tests.step);

    const test_byte_queue_step = b.step("test-byte-queue", "Run byte_queue tests");
    test_byte_queue_step.dependOn(&run_byte_queue_tests.step);

    const test_fd_stream_step = b.step("test-fd-stream", "Run fd_stream tests");
    test_fd_stream_step.dependOn(&run_fd_stream_tests.step);

    const test_session_stream_codec_step = b.step("test-session-stream-codec", "Run session_stream_codec tests");
    test_session_stream_codec_step.dependOn(&run_session_stream_codec_tests.step);

    const test_session_stream_transport_step = b.step("test-session-stream-transport", "Run session_stream_transport tests");
    test_session_stream_transport_step.dependOn(&run_session_stream_transport_tests.step);

    const test_session_core_step = b.step("test-session-core", "Run session_core tests");
    test_session_core_step.dependOn(&run_session_core_tests.step);

    const test_session_wire_step = b.step("test-session-wire", "Run session_wire tests");
    test_session_wire_step.dependOn(&run_session_wire_tests.step);

    const test_client_step = b.step("test-client", "Run client tests");
    test_client_step.dependOn(&run_client_tests.step);

    const test_attach_bridge_step = b.step("test-attach-bridge", "Run attach_bridge tests");
    test_attach_bridge_step.dependOn(&run_attach_bridge_tests.step);

    const test_session_server_step = b.step("test-server", "Run session_server tests");
    test_session_server_step.dependOn(&run_server_tests.step);

    const argv_parse_test_root = b.createModule(.{
        .root_source_file = b.path("shared/src/cli/argv_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const argv_parse_tests = b.addTest(.{ .root_module = argv_parse_test_root });
    const run_argv_parse_tests = b.addRunArtifact(argv_parse_tests);

    const cli_parse_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/cli/cli_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_parse_test_root.addImport("argv_parse", argv_parse_mod);
    cli_parse_test_root.addImport("command_spec", command_spec_mod);
    const cli_parse_tests = b.addTest(.{ .root_module = cli_parse_test_root });
    const run_cli_parse_tests = b.addRunArtifact(cli_parse_tests);

    const test_protocol_step = b.step("test-protocol", "Run session wire tests");
    test_protocol_step.dependOn(&run_session_wire_tests.step);

    const test_attach_runtime_logic_step = b.step("test-attach-runtime", "Run attach bridge tests");
    test_attach_runtime_logic_step.dependOn(&run_attach_bridge_tests.step);

    const test_server_model_step = b.step("test-server-model", "Run session core transition tests");
    test_server_model_step.dependOn(&run_session_core_tests.step);

    const test_argv_parse_step = b.step("test-argv-parse", "Run generic argv parser tests");
    test_argv_parse_step.dependOn(&run_argv_parse_tests.step);

    const test_cli_parse_step = b.step("test-cli-parse", "Run msr CLI parser tests");
    test_cli_parse_step.dependOn(&run_cli_parse_tests.step);

    const smoke_cmd = b.addSystemCommand(&.{ "python3", "-u", "msr/scripts/smoke_msr_binary.py" });
    smoke_cmd.setCwd(b.path("."));
    const smoke_step = b.step("smoke-binary", "Run real-binary smoke test for msr");
    smoke_step.dependOn(b.getInstallStep());
    smoke_step.dependOn(&smoke_cmd.step);

}
