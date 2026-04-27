const ctlwire = @import("root.zig");
const message = ctlwire.message;
const line = ctlwire.line;

pub const EventSink = struct {
    ctx: ?*anyopaque,
    onEventFn: *const fn (ctx: ?*anyopaque, event: message.EventLine) void,

    pub fn emit(self: EventSink, event: message.EventLine) void {
        self.onEventFn(self.ctx, event);
    }
};

pub fn roundTrip(
    writer: anytype,
    reader: anytype,
    event_sink: ?EventSink,
    command: []const u8,
    buf: []u8,
) !message.Line {
    try writeAllCompat(writer, command);
    if (command.len == 0 or command[command.len - 1] != '\n') try writeByteCompat(writer, '\n');

    while (true) {
        const maybe_line = try line.readLine(reader, buf);
        const raw = maybe_line orelse return error.UnexpectedEof;
        switch (try message.parseLine(raw)) {
            .ok => |payload| return .{ .ok = payload },
            .err => |err_line| return .{ .err = err_line },
            .event => |event| if (event_sink) |sink| sink.emit(event),
        }
    }
}

fn writeAllCompat(writer: anytype, bytes: []const u8) !void {
    if (@hasField(@TypeOf(writer.*), "interface")) {
        try writer.interface.writeAll(bytes);
        return;
    }
    if (@hasDecl(@TypeOf(writer.*), "writeAll")) {
        try writer.writeAll(bytes);
        return;
    }
    return error.UnsupportedWriter;
}

fn writeByteCompat(writer: anytype, byte: u8) !void {
    if (@hasField(@TypeOf(writer.*), "interface")) {
        try writer.interface.writeByte(byte);
        return;
    }
    if (@hasDecl(@TypeOf(writer.*), "writeAll")) {
        var one = [1]u8{byte};
        try writer.writeAll(&one);
        return;
    }
    return error.UnsupportedWriter;
}
