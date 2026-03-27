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

    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_root.linkSystemLibrary("util", .{});

    const exe = b.addExecutable(.{
        .name = "msr-demo",
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

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const run_rpc_tests = b.addRunArtifact(rpc_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_rpc_tests.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the demo executable");
    run_step.dependOn(&run_cmd.step);
}
