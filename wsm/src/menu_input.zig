const std = @import("std");
const ui_state = @import("ui_state.zig");

pub const Decoder = struct {
    state: enum { idle, escape, csi } = .idle,

    pub fn feed(self: *Decoder, byte: u8) ?ui_state.Key {
        return switch (self.state) {
            .idle => if (byte == 0x1b) blk: {
                self.state = .escape;
                break :blk null;
            } else ui_state.Key.fromByte(byte),
            .escape => if (byte == '[') blk: {
                self.state = .csi;
                break :blk null;
            } else blk: {
                self.state = .idle;
                break :blk .esc;
            },
            .csi => blk: {
                self.state = .idle;
                break :blk switch (byte) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    else => .esc,
                };
            },
        };
    }

    pub fn hasPending(self: *const Decoder) bool {
        return self.state != .idle;
    }

    pub fn flush(self: *Decoder) ?ui_state.Key {
        if (!self.hasPending()) return null;
        self.state = .idle;
        return .esc;
    }

    pub fn reset(self: *Decoder) void {
        self.state = .idle;
    }
};

test "arrow keys decode across every read boundary" {
    const sequence = "\x1b[A";
    for (0..sequence.len + 1) |split| {
        var decoder = Decoder{};
        var decoded: ?ui_state.Key = null;
        for (sequence[0..split]) |byte| decoded = decoder.feed(byte) orelse decoded;
        for (sequence[split..]) |byte| decoded = decoder.feed(byte) orelse decoded;
        try std.testing.expectEqual(ui_state.Key.up, decoded.?);
        try std.testing.expect(!decoder.hasPending());
    }
}

test "lone and unknown escapes resolve to menu escape" {
    var decoder = Decoder{};
    try std.testing.expect(decoder.feed(0x1b) == null);
    try std.testing.expectEqual(ui_state.Key.esc, decoder.flush().?);

    try std.testing.expect(decoder.feed(0x1b) == null);
    try std.testing.expect(decoder.feed('[') == null);
    try std.testing.expectEqual(ui_state.Key.esc, decoder.feed('Z').?);
    try std.testing.expect(!decoder.hasPending());
}

test "multiple keys in one read remain distinct" {
    var decoder = Decoder{};
    const input = "j\x07";
    try std.testing.expectEqual(ui_state.Key{ .printable = 'j' }, decoder.feed(input[0]).?);
    try std.testing.expectEqual(ui_state.Key.ctrl_g, decoder.feed(input[1]).?);
}
