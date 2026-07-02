const std = @import("std");
const host_control = @import("host_control");
const host_runtime = @import("host_runtime");
const ctlwire = @import("ctlwire");

// Typed host-control facade over raw ctlwire message lines.
pub const Line = union(enum) {
    ok: []const u8,
    err: []const u8,
    event: Event,
};

pub const Event = struct {
    kind: []const u8,
    rest: []const u8,
};

pub const Response = union(enum) {
    ok: []const u8,
    err: []const u8,
};

pub const StateView = struct {
    host_phase: host_runtime.HostPhase,
    child_phase: host_runtime.ChildPhase,
    client_attached: bool,
    child_pid: ?std.posix.pid_t,
    size: ?host_runtime.Size,
    exit_info: host_runtime.ExitInfo,
};

pub const ErrorInfo = struct {
    kind: []const u8,
    detail: []const u8,
};

pub const Error = error{
    InvalidLine,
    UnexpectedEof,
    RequestInFlight,
    UnexpectedResponse,
    InvalidField,
    MissingField,
    InvalidBool,
    InvalidSize,
    InvalidExit,
    InvalidHostPhase,
    InvalidChildPhase,
    InvalidPid,
};

pub const EventSink = struct {
    ctx: ?*anyopaque,
    onEventFn: *const fn (ctx: ?*anyopaque, event: Event) void,

    pub fn emit(self: EventSink, event: Event) void {
        self.onEventFn(self.ctx, event);
    }
};

pub fn parseLine(line_text: []const u8) Error!Line {
    const parsed = ctlwire.message.parseLine(line_text) catch return Error.InvalidLine;
    return switch (parsed) {
        .ok => |payload| .{ .ok = payload },
        .err => |err_line| .{ .err = if (err_line.detail.len == 0) err_line.kind else err_line.detail },
        .event => |event| .{ .event = .{ .kind = event.kind, .rest = event.payload } },
    };
}

pub fn readLine(reader: anytype, buf: []u8) !?[]u8 {
    return ctlwire.line.readLine(reader, buf) catch |err| switch (err) {
        error.InvalidLine => Error.InvalidLine,
        error.UnexpectedEof => Error.UnexpectedEof,
    };
}

pub fn formatCommand(writer: anytype, command: host_control.Command) !void {
    switch (command) {
        .state => try writer.writeAll("state\n"),
        .resize => |size| try writer.print("resize {d} {d}\n", .{ size.cols, size.rows }),
        .signal => |sig| try writer.print("signal {s}\n", .{@tagName(sig)}),
        .exit => try writer.writeAll("exit\n"),
    }
}

pub fn parseErrorInfo(payload: []const u8) ErrorInfo {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return .{ .kind = "", .detail = "" };
    const space = std.mem.indexOfScalar(u8, trimmed, ' ');
    if (space) |i| {
        return .{ .kind = trimmed[0..i], .detail = trimmed[(i + 1)..] };
    }
    return .{ .kind = trimmed, .detail = "" };
}

pub fn parseStateView(payload: []const u8) Error!StateView {
    var host_phase: ?host_runtime.HostPhase = null;
    var child_phase: ?host_runtime.ChildPhase = null;
    var client_attached: ?bool = null;
    var child_pid: ?std.posix.pid_t = null;
    var size: ?host_runtime.Size = null;
    var exit_info: ?host_runtime.ExitInfo = null;

    var iter = std.mem.tokenizeScalar(u8, payload, ' ');
    while (iter.next()) |token| {
        const eq = std.mem.indexOfScalar(u8, token, '=') orelse return Error.InvalidField;
        const key = token[0..eq];
        const value = token[(eq + 1)..];

        if (std.mem.eql(u8, key, "host")) {
            host_phase = try parseHostPhase(value);
        } else if (std.mem.eql(u8, key, "child")) {
            child_phase = try parseChildPhase(value);
        } else if (std.mem.eql(u8, key, "client_attached")) {
            client_attached = try parseBool(value);
        } else if (std.mem.eql(u8, key, "pid")) {
            child_pid = try parsePid(value);
        } else if (std.mem.eql(u8, key, "size")) {
            size = try parseSize(value);
        } else if (std.mem.eql(u8, key, "exit")) {
            exit_info = try parseExitInfo(value);
        } else {
            return Error.InvalidField;
        }
    }

    return .{
        .host_phase = host_phase orelse return Error.MissingField,
        .child_phase = child_phase orelse return Error.MissingField,
        .client_attached = client_attached orelse return Error.MissingField,
        .child_pid = child_pid,
        .size = size,
        .exit_info = exit_info orelse return Error.MissingField,
    };
}

