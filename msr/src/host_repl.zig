const std = @import("std");
const host_control = @import("host_control");
const host_runtime = @import("host_runtime");
const fd_stream = @import("fd_stream");
const ctlwire = @import("ctlwire");

pub const Repl = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    line_buf: std.ArrayList(u8),
    ready_emitted: bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Repl {
        return .{
            .allocator = allocator,
            .io = io,
            .line_buf = .empty,
            .ready_emitted = false,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.line_buf.deinit(self.allocator);
    }

    pub fn setup(self: *Repl) !void {
        try fd_stream.setNonBlocking(std.posix.STDIN_FILENO);
        if (!self.ready_emitted) {
            var stdout_buf: [256]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(self.io, &stdout_buf);
            try ctlwire.message.writeEvent(&stdout.interface, .{ .kind = "ready", .payload = "app=host version=1" });
            try stdout.interface.flush();
            self.ready_emitted = true;
        }
    }

    pub fn step(
        self: *Repl,
        runtime: *host_runtime.HostRuntime,
        applyResizeFn: ?*const fn (size: host_runtime.Size) anyerror!void,
    ) !void {
        var byte_buf: [1]u8 = undefined;
        var stdout_buf: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(self.io, &stdout_buf);

        while (true) {
            const n = std.posix.read(std.posix.STDIN_FILENO, byte_buf[0..]) catch |err| switch (err) {
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
                try stdout.interface.writeAll("ok commands=state,resize,signal,exit\n");
                try stdout.interface.flush();
                continue;
            }

            const parsed = host_control.parse(trimmed);
            const result = switch (parsed) {
                .command => |cmd| host_control.execute(runtime, cmd, applyResizeFn),
                .err => |err| host_control.Result{ .err = err },
            };
            try printResult(&stdout.interface, result);
            try stdout.interface.flush();

            if (runtime.state().host_phase == .exiting or runtime.state().host_phase == .exited) return;
        }
    }
};

fn printResult(writer: anytype, result: host_control.Result) !void {
    switch (result) {
        .ok => try ctlwire.message.writeOk(writer),
        .err => |err| try ctlwire.message.writeErr(writer, .{ .kind = @tagName(err) }),
        .state => |state| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(std.heap.page_allocator);
            var payload = std.Io.Writer.Allocating.fromArrayList(std.heap.page_allocator, &buf);
            defer buf = payload.toArrayList();
            try payload.writer.print(
                "host={s} child={s} client_attached={} pid={any} size=",
                .{ @tagName(state.host_phase), @tagName(state.child_phase), state.client_attached, state.child_pid },
            );
            if (state.size) |size| {
                try payload.writer.print("{d}x{d}", .{ size.cols, size.rows });
            } else {
                try payload.writer.writeAll("none");
            }
            try payload.writer.writeAll(" exit=");
            switch (state.exit_info) {
                .none => try payload.writer.writeAll("none"),
                .code => |code| try payload.writer.print("code={d}", .{code}),
                .signal => |sig| try payload.writer.print("signal={s}", .{@tagName(sig)}),
            }
            try ctlwire.message.writeOkPayload(writer, payload.written());
        },
    }
}
