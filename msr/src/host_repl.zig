const std = @import("std");
const host_control = @import("host_control");
const host_runtime = @import("host_runtime");

pub fn run(
    allocator: std.mem.Allocator,
    runtime: *host_runtime.HostRuntime,
) !void {
    const stdin_file = std.fs.File.stdin();
    var stdout = std.fs.File.stdout().writer(&.{});
    var line_buf = std.ArrayList(u8){};
    defer line_buf.deinit(allocator);

    var byte_buf: [1]u8 = undefined;
    while (true) {
        try stdout.interface.writeAll("> ");
        line_buf.clearRetainingCapacity();

        while (true) {
            const n = try stdin_file.read(byte_buf[0..]);
            if (n == 0) return;
            const b = byte_buf[0];
            if (b == '\n') break;
            if (b == '\r') continue;
            try line_buf.append(allocator, b);
        }

        const trimmed = std.mem.trim(u8, line_buf.items, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "help")) {
            try stdout.interface.writeAll("commands: state | resize <cols> <rows> | signal <term|int|kill> | exit\n");
            continue;
        }

        const parsed = host_control.parse(trimmed);
        const result = switch (parsed) {
            .command => |cmd| host_control.execute(runtime, cmd),
            .err => |err| host_control.Result{ .err = err },
        };

        try printResult(&stdout.interface, result);

        if (runtime.state().host_phase == .exiting or runtime.state().host_phase == .exited) break;
    }
}

fn printResult(writer: anytype, result: host_control.Result) !void {
    switch (result) {
        .ok => try writer.writeAll("ok\n"),
        .err => |err| try writer.print("err {s}\n", .{@tagName(err)}),
        .state => |state| {
            try writer.print(
                "state host={s} child={s} client_attached={} pid={any} size=",
                .{ @tagName(state.host_phase), @tagName(state.child_phase), state.client_attached, state.child_pid },
            );
            if (state.size) |size| {
                try writer.print("{d}x{d}", .{ size.cols, size.rows });
            } else {
                try writer.writeAll("none");
            }
            try writer.writeAll(" exit=");
            switch (state.exit_info) {
                .none => try writer.writeAll("none"),
                .code => |code| try writer.print("code:{d}", .{code}),
                .signal => |sig| try writer.print("signal:{s}", .{@tagName(sig)}),
            }
            try writer.writeByte('\n');
        },
    }
}