pub fn roundTrip(
    writer: anytype,
    reader: anytype,
    event_sink: ?EventSink,
    command: host_control.Command,
    buf: []u8,
) !Response {
    var cmd_buf: [128]u8 = undefined;
    const command_text = try formatCommandInto(&cmd_buf, command);

    const ForwardCtx = struct {
        sink: EventSink,
    };
    const Bridge = struct {
        fn onEvent(ctx: ?*anyopaque, event: ctlwire.message.EventLine) void {
            const forward: *ForwardCtx = @ptrCast(@alignCast(ctx.?));
            forward.sink.emit(.{ .kind = event.kind, .rest = event.payload });
        }
    };
    var forward_ctx: ?ForwardCtx = if (event_sink) |sink| .{ .sink = sink } else null;
    const wire_event_sink = if (forward_ctx) |*ctx| ctlwire.client.EventSink{ .ctx = ctx, .onEventFn = Bridge.onEvent } else null;

    const line_result = ctlwire.client.roundTrip(writer, reader, wire_event_sink, command_text, buf) catch |err| switch (err) {
        error.InvalidLine => return Error.InvalidLine,
        error.UnexpectedEof => return Error.UnexpectedEof,
        else => return err,
    };

    return switch (line_result) {
        .ok => |payload| .{ .ok = payload },
        .err => |err_line| .{ .err = if (err_line.detail.len == 0) err_line.kind else err_line.detail },
        .event => unreachable,
    };
}

fn formatCommandInto(buf: []u8, command: host_control.Command) ![]const u8 {
    return switch (command) {
        .state => std.fmt.bufPrint(buf, "state\n", .{}),
        .resize => |size| std.fmt.bufPrint(buf, "resize {d} {d}\n", .{ size.cols, size.rows }),
        .signal => |sig| std.fmt.bufPrint(buf, "signal {s}\n", .{@tagName(sig)}),
        .exit => std.fmt.bufPrint(buf, "exit\n", .{}),
    };
}

pub fn state(writer: anytype, reader: anytype, event_sink: ?EventSink, buf: []u8) !StateView {
    const response = try roundTrip(writer, reader, event_sink, .state, buf);
    return switch (response) {
        .ok => |payload| parseStateView(payload),
        .err => Error.UnexpectedResponse,
    };
}

pub fn resize(
    writer: anytype,
    reader: anytype,
    event_sink: ?EventSink,
    size_value: host_runtime.Size,
    buf: []u8,
) !void {
    const response = try roundTrip(writer, reader, event_sink, .{ .resize = size_value }, buf);
    switch (response) {
        .ok => {},
        .err => return Error.UnexpectedResponse,
    }
}

pub fn signal(
    writer: anytype,
    reader: anytype,
    event_sink: ?EventSink,
    sig: host_runtime.Signal,
    buf: []u8,
) !void {
    const response = try roundTrip(writer, reader, event_sink, .{ .signal = sig }, buf);
    switch (response) {
        .ok => {},
        .err => return Error.UnexpectedResponse,
    }
}

pub fn exit(writer: anytype, reader: anytype, event_sink: ?EventSink, buf: []u8) !void {
    const response = try roundTrip(writer, reader, event_sink, .exit, buf);
    switch (response) {
        .ok => {},
        .err => return Error.UnexpectedResponse,
    }
}

fn parseBool(value: []const u8) Error!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return Error.InvalidBool;
}

fn parsePid(value: []const u8) Error!?std.posix.pid_t {
    if (std.mem.eql(u8, value, "none")) return null;
    const parsed = std.fmt.parseInt(i32, value, 10) catch return Error.InvalidPid;
    return @as(std.posix.pid_t, parsed);
}

fn parseSize(value: []const u8) Error!?host_runtime.Size {
    if (std.mem.eql(u8, value, "none")) return null;
    const x = std.mem.indexOfScalar(u8, value, 'x') orelse return Error.InvalidSize;
    const cols = std.fmt.parseInt(u16, value[0..x], 10) catch return Error.InvalidSize;
    const rows = std.fmt.parseInt(u16, value[(x + 1)..], 10) catch return Error.InvalidSize;
    return .{ .cols = cols, .rows = rows };
}

fn parseExitInfo(value: []const u8) Error!host_runtime.ExitInfo {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.startsWith(u8, value, "code=")) {
        const code = std.fmt.parseInt(u8, value[5..], 10) catch return Error.InvalidExit;
        return .{ .code = code };
    }
    if (std.mem.startsWith(u8, value, "signal=")) {
        return .{ .signal = try parseSignal(value[7..]) };
    }
    return Error.InvalidExit;
}

