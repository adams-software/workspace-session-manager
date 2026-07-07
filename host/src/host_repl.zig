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
        var pending_resize: ?PendingResize = null;
        var byte_buf: [1]u8 = undefined;
        var stdout_buf: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(self.io, &stdout_buf);

        while (true) {
            const n = std.posix.read(std.posix.STDIN_FILENO, byte_buf[0..]) catch |err| switch (err) {
                error.WouldBlock => {
                    try flushPendingResize(&stdout.interface, runtime, applyResizeFn, &pending_resize);
                    try stdout.interface.flush();
                    return;
                },
                else => return err,
            };
            if (n == 0) {
                try flushPendingResize(&stdout.interface, runtime, applyResizeFn, &pending_resize);
                try stdout.interface.flush();
                return;
            }

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
                try flushPendingResize(&stdout.interface, runtime, applyResizeFn, &pending_resize);
                try stdout.interface.writeAll("ok commands=state,resize,signal,exit\n");
                try stdout.interface.flush();
                continue;
            }

            const parsed = host_control.parse(trimmed);
            try handleParsedLine(&stdout.interface, runtime, applyResizeFn, &pending_resize, parsed);
            try stdout.interface.flush();

            if (runtime.state().host_phase == .exiting or runtime.state().host_phase == .exited) return;
        }
    }
};

const PendingResize = struct {
    size: host_runtime.Size,
    count: usize,
};

fn queueResize(pending_resize: *?PendingResize, size: host_runtime.Size) void {
    if (pending_resize.*) |*pending| {
        pending.size = size;
        pending.count += 1;
    } else {
        pending_resize.* = .{ .size = size, .count = 1 };
    }
}

fn flushPendingResize(
    writer: anytype,
    runtime: *host_runtime.HostRuntime,
    applyResizeFn: ?*const fn (size: host_runtime.Size) anyerror!void,
    pending_resize: *?PendingResize,
) !void {
    const pending = pending_resize.* orelse return;
    pending_resize.* = null;

    const result = host_control.execute(runtime, .{ .resize = pending.size }, applyResizeFn);
    for (0..pending.count) |_| {
        try printResult(writer, result);
    }
}

fn handleParsedLine(
    writer: anytype,
    runtime: *host_runtime.HostRuntime,
    applyResizeFn: ?*const fn (size: host_runtime.Size) anyerror!void,
    pending_resize: *?PendingResize,
    parsed: host_control.ResultOrCommand,
) !void {
    switch (parsed) {
        .err => |parse_err| {
            try flushPendingResize(writer, runtime, applyResizeFn, pending_resize);
            try printResult(writer, .{ .err = parse_err });
        },
        .command => |cmd| switch (cmd) {
            .resize => |size| queueResize(pending_resize, size),
            else => {
                try flushPendingResize(writer, runtime, applyResizeFn, pending_resize);
                try printResult(writer, host_control.execute(runtime, cmd, applyResizeFn));
            },
        },
    }
}

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

test "flushPendingResize applies latest size once and preserves response count" {
    var runtime = try host_runtime.HostRuntime.init(std.testing.allocator, "/tmp/test.sock", null);
    defer runtime.deinit();
    runtime.onSocketListening();
    runtime.onChildStarted(123);

    const Capture = struct {
        var apply_count: usize = 0;
        var last_size: ?host_runtime.Size = null;

        fn apply(size: host_runtime.Size) !void {
            apply_count += 1;
            last_size = size;
        }
    };
    Capture.apply_count = 0;
    Capture.last_size = null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &out);
    defer out = writer.toArrayList();

    var pending_resize: ?PendingResize = .{
        .size = .{ .cols = 120, .rows = 40 },
        .count = 3,
    };
    try flushPendingResize(&writer.writer, &runtime, Capture.apply, &pending_resize);

    try std.testing.expectEqual(@as(?PendingResize, null), pending_resize);
    try std.testing.expectEqual(@as(usize, 1), Capture.apply_count);
    try std.testing.expectEqual(@as(u16, 120), Capture.last_size.?.cols);
    try std.testing.expectEqual(@as(u16, 40), Capture.last_size.?.rows);
    try std.testing.expectEqualStrings("ok\nok\nok\n", out.items);
    try std.testing.expect(runtime.state().size != null);
    try std.testing.expectEqual(@as(u16, 120), runtime.state().size.?.cols);
    try std.testing.expectEqual(@as(u16, 40), runtime.state().size.?.rows);
}

test "handleParsedLine flushes pending resize before exit command" {
    var runtime = try host_runtime.HostRuntime.init(std.testing.allocator, "/tmp/test.sock", null);
    defer runtime.deinit();
    runtime.onSocketListening();
    runtime.onChildStarted(123);

    const Capture = struct {
        var apply_count: usize = 0;
        var last_size: ?host_runtime.Size = null;

        fn apply(size: host_runtime.Size) !void {
            apply_count += 1;
            last_size = size;
        }
    };
    Capture.apply_count = 0;
    Capture.last_size = null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &out);
    defer out = writer.toArrayList();

    var pending_resize: ?PendingResize = null;
    try handleParsedLine(&writer.writer, &runtime, Capture.apply, &pending_resize, .{
        .command = .{ .resize = .{ .cols = 90, .rows = 30 } },
    });
    try handleParsedLine(&writer.writer, &runtime, Capture.apply, &pending_resize, .{
        .command = .{ .resize = .{ .cols = 120, .rows = 50 } },
    });
    try handleParsedLine(&writer.writer, &runtime, Capture.apply, &pending_resize, .{
        .command = .exit,
    });

    try std.testing.expectEqual(@as(?PendingResize, null), pending_resize);
    try std.testing.expectEqual(@as(usize, 1), Capture.apply_count);
    try std.testing.expectEqual(@as(u16, 120), Capture.last_size.?.cols);
    try std.testing.expectEqual(@as(u16, 50), Capture.last_size.?.rows);
    try std.testing.expectEqualStrings("ok\nok\nok\n", out.items);
    try std.testing.expectEqual(host_runtime.HostPhase.exiting, runtime.state().host_phase);
}
