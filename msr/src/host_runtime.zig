const std = @import("std");

const c = @cImport({
    @cInclude("signal.h");
});

pub const Signal = enum {
    term,
    int,
    kill,
};

pub const HostPhase = enum {
    starting,
    running,
    exiting,
    exited,
};

pub const ChildPhase = enum {
    starting,
    running,
    exited,
};

pub const ExitInfo = union(enum) {
    none,
    code: i32,
    signal: Signal,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const HostState = struct {
    socket_path: []const u8,
    host_phase: HostPhase,
    child_phase: ChildPhase,
    child_pid: ?i32,
    client_attached: bool,
    size: ?Size,
    exit_info: ExitInfo,
};

pub const HostEvent = union(enum) {
    socket_listening: struct {
        path: []const u8,
    },
    client_connected,
    client_disconnected,
    client_replaced,
    resized: Size,
    child_exited: ExitInfo,
    host_exiting,
};

pub const EventSink = struct {
    ctx: ?*anyopaque,
    onEventFn: *const fn (ctx: ?*anyopaque, event: HostEvent) void,

    pub fn emit(self: EventSink, event: HostEvent) void {
        self.onEventFn(self.ctx, event);
    }
};

pub fn writeEventLine(writer: anytype, event: HostEvent) !void {
    switch (event) {
        .socket_listening => |info| try writer.print("event socket_listening path={s}\n", .{info.path}),
        .client_connected => try writer.writeAll("event client_connected\n"),
        .client_disconnected => try writer.writeAll("event client_disconnected\n"),
        .client_replaced => try writer.writeAll("event client_replaced\n"),
        .resized => |size| try writer.print("event resized cols={d} rows={d}\n", .{ size.cols, size.rows }),
        .child_exited => |exit_info| switch (exit_info) {
            .none => try writer.writeAll("event child_exited exit=none\n"),
            .code => |code| try writer.print("event child_exited code={d}\n", .{code}),
            .signal => |sig| try writer.print("event child_exited signal={s}\n", .{@tagName(sig)}),
        },
        .host_exiting => try writer.writeAll("event host_exiting\n"),
    }
}

pub const Error = error{
    InvalidArgs,
    InvalidState,
};

pub const HostRuntime = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,
    event_sink: ?EventSink,
    state_snapshot: HostState,

    pub fn init(
        allocator: std.mem.Allocator,
        socket_path: []const u8,
        event_sink: ?EventSink,
    ) !HostRuntime {
        const owned_path = try allocator.dupe(u8, socket_path);
        errdefer allocator.free(owned_path);

        return .{
            .allocator = allocator,
            .socket_path = owned_path,
            .event_sink = event_sink,
            .state_snapshot = .{
                .socket_path = owned_path,
                .host_phase = .starting,
                .child_phase = .starting,
                .child_pid = null,
                .client_attached = false,
                .size = null,
                .exit_info = .none,
            },
        };
    }

    pub fn deinit(self: *HostRuntime) void {
        self.allocator.free(self.socket_path);
    }

    pub fn state(self: *const HostRuntime) HostState {
        return self.state_snapshot;
    }

    pub fn resize(self: *HostRuntime, cols: u16, rows: u16) Error!void {
        if (cols == 0 or rows == 0) return Error.InvalidArgs;
        const size = Size{ .cols = cols, .rows = rows };
        self.state_snapshot.size = size;
        self.emit(.{ .resized = size });
    }

    pub fn sendSignal(self: *HostRuntime, sig: Signal) Error!Signal {
        switch (self.state_snapshot.child_phase) {
            .starting, .running => {
                const pid = self.state_snapshot.child_pid orelse return Error.InvalidState;
                const os_sig: std.posix.SIG = @enumFromInt(switch (sig) {
                    .term => c.SIGTERM,
                    .int => c.SIGINT,
                    .kill => c.SIGKILL,
                });
                std.posix.kill(pid, os_sig) catch return Error.InvalidState;
                return sig;
            },
            .exited => return Error.InvalidState,
        }
    }

    pub fn requestExit(self: *HostRuntime) Error!void {
        switch (self.state_snapshot.host_phase) {
            .starting, .running => {
                self.state_snapshot.host_phase = .exiting;
                self.emit(.host_exiting);
            },
            .exiting, .exited => return Error.InvalidState,
        }
    }

    pub fn onSocketListening(self: *HostRuntime) void {
        self.state_snapshot.host_phase = .running;
        self.emit(.{ .socket_listening = .{ .path = self.socket_path } });
    }

    pub fn onHostExiting(self: *HostRuntime) void {
        if (self.state_snapshot.host_phase != .exited) {
            self.state_snapshot.host_phase = .exiting;
        }
        self.emit(.host_exiting);
    }

    pub fn onClientConnected(self: *HostRuntime) void {
        self.state_snapshot.client_attached = true;
        self.emit(.client_connected);
    }

    pub fn onClientDisconnected(self: *HostRuntime) void {
        self.state_snapshot.client_attached = false;
        self.emit(.client_disconnected);
    }

    pub fn onClientReplaced(self: *HostRuntime) void {
        self.state_snapshot.client_attached = true;
        self.emit(.client_replaced);
    }

    pub fn onChildStarted(self: *HostRuntime, pid: i32) void {
        self.state_snapshot.child_pid = pid;
        self.state_snapshot.child_phase = .running;
    }

    pub fn onChildExitedCode(self: *HostRuntime, code: i32) void {
        const exit_info: ExitInfo = .{ .code = code };
        self.state_snapshot.child_phase = .exited;
        self.state_snapshot.host_phase = .exited;
        self.state_snapshot.exit_info = exit_info;
        self.emit(.{ .child_exited = exit_info });
    }

    pub fn onChildExitedSignal(self: *HostRuntime, sig: Signal) void {
        const exit_info: ExitInfo = .{ .signal = sig };
        self.state_snapshot.child_phase = .exited;
        self.state_snapshot.host_phase = .exited;
        self.state_snapshot.exit_info = exit_info;
        self.emit(.{ .child_exited = exit_info });
    }

    fn emit(self: *HostRuntime, event: HostEvent) void {
        if (self.event_sink) |sink| sink.emit(event);
    }
};