fn parseHostPhase(value: []const u8) Error!host_runtime.HostPhase {
    if (std.mem.eql(u8, value, "starting")) return .starting;
    if (std.mem.eql(u8, value, "running")) return .running;
    if (std.mem.eql(u8, value, "exiting")) return .exiting;
    if (std.mem.eql(u8, value, "exited")) return .exited;
    return Error.InvalidHostPhase;
}

fn parseChildPhase(value: []const u8) Error!host_runtime.ChildPhase {
    if (std.mem.eql(u8, value, "starting")) return .starting;
    if (std.mem.eql(u8, value, "running")) return .running;
    if (std.mem.eql(u8, value, "exited")) return .exited;
    return Error.InvalidChildPhase;
}

fn parseSignal(value: []const u8) Error!host_runtime.Signal {
    if (std.mem.eql(u8, value, "int")) return .int;
    if (std.mem.eql(u8, value, "term")) return .term;
    if (std.mem.eql(u8, value, "kill")) return .kill;
    return Error.InvalidExit;
}

test "host_client parseLine classifies ok err and event" {
    {
        const line = try parseLine("ok host=running child=running");
        try std.testing.expect(line == .ok);
        try std.testing.expectEqualStrings("host=running child=running", line.ok);
    }
    {
        const line = try parseLine("err invalid_args");
        try std.testing.expect(line == .err);
        try std.testing.expectEqualStrings("invalid_args", line.err);
    }
    {
        const line = try parseLine("event child_exited code=0");
        try std.testing.expect(line == .event);
        try std.testing.expectEqualStrings("child_exited", line.event.kind);
        try std.testing.expectEqualStrings("code=0", line.event.rest);
    }
}

test "host_client parseStateView parses structured state payload" {
    const view = try parseStateView(
        "host=running child=running client_attached=false pid=123 size=80x24 exit=none",
    );
    try std.testing.expectEqual(host_runtime.HostPhase.running, view.host_phase);
    try std.testing.expectEqual(host_runtime.ChildPhase.running, view.child_phase);
    try std.testing.expectEqual(false, view.client_attached);
    try std.testing.expectEqual(@as(?std.posix.pid_t, 123), view.child_pid);
    try std.testing.expect(view.size != null);
    try std.testing.expectEqual(@as(u16, 80), view.size.?.cols);
    try std.testing.expectEqual(@as(u16, 24), view.size.?.rows);
    try std.testing.expectEqual(host_runtime.ExitInfo.none, view.exit_info);
}

test "host_client parseStateView accepts starting phases" {
    const view = try parseStateView(
        "host=starting child=starting client_attached=false pid=none size=none exit=none",
    );
    try std.testing.expectEqual(host_runtime.HostPhase.starting, view.host_phase);
    try std.testing.expectEqual(host_runtime.ChildPhase.starting, view.child_phase);
    try std.testing.expectEqual(false, view.client_attached);
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), view.child_pid);
    try std.testing.expectEqual(@as(?host_runtime.Size, null), view.size);
    try std.testing.expectEqual(host_runtime.ExitInfo.none, view.exit_info);
}

test "host_client parseErrorInfo splits kind and detail" {
    const info = parseErrorInfo("invalid_state reason=child_exited");
    try std.testing.expectEqualStrings("invalid_state", info.kind);
    try std.testing.expectEqualStrings("reason=child_exited", info.detail);
}

test "host_client readLine supports plain read readers" {
    const Reader = struct {
        bytes: []const u8,
        index: usize = 0,

        pub fn read(self: *@This(), out: []u8) !usize {
            if (self.index >= self.bytes.len) return 0;
            out[0] = self.bytes[self.index];
            self.index += 1;
            return 1;
        }
    };

    var reader = Reader{ .bytes = "event ready\nok host=running\n" };
    var buf: [128]u8 = undefined;

    const first = try readLine(&reader, &buf);
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("event ready", first.?);

    const second = try readLine(&reader, &buf);
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("ok host=running", second.?);
}

