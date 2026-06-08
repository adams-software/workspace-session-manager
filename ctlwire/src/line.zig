const std = @import("std");

fn trimFraming(line_text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line_text, "\r\n");
}

pub const Error = error{
    InvalidLine,
    UnexpectedEof,
};

pub fn readLine(reader: anytype, buf: []u8) !?[]u8 {
    if (@hasDecl(@TypeOf(reader.*), "readUntilDelimiterOrEof")) {
        while (true) {
            const maybe = try reader.readUntilDelimiterOrEof(buf, '\n');
            const raw = maybe orelse return null;
            const trimmed = trimFraming(raw);
            if (trimmed.len == 0) continue;
            return @constCast(trimmed);
        }
    }
    if (@hasField(@TypeOf(reader.*), "interface")) {
        while (true) {
            const line_text = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
                error.EndOfStream => return null,
                error.ReadFailed => return Error.UnexpectedEof,
                error.StreamTooLong => return Error.InvalidLine,
            };
            const trimmed = trimFraming(line_text);
            if (trimmed.len == 0) continue;
            return trimmed;
        }
    }
    return readLineBytewise(reader, buf);
}

fn readLineBytewise(reader: anytype, buf: []u8) !?[]u8 {
    var used: usize = 0;
    while (true) {
        if (used >= buf.len) return Error.InvalidLine;
        const n = try readCompat(reader, buf[used .. used + 1]);
        if (n == 0) {
            if (used == 0) return null;
            return @constCast(trimFraming(buf[0..used]));
        }
        const b = buf[used];
        if (b == '\n' or b == '\r') {
            const line_text = trimFraming(buf[0..used]);
            if (line_text.len == 0) {
                used = 0;
                continue;
            }
            return @constCast(line_text);
        }
        used += 1;
    }
}

fn readCompat(reader: anytype, out: []u8) !usize {
    if (@hasField(@TypeOf(reader.*), "interface")) {
        return try reader.interface.read(out);
    }
    if (@hasDecl(@TypeOf(reader.*), "read")) {
        return try reader.read(out);
    }
    return Error.InvalidLine;
}
