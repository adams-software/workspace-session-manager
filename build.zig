const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addModule("msr", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib.linkSystemLibrary("util", .{});

    const host_mod = b.addModule("host", .{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_mod.linkSystemLibrary("util", .{});

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

    const server_mod = b.addModule("server", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_mod.addImport("host", host_mod);
    server_mod.addImport("protocol", protocol_mod);

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

    const exe = b.addExecutable(.{
        .name = "msr",
        .root_module = exe_root,
    });
    b.installArtifact(exe);

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib_tests.root_module.linkSystemLibrary("util", .{});

    const host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
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
    const client_integration_tests = b.addTest(.{
        .root_module = client_integration_root,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const run_host_tests = b.addRunArtifact(host_tests);
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    const run_server_tests = b.addRunArtifact(server_tests);
    const run_client_tests = b.addRunArtifact(client_tests);
    const run_client_integration_tests = b.addRunArtifact(client_integration_tests);

    const test_step = b.step("test", "Run v2 tests");
    test_step.dependOn(&run_host_tests.step);
    test_step.dependOn(&run_protocol_tests.step);
    test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_client_tests.step);
    test_step.dependOn(&run_client_integration_tests.step);

    const test_legacy_runtime_step = b.step("test-legacy-runtime", "Run legacy lib/runtime tests");
    test_legacy_runtime_step.dependOn(&run_lib_tests.step);

    const test_host_step = b.step("test-host", "Run host module tests");
    test_host_step.dependOn(&run_host_tests.step);

    const test_server_step = b.step("test-server", "Run server module tests");
    test_server_step.dependOn(&run_server_tests.step);

    const test_protocol_step = b.step("test-protocol", "Run protocol module tests");
    test_protocol_step.dependOn(&run_protocol_tests.step);

    const test_client_step = b.step("test-client", "Run client module tests");
    test_client_step.dependOn(&run_client_tests.step);
    test_client_step.dependOn(&run_client_integration_tests.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the msr executable");
    run_step.dependOn(&run_cmd.step);
}