test "host_client roundTrip tolerates interleaved events" {
    const FakeReader = struct {
        lines: []const []const u8,
        index: usize = 0,

        pub fn readUntilDelimiterOrEof(self: *@This(), buf: []u8, delimiter: u8) !?[]u8 {
            _ = delimiter;
            if (self.index >= self.lines.len) return null;
            const line = self.lines[self.index];
            self.index += 1;
            @memcpy(buf[0..line.len], line);
            return buf[0..line.len];
        }
    };

    const FakeWriter = struct {
        bytes: std.ArrayList(u8),

        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.bytes.appendSlice(std.testing.allocator, bytes);
        }

        pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            const text = try std.fmt.allocPrint(std.testing.allocator, fmt, args);
            defer std.testing.allocator.free(text);
            try self.bytes.appendSlice(std.testing.allocator, text);
        }
    };

    const Capture = struct {
        kinds: std.ArrayList([]u8),

        fn onEvent(ctx: ?*anyopaque, event: Event) void {
            const Self = @This();
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const copy = std.testing.allocator.dupe(u8, event.kind) catch unreachable;
            self.kinds.append(std.testing.allocator, copy) catch unreachable;
        }
    };

    var reader = FakeReader{ .lines = &.{ "event ready", "event client_connected", "ok host=running" } };
    var writer = FakeWriter{ .bytes = .empty };
    defer writer.bytes.deinit(std.testing.allocator);

    var capture = Capture{ .kinds = .empty };
    defer {
        for (capture.kinds.items) |item| std.testing.allocator.free(item);
        capture.kinds.deinit(std.testing.allocator);
    }

    var buf: [256]u8 = undefined;
    const response = try roundTrip(
        &writer,
        &reader,
        .{ .ctx = &capture, .onEventFn = Capture.onEvent },
        .state,
        &buf,
    );

    try std.testing.expect(response == .ok);
    try std.testing.expectEqualStrings("host=running", response.ok);
    try std.testing.expectEqualStrings("state\n", writer.bytes.items);
    try std.testing.expectEqual(@as(usize, 2), capture.kinds.items.len);
    try std.testing.expectEqualStrings("ready", capture.kinds.items[0]);
    try std.testing.expectEqualStrings("client_connected", capture.kinds.items[1]);
}

test "host_client state helper parses typed state through interleaved events" {
    const FakeReader = struct {
        lines: []const []const u8,
        index: usize = 0,

        pub fn readUntilDelimiterOrEof(self: *@This(), buf: []u8, delimiter: u8) !?[]u8 {
            _ = delimiter;
            if (self.index >= self.lines.len) return null;
            const line = self.lines[self.index];
            self.index += 1;
            @memcpy(buf[0..line.len], line);
            return buf[0..line.len];
        }
    };

    const FakeWriter = struct {
        bytes: std.ArrayList(u8),

        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.bytes.appendSlice(std.testing.allocator, bytes);
        }

        pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            const text = try std.fmt.allocPrint(std.testing.allocator, fmt, args);
            defer std.testing.allocator.free(text);
            try self.bytes.appendSlice(std.testing.allocator, text);
        }
    };

    var reader = FakeReader{ .lines = &.{
        "event ready",
        "event resized cols=120 rows=40",
        "ok host=running child=running client_attached=true pid=42 size=120x40 exit=none",
    } };
    var writer = FakeWriter{ .bytes = .empty };
    defer writer.bytes.deinit(std.testing.allocator);

    var buf: [256]u8 = undefined;
    const view = try state(&writer, &reader, null, &buf);

    try std.testing.expectEqualStrings("state\n", writer.bytes.items);
    try std.testing.expectEqual(host_runtime.HostPhase.running, view.host_phase);
    try std.testing.expectEqual(host_runtime.ChildPhase.running, view.child_phase);
    try std.testing.expectEqual(true, view.client_attached);
    try std.testing.expectEqual(@as(?std.posix.pid_t, 42), view.child_pid);
    try std.testing.expect(view.size != null);
    try std.testing.expectEqual(@as(u16, 120), view.size.?.cols);
    try std.testing.expectEqual(@as(u16, 40), view.size.?.rows);
}

test "host_client roundTrip rejects malformed line" {
    const FakeReader = struct {
        lines: []const []const u8,
        index: usize = 0,

        pub fn readUntilDelimiterOrEof(self: *@This(), buf: []u8, delimiter: u8) !?[]u8 {
            _ = delimiter;
            if (self.index >= self.lines.len) return null;
            const line = self.lines[self.index];
            self.index += 1;
            @memcpy(buf[0..line.len], line);
            return buf[0..line.len];
        }
    };

    const FakeWriter = struct {
        bytes: std.ArrayList(u8),

        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.bytes.appendSlice(std.testing.allocator, bytes);
        }

        pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            const text = try std.fmt.allocPrint(std.testing.allocator, fmt, args);
            defer std.testing.allocator.free(text);
            try self.bytes.appendSlice(std.testing.allocator, text);
        }
    };

    var reader = FakeReader{ .lines = &.{ "wat nonsense", "ok" } };
    var writer = FakeWriter{ .bytes = .empty };
    defer writer.bytes.deinit(std.testing.allocator);

    var buf: [256]u8 = undefined;
    try std.testing.expectError(Error.InvalidLine, roundTrip(&writer, &reader, null, .exit, &buf));
    try std.testing.expectEqualStrings("exit\n", writer.bytes.items);
}