test "host_runtime updates state and emits key events" {
    const Capture = struct {
        events: std.ArrayList(HostEvent),

        fn onEvent(ctx: ?*anyopaque, event: HostEvent) void {
            const Self = @This();
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.events.append(std.testing.allocator, event) catch unreachable;
        }
    };

    var capture = Capture{ .events = .empty };
    defer capture.events.deinit(std.testing.allocator);

    var runtime = try HostRuntime.init(
        std.testing.allocator,
        "/tmp/test.sock",
        .{ .ctx = &capture, .onEventFn = Capture.onEvent },
    );
    defer runtime.deinit();

    runtime.onSocketListening();
    runtime.onClientConnected();
    runtime.onClientReplaced();
    runtime.onClientDisconnected();
    try runtime.resize(120, 40);
    runtime.onChildStarted(1234);
    runtime.onChildExitedCode(7);

    const st = runtime.state();
    try std.testing.expectEqual(HostPhase.exited, st.host_phase);
    try std.testing.expectEqual(ChildPhase.exited, st.child_phase);
    try std.testing.expectEqual(@as(?i32, 1234), st.child_pid);
    try std.testing.expectEqual(false, st.client_attached);
    try std.testing.expect(st.size != null);
    try std.testing.expectEqual(@as(u16, 120), st.size.?.cols);
    try std.testing.expectEqual(@as(u16, 40), st.size.?.rows);
    switch (st.exit_info) {
        .code => |code| try std.testing.expectEqual(@as(i32, 7), code),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 6), capture.events.items.len);
    try std.testing.expect(capture.events.items[0] == .socket_listening);
    try std.testing.expect(capture.events.items[1] == .client_connected);
    try std.testing.expect(capture.events.items[2] == .client_replaced);
    try std.testing.expect(capture.events.items[3] == .client_disconnected);
    try std.testing.expect(capture.events.items[4] == .resized);
    try std.testing.expect(capture.events.items[5] == .child_exited);
}

test "host_runtime requestExit moves to exiting and emits host_exiting" {
    const Capture = struct {
        saw_host_exiting: bool = false,

        fn onEvent(ctx: ?*anyopaque, event: HostEvent) void {
            const Self = @This();
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (event == .host_exiting) self.saw_host_exiting = true;
        }
    };

    var capture = Capture{};
    var runtime = try HostRuntime.init(
        std.testing.allocator,
        "/tmp/test.sock",
        .{ .ctx = &capture, .onEventFn = Capture.onEvent },
    );
    defer runtime.deinit();

    runtime.onSocketListening();
    try runtime.requestExit();

    try std.testing.expectEqual(HostPhase.exiting, runtime.state().host_phase);
    try std.testing.expect(capture.saw_host_exiting);
}
