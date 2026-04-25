const std = @import("std");
const host_control = @import("host_control");
const host_runtime = @import("host_runtime");

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

pub const Error = error{
    InvalidLine,
    UnexpectedEof,
    RequestInFlight,
};

pub const EventSink = struct {
    ctx: ?*anyopaque,
    onEventFn: *const fn (ctx: ?*anyopaque, event: Event) void,

    pub fn emit(self: EventSink, event: Event) void {
        self.onEventFn(self.ctx, event);
    }
};

pub fn formatCommand(writer: anytype, command: host_control.Command) !void {
    switch (command) {
        .state => try writer.writeAll("state\n"),
        .resize => |size| try writer.print("resize {d} {d}\n", .{ size.cols, size.rows }),
        .signal => |sig| try writer.print("signal {s}\n", .{@tagName(sig)}),
        .exit => try writer.writeAll("exit\n"),
    }
}

pub fn parseLine(line: []const u8) Error!Line {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return Error.InvalidLine;

    if (std.mem.eql(u8, trimmed, "ok")) return .{ .ok = "" };
    if (std.mem.startsWith(u8, trimmed, "ok ")) return .{ .ok = trimmed[3..] };
    if (std.mem.startsWith(u8, trimmed, "err ")) return .{ .err = trimmed[4..] };
    if (std.mem.eql(u8, trimmed, "event")) return Error.InvalidLine;
    if (std.mem.startsWith(u8, trimmed, "event ")) {
        const rest = trimmed[6..];
        const space = std.mem.indexOfScalar(u8, rest, ' ');
        if (space) |i| {
            return .{ .event = .{ .kind = rest[0..i], .rest = rest[(i + 1)..] } };
        }
        return .{ .event = .{ .kind = rest, .rest = "" } };
    }
    return Error.InvalidLine;
}

pub fn roundTrip(
    writer: anytype,
    reader: anytype,
    event_sink: ?EventSink,
    command: host_control.Command,
    buf: []u8,
) !Response {
    try formatCommand(writer, command);

    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEof(buf, '\n');
        const line = maybe_line orelse return Error.UnexpectedEof;
        switch (try parseLine(line)) {
            .ok => |rest| return .{ .ok = rest },
            .err => |rest| return .{ .err = rest },
            .event => |event| {
                if (event_sink) |sink| sink.emit(event);
            },
        }
    }
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

test "host_client roundTrip tolerates interleaved events" {
    const FakeReader = struct {
        lines: []const []const u8,
        index: usize = 0,

        fn readUntilDelimiterOrEof(self: *@This(), buf: []u8, delimiter: u8) !?[]u8 {
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

        fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.bytes.appendSlice(std.testing.allocator, bytes);
        }

        fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
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
    var writer = FakeWriter{ .bytes = .{} };
    defer writer.bytes.deinit(std.testing.allocator);

    var capture = Capture{ .kinds = .{} };
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
