const std = @import("std");

pub const ErrorLine = struct {
    kind: []const u8,
    detail: []const u8 = "",
};

pub const EventLine = struct {
    kind: []const u8,
    payload: []const u8 = "",
};

pub const Line = union(enum) {
    ok: []const u8,
    err: ErrorLine,
    event: EventLine,
};

pub const Error = error{
    InvalidLine,
};

pub fn parseLine(line: []const u8) Error!Line {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return Error.InvalidLine;

    if (std.mem.eql(u8, trimmed, "ok")) return .{ .ok = "" };
    if (std.mem.startsWith(u8, trimmed, "ok ")) return .{ .ok = trimmed[3..] };

    if (std.mem.startsWith(u8, trimmed, "err ")) {
        const rest = trimmed[4..];
        const space = std.mem.indexOfScalar(u8, rest, ' ');
        if (space) |i| {
            return .{ .err = .{ .kind = rest[0..i], .detail = rest[(i + 1)..] } };
        }
        return .{ .err = .{ .kind = rest } };
    }

    if (std.mem.eql(u8, trimmed, "event")) return Error.InvalidLine;
    if (std.mem.startsWith(u8, trimmed, "event ")) {
        const rest = trimmed[6..];
        const space = std.mem.indexOfScalar(u8, rest, ' ');
        if (space) |i| {
            return .{ .event = .{ .kind = rest[0..i], .payload = rest[(i + 1)..] } };
        }
        return .{ .event = .{ .kind = rest } };
    }

    return Error.InvalidLine;
}

pub fn writeOk(writer: anytype) !void {
    try writer.writeAll("ok\n");
}

pub fn writeOkPayload(writer: anytype, payload: []const u8) !void {
    if (payload.len == 0) return writeOk(writer);
    try writer.print("ok {s}\n", .{payload});
}

pub fn writeErr(writer: anytype, err: ErrorLine) !void {
    if (err.detail.len == 0) {
        try writer.print("err {s}\n", .{err.kind});
    } else {
        try writer.print("err {s} {s}\n", .{ err.kind, err.detail });
    }
}

pub fn writeEvent(writer: anytype, event: EventLine) !void {
    if (event.payload.len == 0) {
        try writer.print("event {s}\n", .{event.kind});
    } else {
        try writer.print("event {s} {s}\n", .{ event.kind, event.payload });
    }
}
