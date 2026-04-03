const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const host_mod = b.addModule("host", .{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_mod.linkSystemLibrary("util", .{});
    host_mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    host_mod.addIncludePath(b.path("src"));
    host_mod.addCSourceFile(.{ .file = b.path("src/vterm_shim.c") });
    host_mod.linkSystemLibrary("vterm", .{});

    const protocol_mod = b.addModule("protocol", .{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const client_mod = b.addModule("client", .{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client_mod.linkSystemLibrary("util", .{});
    client_mod.addImport("host", host_mod);
    client_mod.addImport("protocol", protocol_mod);

    const nested_client_mod = b.addModule("nested_client", .{
        .root_source_file = b.path("src/nested_client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nested_client_mod.addImport("client", client_mod);
    nested_client_mod.addImport("protocol", protocol_mod);

    const server_mod = b.addModule("server", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_mod.addImport("host", host_mod);
    server_mod.addImport("protocol", protocol_mod);
    const server_model_mod = b.createModule(.{
        .root_source_file = b.path("src/server_model.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_model_mod.addImport("protocol", protocol_mod);
    server_mod.addImport("server_model", server_model_mod);

    const attach_runtime_mod = b.addModule("attach_runtime", .{
        .root_source_file = b.path("src/attach_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attach_runtime_mod.linkSystemLibrary("util", .{});
    attach_runtime_mod.addImport("client", client_mod);
    attach_runtime_mod.addImport("protocol", protocol_mod);

    const argv_parse_mod = b.addModule("argv_parse", .{
        .root_source_file = b.path("src/argv_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const command_spec_mod = b.addModule("command_spec", .{
        .root_source_file = b.path("src/command_spec.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const cli_parse_mod = b.addModule("cli_parse", .{
        .root_source_file = b.path("src/cli_parse.zig"),
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
    exe_root.addImport("attach_runtime", attach_runtime_mod);
    exe_root.addImport("nested_client", nested_client_mod);
    exe_root.addImport("cli_parse", cli_parse_mod);
    exe_root.addImport("command_spec", command_spec_mod);

    const exe = b.addExecutable(.{
        .name = "msr",
        .root_module = exe_root,
    });
    b.installArtifact(exe);

    const terminal_state_vterm_test_root = b.createModule(.{
        .root_source_file = b.path("src/terminal_state_vterm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    terminal_state_vterm_test_root.addIncludePath(.{ .cwd_relative = "/usr/include" });
    terminal_state_vterm_test_root.addIncludePath(b.path("src"));
    terminal_state_vterm_test_root.addCSourceFile(.{ .file = b.path("src/vterm_shim.c") });
    terminal_state_vterm_test_root.linkSystemLibrary("vterm", .{});
    const terminal_state_vterm_tests = b.addTest(.{
        .root_module = terminal_state_vterm_test_root,
    });

    const host_test_root = b.createModule(.{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_test_root.addIncludePath(.{ .cwd_relative = "/usr/include" });
    host_test_root.addIncludePath(b.path("src"));
    host_test_root.addCSourceFile(.{ .file = b.path("src/vterm_shim.c") });
    host_test_root.linkSystemLibrary("vterm", .{});
    const host_tests = b.addTest(.{
        .root_module = host_test_root,
    });

    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const server_test_root = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
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
        .root_source_file = b.path("src/client.zig"),
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
        .root_source_file = b.path("src/client_integration_test.zig"),
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
        .root_source_file = b.path("src/attach_runtime_logic_test.zig"),
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
        .root_source_file = b.path("src/argv_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const argv_parse_tests = b.addTest(.{
        .root_module = argv_parse_test_root,
    });

    const cli_parse_test_root = b.createModule(.{
        .root_source_file = b.path("src/cli_parse.zig"),
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
        .root_source_file = b.path("src/server_model.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_model_test_root.addImport("protocol", protocol_mod);
    const server_model_tests = b.addTest(.{
        .root_module = server_model_test_root,
    });

    const run_terminal_state_vterm_tests = b.addRunArtifact(terminal_state_vterm_tests);
    const run_host_tests = b.addRunArtifact(host_tests);
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    const run_server_tests = b.addRunArtifact(server_tests);
    const run_client_tests = b.addRunArtifact(client_tests);
    const run_client_integration_tests = b.addRunArtifact(client_integration_tests);
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
    test_step.dependOn(&run_client_integration_tests.step);
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
    test_client_step.dependOn(&run_client_integration_tests.step);

    const test_attach_runtime_logic_step = b.step("test-attach-runtime", "Run attach runtime logic tests");
    test_attach_runtime_logic_step.dependOn(&run_attach_runtime_logic_tests.step);

    const test_server_model_step = b.step("test-server-model", "Run server model transition tests");
    test_server_model_step.dependOn(&run_server_model_tests.step);

    const test_argv_parse_step = b.step("test-argv-parse", "Run generic argv parser tests");
    test_argv_parse_step.dependOn(&run_argv_parse_tests.step);

    const test_cli_parse_step = b.step("test-cli-parse", "Run msr CLI parser tests");
    test_cli_parse_step.dependOn(&run_cli_parse_tests.step);

    const smoke_cmd = b.addSystemCommand(&.{ "python3", "-u", "scripts/smoke_msr_binary.py" });
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
