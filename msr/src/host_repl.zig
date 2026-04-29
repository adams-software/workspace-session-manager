const std = @import("std");
const host_control = @import("host_control");
const host_runtime = @import("host_runtime");
const fd_stream = @import("fd_stream");
const ctlwire = @import("ctlwire");

pub const Repl = struct {
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    stdout: std.fs.File.Writer,
    line_buf: std.ArrayList(u8),
    ready_emitted: bool,

    pub fn init(allocator: std.mem.Allocator) Repl {
        return .{
            .allocator = allocator,
            .stdin_file = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout().writer(&.{}),
            .line_buf = .{},
            .ready_emitted = false,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.line_buf.deinit(self.allocator);
    }

    pub fn setup(self: *Repl) !void {
        try fd_stream.setNonBlocking(std.posix.STDIN_FILENO);
        if (!self.ready_emitted) {
            try ctlwire.message.writeEvent(&self.stdout.interface, .{ .kind = "ready", .payload = "app=msr version=1" });
            self.ready_emitted = true;
        }
    }

    pub fn step(
        self: *Repl,
        runtime: *host_runtime.HostRuntime,
        applyResizeFn: ?*const fn (size: host_runtime.Size) anyerror!void,
    ) !void {
        var byte_buf: [1]u8 = undefined;

        while (true) {
            const n = self.stdin_file.read(byte_buf[0..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) return;

            const b = byte_buf[0];
            if (b == '\r') continue;
            if (b != '\n') {
                try self.line_buf.append(self.allocator, b);
                continue;
            }

            const trimmed = std.mem.trim(u8, self.line_buf.items, " \t\r\n");
            defer self.line_buf.clearRetainingCapacity();
            if (trimmed.len == 0) continue;

            if (std.mem.eql(u8, trimmed, "help")) {
                try self.stdout.interface.writeAll("ok commands=state,resize,signal,exit\n");
                continue;
            }

            const parsed = host_control.parse(trimmed);
            const result = switch (parsed) {
                .command => |cmd| host_control.execute(runtime, cmd, applyResizeFn),
                .err => |err| host_control.Result{ .err = err },
            };
            try printResult(&self.stdout.interface, result);

            if (runtime.state().host_phase == .exiting or runtime.state().host_phase == .exited) return;
        }
    }
};

fn printResult(writer: anytype, result: host_control.Result) !void {
    switch (result) {
        .ok => try ctlwire.message.writeOk(writer),
        .err => |err| try ctlwire.message.writeErr(writer, .{ .kind = @tagName(err) }),
        .state => |state| {
            var buf = std.ArrayList(u8){};
            defer buf.deinit(std.heap.page_allocator);
            var payload = buf.writer(std.heap.page_allocator);
            try payload.print(
                "host={s} child={s} client_attached={} pid={any} size=",
                .{ @tagName(state.host_phase), @tagName(state.child_phase), state.client_attached, state.child_pid },
            );
            if (state.size) |size| {
                try payload.print("{d}x{d}", .{ size.cols, size.rows });
            } else {
                try payload.writeAll("none");
            }
            try payload.writeAll(" exit=");
            switch (state.exit_info) {
                .none => try payload.writeAll("none"),
                .code => |code| try payload.print("code={d}", .{code}),
                .signal => |sig| try payload.print("signal={s}", .{@tagName(sig)}),
            }
            try ctlwire.message.writeOkPayload(writer, buf.items);
        },
    }
}
