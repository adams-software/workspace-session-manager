const std = @import("std");
const ui_state = @import("ui_state.zig");

pub const Text = struct {
    bytes: [4]u8 = undefined,
    len: u3,

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Event = union(enum) {
    key: ui_state.Key,
    text: Text,
};

pub const Decoder = struct {
    escape_state: enum { idle, escape, csi } = .idle,
    utf8_bytes: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_expected: u3 = 0,

    pub fn feed(self: *Decoder, byte: u8) ?Event {
        return switch (self.escape_state) {
            .idle => self.feedTextOrControl(byte),
            .escape => if (byte == '[') blk: {
                self.escape_state = .csi;
                break :blk null;
            } else blk: {
                self.escape_state = .idle;
                break :blk .{ .key = .esc };
            },
            .csi => blk: {
                self.escape_state = .idle;
                break :blk .{ .key = switch (byte) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    else => .esc,
                } };
            },
        };
    }

    fn feedTextOrControl(self: *Decoder, byte: u8) ?Event {
        if (self.utf8_len > 0) {
            if (byte & 0xc0 != 0x80) {
                self.clearUtf8();
                return self.feedTextOrControl(byte);
            }
            self.utf8_bytes[self.utf8_len] = byte;
            self.utf8_len += 1;
            if (self.utf8_len < self.utf8_expected) return null;

            const len = self.utf8_len;
            _ = std.unicode.utf8Decode(self.utf8_bytes[0..len]) catch {
                self.clearUtf8();
                return null;
            };
            const event = Event{ .text = .{ .bytes = self.utf8_bytes, .len = len } };
            self.clearUtf8();
            return event;
        }

        if (byte == 0x1b) {
            self.escape_state = .escape;
            return null;
        }
        if (ui_state.Key.fromByte(byte)) |key| return .{ .key = key };
        if (byte >= 0x20 and byte <= 0x7e) return textEvent(&.{byte});

        const expected = std.unicode.utf8ByteSequenceLength(byte) catch return null;
        if (expected == 1) return null;
        self.utf8_bytes[0] = byte;
        self.utf8_len = 1;
        self.utf8_expected = expected;
        return null;
    }

    pub fn hasPendingEscape(self: *const Decoder) bool {
        return self.escape_state != .idle;
    }

    pub fn hasPendingText(self: *const Decoder) bool {
        return self.utf8_len != 0;
    }

    pub fn flushEscape(self: *Decoder) ?Event {
        if (!self.hasPendingEscape()) return null;
        self.escape_state = .idle;
        return .{ .key = .esc };
    }

    pub fn reset(self: *Decoder) void {
        self.escape_state = .idle;
        self.clearUtf8();
    }

    fn clearUtf8(self: *Decoder) void {
        self.utf8_len = 0;
        self.utf8_expected = 0;
    }
};

fn textEvent(bytes: []const u8) Event {
    var value = Text{ .len = @intCast(bytes.len) };
    @memcpy(value.bytes[0..bytes.len], bytes);
    return .{ .text = value };
}

test "arrow keys decode across every read boundary" {
    const sequence = "\x1b[A";
    for (0..sequence.len + 1) |split| {
        var decoder = Decoder{};
        var decoded: ?Event = null;
        for (sequence[0..split]) |byte| decoded = decoder.feed(byte) orelse decoded;
        for (sequence[split..]) |byte| decoded = decoder.feed(byte) orelse decoded;
        try std.testing.expectEqual(ui_state.Key.up, decoded.?.key);
        try std.testing.expect(!decoder.hasPendingEscape());
    }
}

test "UTF-8 text decodes across every read boundary" {
    const input = "a🙂e\u{301}👍🏽";
    for (0..input.len + 1) |split| {
        var decoder = Decoder{};
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        for (input[0..split]) |byte| if (decoder.feed(byte)) |event| switch (event) {
            .text => |value| try output.appendSlice(std.testing.allocator, value.slice()),
            .key => return error.TestUnexpectedResult,
        };
        for (input[split..]) |byte| if (decoder.feed(byte)) |event| switch (event) {
            .text => |value| try output.appendSlice(std.testing.allocator, value.slice()),
            .key => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqualStrings(input, output.items);
        try std.testing.expect(!decoder.hasPendingText());
    }
}

test "lone and unknown escapes resolve to menu escape" {
    var decoder = Decoder{};
    try std.testing.expect(decoder.feed(0x1b) == null);
    try std.testing.expectEqual(ui_state.Key.esc, decoder.flushEscape().?.key);

    try std.testing.expect(decoder.feed(0x1b) == null);
    try std.testing.expect(decoder.feed('[') == null);
    try std.testing.expectEqual(ui_state.Key.esc, decoder.feed('Z').?.key);
    try std.testing.expect(!decoder.hasPendingEscape());
}

test "invalid UTF-8 is discarded without swallowing the next key" {
    var decoder = Decoder{};
    try std.testing.expect(decoder.feed(0xf0) == null);
    try std.testing.expect(decoder.feed(0x9f) == null);
    try std.testing.expectEqualStrings("j", decoder.feed('j').?.text.slice());

    try std.testing.expect(decoder.feed(0xc0) == null);
    try std.testing.expect(decoder.feed(0x80) == null);
    try std.testing.expect(!decoder.hasPendingText());
}

test "multiple keys in one read remain distinct" {
    var decoder = Decoder{};
    const input = "j\x07";
    try std.testing.expectEqualStrings("j", decoder.feed(input[0]).?.text.slice());
    try std.testing.expectEqual(ui_state.Key.ctrl_g, decoder.feed(input[1]).?.key);
}
