const std = @import("std");
const ByteQueue = @import("byte_queue").ByteQueue;

pub const prefix = "\x1bP+wsm;";
pub const suffix = "\x1b\\";
pub const max_token_len = 64;
pub const max_frame_len = prefix.len + "resume;".len + max_token_len + suffix.len;

pub const Action = enum { yielded, resumed };

pub const Frame = struct {
    action: Action,
    token: [max_token_len]u8 = undefined,
    token_len: u8,

    pub fn tokenSlice(self: *const Frame) []const u8 {
        return self.token[0..self.token_len];
    }
};

pub const Decoder = struct {
    state: enum { scanning, frame } = .scanning,
    pending: [max_frame_len]u8 = undefined,
    pending_len: usize = 0,

    pub fn bufferedBytes(self: *const Decoder) usize {
        return self.pending_len;
    }

    pub fn feedByte(self: *Decoder, allocator: std.mem.Allocator, output: *ByteQueue, byte: u8) !?Frame {
        self.pending[self.pending_len] = byte;
        self.pending_len += 1;

        return switch (self.state) {
            .scanning => self.scanForPrefix(allocator, output),
            .frame => self.finishFrameOrFlush(allocator, output),
        };
    }

    pub fn finish(self: *Decoder, allocator: std.mem.Allocator, output: *ByteQueue) !void {
        try output.append(allocator, self.pending[0..self.pending_len]);
        self.reset();
    }

    fn scanForPrefix(self: *Decoder, allocator: std.mem.Allocator, output: *ByteQueue) !?Frame {
        while (!std.mem.startsWith(u8, prefix, self.pending[0..self.pending_len])) {
            try output.appendByte(allocator, self.pending[0]);
            self.discardFirst();
        }
        if (self.pending_len == prefix.len) self.state = .frame;
        return null;
    }

    fn finishFrameOrFlush(self: *Decoder, allocator: std.mem.Allocator, output: *ByteQueue) !?Frame {
        if (self.pending_len >= suffix.len and std.mem.endsWith(u8, self.pending[0..self.pending_len], suffix)) {
            const parsed = parseFrame(self.pending[0..self.pending_len]);
            if (parsed) |frame| {
                self.reset();
                return frame;
            }
            try output.append(allocator, self.pending[0..self.pending_len]);
            self.reset();
            return null;
        }
        if (self.pending_len == self.pending.len) {
            try output.append(allocator, self.pending[0..self.pending_len]);
            self.reset();
        }
        return null;
    }

    fn discardFirst(self: *Decoder) void {
        std.mem.copyForwards(u8, self.pending[0 .. self.pending_len - 1], self.pending[1..self.pending_len]);
        self.pending_len -= 1;
    }

    fn reset(self: *Decoder) void {
        self.state = .scanning;
        self.pending_len = 0;
    }
};

fn parseFrame(bytes: []const u8) ?Frame {
    if (!std.mem.startsWith(u8, bytes, prefix) or !std.mem.endsWith(u8, bytes, suffix)) return null;
    const body = bytes[prefix.len .. bytes.len - suffix.len];
    const separator = std.mem.indexOfScalar(u8, body, ';') orelse return null;
    const action_text = body[0..separator];
    const token = body[separator + 1 ..];
    if (token.len == 0 or token.len > max_token_len) return null;
    for (token) |byte| if (!std.ascii.isHex(byte)) return null;

    var frame = Frame{
        .action = if (std.mem.eql(u8, action_text, "yield")) .yielded else if (std.mem.eql(u8, action_text, "resume")) .resumed else return null,
        .token_len = @intCast(token.len),
    };
    @memcpy(frame.token[0..token.len], token);
    return frame;
}

fn feedChunks(decoder: *Decoder, output: *ByteQueue, chunks: []const []const u8, frames: *std.ArrayList(Frame)) !void {
    for (chunks) |chunk| {
        for (chunk) |byte| {
            if (try decoder.feedByte(std.testing.allocator, output, byte)) |frame| try frames.append(std.testing.allocator, frame);
        }
    }
}

test "decoder strips a frame at every read boundary and preserves surrounding bytes" {
    const wire = "before\x1bP+wsm;yield;0123abcdef\x1b\\after";
    for (0..wire.len + 1) |split| {
        var decoder = Decoder{};
        var output = ByteQueue.init();
        defer output.deinit(std.testing.allocator);
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(std.testing.allocator);
        const chunks = [_][]const u8{ wire[0..split], wire[split..] };
        try feedChunks(&decoder, &output, &chunks, &frames);

        try std.testing.expectEqualStrings("beforeafter", output.readableSlice());
        try std.testing.expectEqual(@as(usize, 1), frames.items.len);
        try std.testing.expectEqual(Action.yielded, frames.items[0].action);
        try std.testing.expectEqualStrings("0123abcdef", frames.items[0].tokenSlice());
    }
}

test "decoder handles multiple frames and prefix-like ordinary output" {
    var decoder = Decoder{};
    var output = ByteQueue.init();
    defer output.deinit(std.testing.allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(std.testing.allocator);
    const chunks = [_][]const u8{
        "a\x1bP+ws",
        "x\x1bP+wsm;yield;aa\x1b\\b\x1bP+wsm;resume;bb\x1b\\c",
    };
    try feedChunks(&decoder, &output, &chunks, &frames);
    try decoder.finish(std.testing.allocator, &output);

    try std.testing.expectEqualStrings("a\x1bP+wsxbc", output.readableSlice());
    try std.testing.expectEqual(@as(usize, 2), frames.items.len);
    try std.testing.expectEqual(Action.yielded, frames.items[0].action);
    try std.testing.expectEqual(Action.resumed, frames.items[1].action);
}

test "decoder preserves malformed and unterminated frames" {
    var decoder = Decoder{};
    var output = ByteQueue.init();
    defer output.deinit(std.testing.allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(std.testing.allocator);
    const chunks = [_][]const u8{
        "\x1bP+wsm;other;abcd\x1b\\",
        "\x1bP+wsm;yield;not-hex\x1b\\",
        "\x1bP+wsm;yield;abcd",
    };
    try feedChunks(&decoder, &output, &chunks, &frames);
    try decoder.finish(std.testing.allocator, &output);

    try std.testing.expectEqualStrings("\x1bP+wsm;other;abcd\x1b\\\x1bP+wsm;yield;not-hex\x1b\\\x1bP+wsm;yield;abcd", output.readableSlice());
    try std.testing.expectEqual(@as(usize, 0), frames.items.len);
}
