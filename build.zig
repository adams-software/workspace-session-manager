const std = @import("std");

fn addVendoredLibvterm(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("term_engine/vendor/libvterm/include"));
    module.addIncludePath(b.path("term_engine/vendor/libvterm/src"));
    module.addIncludePath(b.path("term_engine/vendor/utf8proc"));
    module.addIncludePath(b.path("term_engine/src"));
    module.addCSourceFile(.{ .file = b.path("term_engine/src/vterm_shim.c") });
    module.addCSourceFiles(.{ .files = &.{
        "term_engine/vendor/utf8proc/utf8proc.c",
        "term_engine/vendor/libvterm/src/encoding.c",
        "term_engine/vendor/libvterm/src/keyboard.c",
        "term_engine/vendor/libvterm/src/mouse.c",
        "term_engine/vendor/libvterm/src/parser.c",
        "term_engine/vendor/libvterm/src/pen.c",
        "term_engine/vendor/libvterm/src/screen.c",
        "term_engine/vendor/libvterm/src/state.c",
        "term_engine/vendor/libvterm/src/unicode.c",
        "term_engine/vendor/libvterm/src/vterm.c",
    } });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared modules
    const term_engine_mod = b.addModule("term_engine", .{
        .root_source_file = b.path("term_engine/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addVendoredLibvterm(term_engine_mod, b);

    const byte_queue_mod = b.addModule("byte_queue", .{
        .root_source_file = b.path("ptyio/src/stream/byte_queue.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const ctlwire_mod = b.addModule("ctlwire", .{
        .root_source_file = b.path("ctlwire/src/root.zig"),
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

    const duplex_link_mod = b.addModule("duplex_link", .{
        .root_source_file = b.path("ptyio/src/stream/duplex_link.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    duplex_link_mod.addImport("byte_queue", byte_queue_mod);
    duplex_link_mod.addImport("fd_stream", fd_stream_mod);

    const host_runtime_mod = b.addModule("host_runtime", .{
        .root_source_file = b.path("msr/src/host_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const host_control_mod = b.addModule("host_control", .{
        .root_source_file = b.path("msr/src/host_control.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_control_mod.addImport("host_runtime", host_runtime_mod);

    const host_client_mod = b.addModule("host_client", .{
        .root_source_file = b.path("msr/src/host_client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_client_mod.addImport("host_control", host_control_mod);
    host_client_mod.addImport("host_runtime", host_runtime_mod);
    host_client_mod.addImport("ctlwire", ctlwire_mod);

    const host_mod = b.addModule("host", .{
        .root_source_file = b.path("ptyio/src/pty/child_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    host_mod.linkSystemLibrary("util", .{});

    const host_repl_mod = b.addModule("host_repl", .{
        .root_source_file = b.path("msr/src/host_repl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_repl_mod.addImport("host_control", host_control_mod);
    host_repl_mod.addImport("host_runtime", host_runtime_mod);
    host_repl_mod.addImport("fd_stream", fd_stream_mod);
    host_repl_mod.addImport("ctlwire", ctlwire_mod);

    const server_mod = b.addModule("server", .{
        .root_source_file = b.path("msr/src/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_mod.addImport("host", host_mod);
    server_mod.addImport("host_runtime", host_runtime_mod);
    server_mod.addImport("byte_queue", byte_queue_mod);
    server_mod.addImport("fd_stream", fd_stream_mod);

    const raw_mode_mod = b.addModule("ptyio_raw_mode", .{
        .root_source_file = b.path("ptyio/src/tty/raw_mode.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const tty_size_mod = b.addModule("ptyio_tty_size", .{
        .root_source_file = b.path("ptyio/src/tty/tty_size.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // msr
    const exe_root = b.createModule(.{
        .root_source_file = b.path("msr/src/main.zig"),
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
    exe_root.addImport("ptyio_tty_size", tty_size_mod);

    const exe = b.addExecutable(.{
        .name = "msr",
        .root_module = exe_root,
    });
    b.installArtifact(exe);

    const attach_root = b.createModule(.{
        .root_source_file = b.path("msr/src/attach_raw.zig"),
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

    const argv_parse_mod = b.addModule("argv_parse", .{
        .root_source_file = b.path("shared/src/cli/argv_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const wsm_root = b.createModule(.{
        .root_source_file = b.path("wsm/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wsm_root.addImport("byte_queue", byte_queue_mod);
    wsm_root.addImport("fd_stream", fd_stream_mod);
    wsm_root.addImport("duplex_link", duplex_link_mod);
    wsm_root.addImport("ptyio_raw_mode", raw_mode_mod);
    wsm_root.addImport("ptyio_tty_size", tty_size_mod);
    wsm_root.addImport("ctlwire", ctlwire_mod);
    wsm_root.addImport("argv_parse", argv_parse_mod);
    const wsm_exe = b.addExecutable(.{
        .name = "wsm",
        .root_module = wsm_root,
    });
    b.installArtifact(wsm_exe);

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

    const host_test_root = b.createModule(.{
        .root_source_file = b.path("ptyio/src/pty/child_host.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    host_test_root.linkSystemLibrary("util", .{});
    const host_tests = b.addTest(.{ .root_module = host_test_root });

    const host_runtime_tests = b.addTest(.{ .root_module = host_runtime_mod });
    const host_control_tests = b.addTest(.{ .root_module = host_control_mod });
    const host_client_tests = b.addTest(.{ .root_module = host_client_mod });

    const wsm_ui_state_mod = b.createModule(.{
        .root_source_file = b.path("wsm/src/ui_state.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    const wsm_bar_layout_mod = b.createModule(.{
        .root_source_file = b.path("wsm/src/bar_layout.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    wsm_bar_layout_mod.addImport("ui_state", wsm_ui_state_mod);
    const wsm_bar_render_mod = b.createModule(.{
        .root_source_file = b.path("wsm/src/bar_render.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    wsm_bar_render_mod.addImport("ui_state", wsm_ui_state_mod);
    const wsm_ui_state_tests = b.addTest(.{ .root_module = wsm_ui_state_mod });
    const wsm_bar_layout_tests = b.addTest(.{ .root_module = wsm_bar_layout_mod });
    const wsm_bar_render_tests = b.addTest(.{ .root_module = wsm_bar_render_mod });

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
    session_host_vpty_mod.addImport("term_engine", term_engine_mod);

    const terminal_model_mod = b.addModule("terminal_model", .{
        .root_source_file = b.path("vpty/src/terminal_model.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    terminal_model_mod.addImport("term_engine", term_engine_mod);

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

    const single_viewport_adapter_mod = b.addModule("single_viewport_adapter", .{
        .root_source_file = b.path("vpty/src/single_viewport_adapter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    single_viewport_adapter_mod.addImport("session_host_vpty", session_host_vpty_mod);

    const vpty_render_mod = b.addModule("vpty_render", .{
        .root_source_file = b.path("vpty/src/vpty_render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vpty_render_mod.addImport("session_host_vpty", session_host_vpty_mod);
    vpty_render_mod.addImport("single_viewport_adapter", single_viewport_adapter_mod);
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

    const ptyio_tty_size_mod = b.addModule("ptyio_tty_size", .{
        .root_source_file = b.path("ptyio/src/tty/tty_size.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // scroll spike
    const scroll_root = b.createModule(.{
        .root_source_file = b.path("scroll/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    scroll_root.addImport("term_engine", term_engine_mod);
    scroll_root.addImport("ptyio_tty_size", ptyio_tty_size_mod);
    const scroll_exe = b.addExecutable(.{
        .name = "scroll",
        .root_module = scroll_root,
    });
    b.installArtifact(scroll_exe);

    // alt
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
    alt_root.addImport("argv_parse", argv_parse_mod);

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

    const terminal_state_vterm_tests = b.addTest(.{ .root_module = term_engine_mod });

    // Test runners and aliases
    const run_terminal_state_vterm_tests = b.addRunArtifact(terminal_state_vterm_tests);
    const run_alt_tests = b.addRunArtifact(alt_tests);
    const run_byte_queue_tests = b.addRunArtifact(byte_queue_tests);
    const run_fd_stream_tests = b.addRunArtifact(fd_stream_tests);
    const run_host_tests = b.addRunArtifact(host_tests);
    const run_host_runtime_tests = b.addRunArtifact(host_runtime_tests);
    const run_host_control_tests = b.addRunArtifact(host_control_tests);
    const run_host_client_tests = b.addRunArtifact(host_client_tests);
    const run_wsm_ui_state_tests = b.addRunArtifact(wsm_ui_state_tests);
    const run_wsm_bar_layout_tests = b.addRunArtifact(wsm_bar_layout_tests);
    const run_wsm_bar_render_tests = b.addRunArtifact(wsm_bar_render_tests);

    const test_step = b.step("test", "Run workspace tests");
    test_step.dependOn(&run_alt_tests.step);
    test_step.dependOn(&run_byte_queue_tests.step);
    test_step.dependOn(&run_fd_stream_tests.step);
    test_step.dependOn(&run_host_tests.step);
    test_step.dependOn(&run_host_runtime_tests.step);
    test_step.dependOn(&run_host_control_tests.step);
    test_step.dependOn(&run_host_client_tests.step);
    test_step.dependOn(&run_wsm_ui_state_tests.step);
    test_step.dependOn(&run_wsm_bar_layout_tests.step);
    test_step.dependOn(&run_wsm_bar_render_tests.step);

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

    const test_host_runtime_step = b.step("test-host-runtime", "Run msr host_runtime tests");
    test_host_runtime_step.dependOn(&run_host_runtime_tests.step);

    const test_host_control_step = b.step("test-host-control", "Run msr host_control tests");
    test_host_control_step.dependOn(&run_host_control_tests.step);

    const test_host_client_step = b.step("test-host-client", "Run msr host_client tests");
    test_host_client_step.dependOn(&run_host_client_tests.step);

    const test_wsm_ui_state_step = b.step("test-wsm-ui-state", "Run wsm ui_state tests");
    test_wsm_ui_state_step.dependOn(&run_wsm_ui_state_tests.step);

    const test_wsm_bar_layout_step = b.step("test-wsm-bar-layout", "Run wsm bar_layout tests");
    test_wsm_bar_layout_step.dependOn(&run_wsm_bar_layout_tests.step);

    const test_wsm_bar_render_step = b.step("test-wsm-bar-render", "Run wsm bar_render tests");
    test_wsm_bar_render_step.dependOn(&run_wsm_bar_render_tests.step);

    const smoke_cmd = b.addSystemCommand(&.{ "python3", "-u", "msr/scripts/smoke_msr_binary.py" });
    smoke_cmd.setCwd(b.path("."));
    const smoke_step = b.step("smoke-binary", "Run real-binary smoke test for msr");
    smoke_step.dependOn(b.getInstallStep());
    smoke_step.dependOn(&smoke_cmd.step);

}
