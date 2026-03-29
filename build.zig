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

    const client_mod = b.addModule("client", .{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client_mod.linkSystemLibrary("util", .{});
    client_mod.addImport("msr", lib);

    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_root.linkSystemLibrary("util", .{});
    exe_root.addImport("client", client_mod);

    const manager_mod = b.addModule("manager", .{
        .root_source_file = b.path("src/manager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    manager_mod.linkSystemLibrary("util", .{});
    manager_mod.addImport("msr", lib);
    manager_mod.addImport("client", client_mod);

    const manager_v2_mod = b.addModule("manager_v2", .{
        .root_source_file = b.path("src/manager_v2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    manager_v2_mod.linkSystemLibrary("util", .{});
    manager_v2_mod.addImport("msr", lib);
    manager_v2_mod.addImport("manager", manager_mod);

    const app_exe_root = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_exe_root.addImport("msr", lib);
    app_exe_root.addImport("client", client_mod);
    app_exe_root.addImport("manager", manager_mod);
    app_exe_root.addImport("manager_v2", manager_v2_mod);

    const app_exe = b.addExecutable(.{
        .name = "msr-app",
        .root_module = app_exe_root,
    });
    b.installArtifact(app_exe);

    const exe = b.addExecutable(.{
        .name = "msr",
        .root_module = exe_root,
    });
    exe.root_module.addImport("msr", lib);
    b.installArtifact(exe);

    const test_root = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_root.linkSystemLibrary("util", .{});

    const lib_tests = b.addTest(.{
        .root_module = test_root,
    });

    const rpc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rpc.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const client_test_root = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client_test_root.linkSystemLibrary("util", .{});
    client_test_root.addImport("msr", lib);

    const client_tests = b.addTest(.{
        .root_module = client_test_root,
    });

    const nav_test_root = b.createModule(.{
        .root_source_file = b.path("src/nav.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const nav_tests = b.addTest(.{
        .root_module = nav_test_root,
    });

    const manager_test_root = b.createModule(.{
        .root_source_file = b.path("src/manager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    manager_test_root.linkSystemLibrary("util", .{});
    manager_test_root.addImport("msr", lib);
    manager_test_root.addImport("client", client_mod);
    manager_test_root.addImport("manager", manager_mod);

    const manager_tests = b.addTest(.{
        .root_module = manager_test_root,
    });

    const manager_v2_test_root = b.createModule(.{
        .root_source_file = b.path("src/manager_v2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    manager_v2_test_root.linkSystemLibrary("util", .{});
    manager_v2_test_root.addImport("msr", lib);
    manager_v2_test_root.addImport("manager", manager_mod);

    const manager_v2_tests = b.addTest(.{
        .root_module = manager_v2_test_root,
    });

    nav_test_root.addImport("manager", manager_mod);
    nav_test_root.addImport("msr", lib);

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const run_rpc_tests = b.addRunArtifact(rpc_tests);
    const run_client_tests = b.addRunArtifact(client_tests);
    const run_nav_tests = b.addRunArtifact(nav_tests);
    const run_manager_tests = b.addRunArtifact(manager_tests);
    const run_manager_v2_tests = b.addRunArtifact(manager_v2_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_rpc_tests.step);
    test_step.dependOn(&run_client_tests.step);
    test_step.dependOn(&run_nav_tests.step);
    test_step.dependOn(&run_manager_tests.step);
    test_step.dependOn(&run_manager_v2_tests.step);

    const test_manager_step = b.step("test-manager", "Run manager module tests");
    test_manager_step.dependOn(&run_manager_tests.step);

    const test_client_step = b.step("test-client", "Run client module tests");
    test_client_step.dependOn(&run_client_tests.step);

    const test_nav_step = b.step("test-nav", "Run nav module tests");
    test_nav_step.dependOn(&run_nav_tests.step);

    const test_manager_v2_step = b.step("test-manager-v2", "Run manager v2 module tests");
    test_manager_v2_step.dependOn(&run_manager_v2_tests.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the demo executable");
    run_step.dependOn(&run_cmd.step);
}
