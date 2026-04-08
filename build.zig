const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const host_mod = b.addModule("host", .{
        .root_source_file = b.path("shared/src/host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_mod.linkSystemLibrary("util", .{});
    host_mod.addImport("terminal_state_vterm", terminal_state_vterm_mod);
    host_mod.addImport("vterm_screen_types", vterm_screen_types_mod);

    const protocol_mod = b.addModule("protocol", .{
        .root_source_file = b.path("msr/src/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const client_mod = b.addModule("client", .{
        .root_source_file = b.path("msr/src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client_mod.linkSystemLibrary("util", .{});
    client_mod.addImport("host", host_mod);
    client_mod.addImport("protocol", protocol_mod);


    const nested_client_mod = b.addModule("nested_client", .{
        .root_source_file = b.path("msr/src/nested_client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nested_client_mod.addImport("client", client_mod);
    nested_client_mod.addImport("protocol", protocol_mod);

    const server_mod = b.addModule("server", .{
        .root_source_file = b.path("msr/src/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_mod.addImport("host", host_mod);
    server_mod.addImport("protocol", protocol_mod);
    const server_model_mod = b.createModule(.{
        .root_source_file = b.path("msr/src/server_model.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_model_mod.addImport("protocol", protocol_mod);
    server_mod.addImport("server_model", server_model_mod);

    const attach_runtime_mod = b.addModule("attach_runtime", .{
        .root_source_file = b.path("msr/src/attach_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attach_runtime_mod.linkSystemLibrary("util", .{});
    attach_runtime_mod.addImport("client", client_mod);
    attach_runtime_mod.addImport("protocol", protocol_mod);

    const argv_parse_mod = b.addModule("argv_parse", .{
        .root_source_file = b.path("msr/src/argv_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });


    const command_spec_mod = b.addModule("command_spec", .{
        .root_source_file = b.path("msr/src/command_spec.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const cli_parse_mod = b.addModule("cli_parse", .{
        .root_source_file = b.path("msr/src/cli_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_parse_mod.addImport("argv_parse", argv_parse_mod);
    cli_parse_mod.addImport("command_spec", command_spec_mod);

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
    exe_root.addImport("attach_runtime", attach_runtime_mod);
    exe_root.addImport("nested_client", nested_client_mod);
    exe_root.addImport("cli_parse", cli_parse_mod);
    exe_root.addImport("command_spec", command_spec_mod);

    const exe = b.addExecutable(.{
        .name = "msr",
        .root_module = exe_root,
    });
    b.installArtifact(exe);

    const vpty_terminal_mod = b.addModule("vpty_terminal", .{
        .root_source_file = b.path("vpty/src/vpty_terminal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const vpty_render_mod = b.addModule("vpty_render", .{
        .root_source_file = b.path("vpty/src/vpty_render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vpty_render_mod.addImport("host", host_mod);

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
    vpty_root.linkSystemLibrary("util", .{});
    vpty_root.addImport("host", host_mod);
    vpty_root.addImport("vpty_terminal", vpty_terminal_mod);
    vpty_root.addImport("vpty_render", vpty_render_mod);
    vpty_root.addImport("side_effects", side_effects);

    const vpty_exe = b.addExecutable(.{
        .name = "vpty",
        .root_module = vpty_root,
    });
    b.installArtifact(vpty_exe);

    const alt_root = b.createModule(.{
        .root_source_file = b.path("alt/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    alt_root.linkSystemLibrary("util", .{});

    const alt_exe = b.addExecutable(.{
        .name = "alt",
        .root_module = alt_root,
    });
    b.installArtifact(alt_exe);

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

    const host_test_root = b.createModule(.{
        .root_source_file = b.path("shared/src/host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_test_root.addImport("terminal_state_vterm", terminal_state_vterm_mod);
    host_test_root.addImport("vterm_screen_types", vterm_screen_types_mod);
    const host_tests = b.addTest(.{
        .root_module = host_test_root,
    });

    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("msr/src/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const server_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_test_root.addImport("host", host_mod);
    server_test_root.addImport("protocol", protocol_mod);
    server_test_root.addImport("server_model", server_model_mod);
    const server_tests = b.addTest(.{
        .root_module = server_test_root,
    });

    const client_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client_test_root.linkSystemLibrary("util", .{});
    client_test_root.addImport("host", host_mod);
    client_test_root.addImport("protocol", protocol_mod);
    const client_tests = b.addTest(.{
        .root_module = client_test_root,
    });

    const client_integration_root = b.createModule(.{
        .root_source_file = b.path("msr/src/client_integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client_integration_root.linkSystemLibrary("util", .{});
    client_integration_root.addImport("client", client_mod);
    client_integration_root.addImport("server", server_mod);
    client_integration_root.addImport("host", host_mod);
    client_integration_root.addImport("protocol", protocol_mod);
    client_integration_root.addImport("attach_runtime", attach_runtime_mod);
    const client_integration_tests = b.addTest(.{
        .root_module = client_integration_root,
    });

    const attach_runtime_logic_root = b.createModule(.{
        .root_source_file = b.path("msr/src/attach_runtime_logic_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attach_runtime_logic_root.linkSystemLibrary("util", .{});
    attach_runtime_logic_root.addImport("client", client_mod);
    attach_runtime_logic_root.addImport("protocol", protocol_mod);
    attach_runtime_logic_root.addImport("attach_runtime", attach_runtime_mod);
    const attach_runtime_logic_tests = b.addTest(.{
        .root_module = attach_runtime_logic_root,
    });

    const argv_parse_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/argv_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const argv_parse_tests = b.addTest(.{
        .root_module = argv_parse_test_root,
    });

    const cli_parse_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/cli_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_parse_test_root.addImport("argv_parse", argv_parse_mod);
    cli_parse_test_root.addImport("command_spec", command_spec_mod);
    const cli_parse_tests = b.addTest(.{
        .root_module = cli_parse_test_root,
    });

    const server_model_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/server_model.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_model_test_root.addImport("protocol", protocol_mod);
    const server_model_tests = b.addTest(.{
        .root_module = server_model_test_root,
    });

        // msr v2 stuff
    const session_core2_mod = b.addModule("session_core2", .{
        .root_source_file = b.path("msr/src/session_core2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const session_wire2_mod = b.addModule("session_wire2", .{
        .root_source_file = b.path("msr/src/session_wire2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_wire2_mod.addImport("session_core2", session_core2_mod);

    const byte_queue_mod = b.addModule("byte_queue", .{
        .root_source_file = b.path("msr/src/byte_queue.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const fd_stream_mod = b.addModule("fd_stream", .{
        .root_source_file = b.path("msr/src/fd_stream.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fd_stream_mod.addImport("byte_queue", byte_queue_mod);

    const session_stream_codec_mod = b.addModule("session_stream_codec", .{
        .root_source_file = b.path("msr/src/session_stream_codec.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_stream_codec_mod.addImport("byte_queue", byte_queue_mod);
    session_stream_codec_mod.addImport("session_core2", session_core2_mod);
    session_stream_codec_mod.addImport("session_wire2", session_wire2_mod);

    const session_stream_transport_mod = b.addModule("session_stream_transport", .{
        .root_source_file = b.path("msr/src/session_stream_transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_stream_transport_mod.addImport("byte_queue", byte_queue_mod);
    session_stream_transport_mod.addImport("fd_stream", fd_stream_mod);
    session_stream_transport_mod.addImport("session_stream_codec", session_stream_codec_mod);
    session_stream_transport_mod.addImport("session_core2", session_core2_mod);
    session_stream_transport_mod.addImport("session_wire2", session_wire2_mod);


    const client2_mod = b.addModule("client2", .{
        .root_source_file = b.path("msr/src/client2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client2_mod.addImport("session_core2", session_core2_mod);
    client2_mod.addImport("session_wire2", session_wire2_mod);
    client2_mod.addImport("session_stream_transport", session_stream_transport_mod);

    const host2_mod = b.addModule("host2", .{
        .root_source_file = b.path("msr/src/host2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host2_mod.linkSystemLibrary("util", .{});
    host2_mod.addImport("terminal_state_vterm", terminal_state_vterm_mod);
    host2_mod.addImport("vterm_screen_types", vterm_screen_types_mod);

    const host2_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/host2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host2_test_root.addImport("terminal_state_vterm", terminal_state_vterm_mod);
    host2_test_root.addImport("vterm_screen_types", vterm_screen_types_mod);

    const host2_tests = b.addTest(.{
        .root_module = host2_test_root,
    });

    const run_host2_tests = b.addRunArtifact(host2_tests);

    const attach_bridge2_mod = b.addModule("attach_bridge2", .{
        .root_source_file = b.path("msr/src/attach_bridge2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attach_bridge2_mod.addImport("byte_queue", byte_queue_mod);
    attach_bridge2_mod.addImport("fd_stream", fd_stream_mod);
    attach_bridge2_mod.addImport("session_core2", session_core2_mod);
    attach_bridge2_mod.addImport("session_wire2", session_wire2_mod);
    attach_bridge2_mod.addImport("client2", client2_mod);
    attach_bridge2_mod.addImport("session_stream_transport", session_stream_transport_mod);

    const session_server2_mod = b.addModule("session_server2", .{
        .root_source_file = b.path("msr/src/session_server2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_server2_mod.addImport("host", host2_mod);
    session_server2_mod.addImport("fd_stream", fd_stream_mod);
    session_server2_mod.addImport("byte_queue", byte_queue_mod);
    session_server2_mod.addImport("session_core2", session_core2_mod);
    session_server2_mod.addImport("session_wire2", session_wire2_mod);
    session_server2_mod.addImport("client2", client2_mod);
    session_server2_mod.addImport("session_stream_transport", session_stream_transport_mod);

    const session_core2_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("msr/src/session_core2.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const session_wire2_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/session_wire2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_wire2_test_root.addImport("session_core2", session_core2_mod);
    const session_wire2_tests = b.addTest(.{
        .root_module = session_wire2_test_root,
    });

    const client2_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/client2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client2_test_root.addImport("session_core2", session_core2_mod);
    client2_test_root.addImport("session_wire2", session_wire2_mod);
    const client2_tests = b.addTest(.{
        .root_module = client2_test_root,
    });

    const attach_bridge2_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/attach_bridge2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attach_bridge2_test_root.addImport("session_core2", session_core2_mod);
    attach_bridge2_test_root.addImport("session_wire2", session_wire2_mod);
    attach_bridge2_test_root.addImport("client2", client2_mod);
    const attach_bridge2_tests = b.addTest(.{
        .root_module = attach_bridge2_test_root,
    });

    const session_server2_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/session_server2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_server2_test_root.addImport("host", host2_mod);
    session_server2_test_root.addImport("session_core2", session_core2_mod);
    session_server2_test_root.addImport("session_wire2", session_wire2_mod);
    session_server2_test_root.addImport("client2", client2_mod);
    const session_server2_tests = b.addTest(.{
        .root_module = session_server2_test_root,
    });

    const client2_integration_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/client2_integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client2_integration_test_root.linkSystemLibrary("util", .{});
    client2_integration_test_root.addImport("host", host2_mod);
    client2_integration_test_root.addImport("session_server2", session_server2_mod);
    client2_integration_test_root.addImport("client2", client2_mod);
    client2_integration_test_root.addImport("attach_bridge2", attach_bridge2_mod);
    client2_integration_test_root.addImport("session_wire2", session_wire2_mod);
    const client2_integration_tests = b.addTest(.{
        .root_module = client2_integration_test_root,
    });

        const byte_queue_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/byte_queue.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const byte_queue_tests = b.addTest(.{
        .root_module = byte_queue_test_root,
    });

    const fd_stream_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/fd_stream.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const fd_stream_tests = b.addTest(.{
        .root_module = fd_stream_test_root,
    });

    const session_stream_codec_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/session_stream_codec.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_stream_codec_test_root.addImport("session_core2", session_core2_mod);
    session_stream_codec_test_root.addImport("session_wire2", session_wire2_mod);
    const session_stream_codec_tests = b.addTest(.{
        .root_module = session_stream_codec_test_root,
    });

    const session_stream_transport_test_root = b.createModule(.{
        .root_source_file = b.path("msr/src/session_stream_transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_stream_transport_test_root.addImport("session_core2", session_core2_mod);
    session_stream_transport_test_root.addImport("session_wire2", session_wire2_mod);
    const session_stream_transport_tests = b.addTest(.{
        .root_module = session_stream_transport_test_root,
    });

    const run_session_core2_tests = b.addRunArtifact(session_core2_tests);
    const run_session_wire2_tests = b.addRunArtifact(session_wire2_tests);
    const run_client2_tests = b.addRunArtifact(client2_tests);
    const run_attach_bridge2_tests = b.addRunArtifact(attach_bridge2_tests);
    const run_session_server2_tests = b.addRunArtifact(session_server2_tests);
    const run_client2_integration_tests = b.addRunArtifact(client2_integration_tests);


    const msr2_root = b.createModule(.{
        .root_source_file = b.path("msr/src/main2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    msr2_root.linkSystemLibrary("util", .{});
    msr2_root.addImport("host", host2_mod);
    msr2_root.addImport("session_server2", session_server2_mod);
    msr2_root.addImport("client2", client2_mod);
    msr2_root.addImport("attach_bridge2", attach_bridge2_mod);
    msr2_root.addImport("cli_parse", cli_parse_mod);
    msr2_root.addImport("command_spec", command_spec_mod);
    msr2_root.addImport("session_stream_transport", session_stream_transport_mod);

    const msr2_exe = b.addExecutable(.{
        .name = "msr2",
        .root_module = msr2_root,
    });
    b.installArtifact(msr2_exe);

    const run_msr2_cmd = b.addRunArtifact(msr2_exe);
    run_msr2_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_msr2_cmd.addArgs(args);

    const run_msr2_step = b.step("run-msr2", "Run the msr2 executable");
    run_msr2_step.dependOn(&run_msr2_cmd.step);

    const test_v2_step = b.step("test-v2", "Run msr v2 tests");

    const run_byte_queue_tests = b.addRunArtifact(byte_queue_tests);
    const run_fd_stream_tests = b.addRunArtifact(fd_stream_tests);
    const run_session_stream_codec_tests = b.addRunArtifact(session_stream_codec_tests);
    const run_session_stream_transport_tests = b.addRunArtifact(session_stream_transport_tests);

    test_v2_step.dependOn(&run_session_core2_tests.step);
    test_v2_step.dependOn(&run_session_wire2_tests.step);
    test_v2_step.dependOn(&run_client2_tests.step);
    test_v2_step.dependOn(&run_attach_bridge2_tests.step);
    test_v2_step.dependOn(&run_session_server2_tests.step);
    test_v2_step.dependOn(&run_client2_integration_tests.step);
    test_v2_step.dependOn(&run_byte_queue_tests.step);
    test_v2_step.dependOn(&run_fd_stream_tests.step);
    test_v2_step.dependOn(&run_session_stream_codec_tests.step);
    test_v2_step.dependOn(&run_session_stream_transport_tests.step);
    test_v2_step.dependOn(&run_host2_tests.step);


    const test_host2_step = b.step("test-host2", "Run host2 module tests");
    test_host2_step.dependOn(&run_host2_tests.step);

    const test_byte_queue_step = b.step("test-byte-queue", "Run byte_queue tests");
    test_byte_queue_step.dependOn(&run_byte_queue_tests.step);

    const test_fd_stream_step = b.step("test-fd-stream", "Run fd_stream tests");
    test_fd_stream_step.dependOn(&run_fd_stream_tests.step);

    const test_session_stream_codec_step = b.step("test-session-stream-codec", "Run session_stream_codec tests");
    test_session_stream_codec_step.dependOn(&run_session_stream_codec_tests.step);

    const test_session_stream_transport_step = b.step("test-session-stream-transport", "Run session_stream_transport tests");
    test_session_stream_transport_step.dependOn(&run_session_stream_transport_tests.step);

    const test_session_core2_step = b.step("test-session-core2", "Run session_core2 tests");
    test_session_core2_step.dependOn(&run_session_core2_tests.step);

    const test_session_wire2_step = b.step("test-session-wire2", "Run session_wire2 tests");
    test_session_wire2_step.dependOn(&run_session_wire2_tests.step);

    const test_client2_step = b.step("test-client2", "Run client2 tests");
    test_client2_step.dependOn(&run_client2_tests.step);

    const test_attach_bridge2_step = b.step("test-attach-bridge2", "Run attach_bridge2 tests");
    test_attach_bridge2_step.dependOn(&run_attach_bridge2_tests.step);

    const test_session_server2_step = b.step("test-session-server2", "Run session_server2 tests");
    test_session_server2_step.dependOn(&run_session_server2_tests.step);

    const test_client2_integration_step = b.step("test-client2-integration", "Run client2 integration tests");
    test_client2_integration_step.dependOn(&run_client2_integration_tests.step);



    const run_terminal_state_vterm_tests = b.addRunArtifact(terminal_state_vterm_tests);
    const run_host_tests = b.addRunArtifact(host_tests);
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    const run_server_tests = b.addRunArtifact(server_tests);
    const run_client_tests = b.addRunArtifact(client_tests);
    _ = client_integration_tests;
    const run_attach_runtime_logic_tests = b.addRunArtifact(attach_runtime_logic_tests);
    const run_server_model_tests = b.addRunArtifact(server_model_tests);
    const run_argv_parse_tests = b.addRunArtifact(argv_parse_tests);
    const run_cli_parse_tests = b.addRunArtifact(cli_parse_tests);

    const test_step = b.step("test", "Run v2 tests");
    test_step.dependOn(&run_terminal_state_vterm_tests.step);
    test_step.dependOn(&run_host_tests.step);
    test_step.dependOn(&run_protocol_tests.step);
    test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_client_tests.step);
    test_step.dependOn(&run_attach_runtime_logic_tests.step);
    test_step.dependOn(&run_server_model_tests.step);
    test_step.dependOn(&run_argv_parse_tests.step);
    test_step.dependOn(&run_cli_parse_tests.step);

    const test_terminal_state_vterm_step = b.step("test-vterm", "Run libvterm adapter tests");
    test_terminal_state_vterm_step.dependOn(&run_terminal_state_vterm_tests.step);

    const test_host_step = b.step("test-host", "Run host module tests");
    test_host_step.dependOn(&run_host_tests.step);

    const test_server_step = b.step("test-server", "Run server module tests");
    test_server_step.dependOn(&run_server_tests.step);

    const test_protocol_step = b.step("test-protocol", "Run protocol module tests");
    test_protocol_step.dependOn(&run_protocol_tests.step);

    const test_client_step = b.step("test-client", "Run client module tests");
    test_client_step.dependOn(&run_client_tests.step);

    const test_attach_runtime_logic_step = b.step("test-attach-runtime", "Run attach runtime logic tests");
    test_attach_runtime_logic_step.dependOn(&run_attach_runtime_logic_tests.step);

    const test_server_model_step = b.step("test-server-model", "Run server model transition tests");
    test_server_model_step.dependOn(&run_server_model_tests.step);

    const test_argv_parse_step = b.step("test-argv-parse", "Run generic argv parser tests");
    test_argv_parse_step.dependOn(&run_argv_parse_tests.step);

    const test_cli_parse_step = b.step("test-cli-parse", "Run msr CLI parser tests");
    test_cli_parse_step.dependOn(&run_cli_parse_tests.step);

    const smoke_cmd = b.addSystemCommand(&.{ "python3", "-u", "msr/scripts/smoke_msr_binary.py" });
    smoke_cmd.setCwd(b.path("."));
    const smoke_step = b.step("smoke-binary", "Run real-binary smoke test for msr");
    smoke_step.dependOn(b.getInstallStep());
    smoke_step.dependOn(&smoke_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the msr executable");
    run_step.dependOn(&run_cmd.step);
}
