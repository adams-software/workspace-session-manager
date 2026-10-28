const std = @import("std");

pub const bracketed_paste_start = "\x1b[200~";
pub const bracketed_paste_end = "\x1b[201~";
pub const max_deferred_bytes = bracketed_paste_start.len - 1;

pub const Result = struct {
    consumed: usize,
    child_len: usize,
    hotkey: bool,
};

pub const Router = struct {
    hotkey: u8,
    state: enum { child, paste } = .child,
    pending: [bracketed_paste_start.len]u8 = undefined,
    pending_len: usize = 0,

    pub fn init(hotkey: u8) Router {
        return .{ .hotkey = hotkey };
    }

    /// Routes bytes owned by the child into `child_output` until a hotkey changes
    /// ownership. The caller owns `input[result.consumed..]`; it is deliberately
    /// left untouched so the new owner can interpret it.
    pub fn route(self: *Router, input: []const u8, child_output: []u8) Result {
        std.debug.assert(child_output.len >= input.len + self.pending_len);
        var child_len: usize = 0;

        for (input, 0..) |byte, index| {
            self.pending[self.pending_len] = byte;
            self.pending_len += 1;

            const hotkey = switch (self.state) {
                .child => self.processChild(child_output, &child_len),
                .paste => blk: {
                    self.processPaste(child_output, &child_len);
                    break :blk false;
                },
            };
            if (hotkey) return .{ .consumed = index + 1, .child_len = child_len, .hotkey = true };
        }

        return .{ .consumed = input.len, .child_len = child_len, .hotkey = false };
    }

    /// Releases an incomplete paste-marker prefix after the caller's input
    /// ambiguity timeout. The current paste state is unchanged.
    pub fn flushPending(self: *Router, child_output: []u8) usize {
        std.debug.assert(child_output.len >= self.pending_len);
        const count = self.pending_len;
        @memcpy(child_output[0..count], self.pending[0..count]);
        self.pending_len = 0;
        return count;
    }

    pub fn inPaste(self: *const Router) bool {
        return self.state == .paste;
    }

    fn processChild(self: *Router, output: []u8, output_len: *usize) bool {
        while (self.pending_len > 0) {
            if (std.mem.startsWith(u8, bracketed_paste_start, self.pending[0..self.pending_len])) {
                if (self.pending_len == bracketed_paste_start.len) {
                    append(output, output_len, self.pending[0..self.pending_len]);
                    self.pending_len = 0;
                    self.state = .paste;
                }
                return false;
            }
            if (self.pending[0] == self.hotkey) {
                self.discardFirst();
                return true;
            }
            appendByte(output, output_len, self.pending[0]);
            self.discardFirst();
        }
        return false;
    }

    fn processPaste(self: *Router, output: []u8, output_len: *usize) void {
        while (self.pending_len > 0) {
            if (std.mem.startsWith(u8, bracketed_paste_end, self.pending[0..self.pending_len])) {
                if (self.pending_len == bracketed_paste_end.len) {
                    append(output, output_len, self.pending[0..self.pending_len]);
                    self.pending_len = 0;
                    self.state = .child;
                }
                return;
            }
            appendByte(output, output_len, self.pending[0]);
            self.discardFirst();
        }
    }

    fn discardFirst(self: *Router) void {
        std.mem.copyForwards(u8, self.pending[0 .. self.pending_len - 1], self.pending[1..self.pending_len]);
        self.pending_len -= 1;
    }
};

fn append(output: []u8, output_len: *usize, bytes: []const u8) void {
    @memcpy(output[output_len.* .. output_len.* + bytes.len], bytes);
    output_len.* += bytes.len;
}

fn appendByte(output: []u8, output_len: *usize, byte: u8) void {
    output[output_len.*] = byte;
    output_len.* += 1;
}

test "hotkey splits child bytes from bytes owned by the menu" {
    var router = Router.init(0x07);
    const input = "child\x07menu\x07tail";
    var child: [input.len + max_deferred_bytes]u8 = undefined;

    const result = router.route(input, &child);

    try std.testing.expect(result.hotkey);
    try std.testing.expectEqual(@as(usize, "child\x07".len), result.consumed);
    try std.testing.expectEqualStrings("child", child[0..result.child_len]);
    try std.testing.expectEqualStrings("menu\x07tail", input[result.consumed..]);
}

test "hotkey inside bracketed paste is child data across every read boundary" {
    const input = "before\x1b[200~paste\x07data\x1b[201~after\x07menu";
    const expected_child = "before\x1b[200~paste\x07data\x1b[201~after";

    for (0..input.len + 1) |split| {
        var router = Router.init(0x07);
        var child: [input.len + max_deferred_bytes]u8 = undefined;
        var child_len: usize = 0;

        const first = router.route(input[0..split], child[child_len..]);
        child_len += first.child_len;
        if (first.hotkey) {
            try std.testing.expectEqualStrings(expected_child, child[0..child_len]);
            continue;
        }

        const second = router.route(input[split..], child[child_len..]);
        child_len += second.child_len;
        try std.testing.expect(second.hotkey);
        try std.testing.expectEqualStrings(expected_child, child[0..child_len]);
        try std.testing.expect(!router.inPaste());
    }
}

test "prefix-like input and UTF-8 remain byte exact" {
    var router = Router.init(0x07);
    const input = "a\x1b[20x🙂\x1b[201x\x07z";
    var child: [input.len + max_deferred_bytes]u8 = undefined;

    const result = router.route(input, &child);

    try std.testing.expect(result.hotkey);
    try std.testing.expectEqualStrings("a\x1b[20x🙂\x1b[201x", child[0..result.child_len]);
    try std.testing.expectEqualStrings("z", input[result.consumed..]);
}

test "incomplete marker prefix can be released without changing paste state" {
    var router = Router.init(0x07);
    var child: [32]u8 = undefined;

    const first = router.route("\x1b[20", &child);
    try std.testing.expectEqual(@as(usize, 0), first.child_len);
    const flushed = router.flushPending(&child);
    try std.testing.expectEqualStrings("\x1b[20", child[0..flushed]);
    try std.testing.expect(!router.inPaste());

    const paste = router.route("\x1b[200~x\x1b[20", &child);
    try std.testing.expect(router.inPaste());
    const paste_flushed = router.flushPending(child[paste.child_len..]);
    try std.testing.expectEqualStrings("\x1b[20", child[paste.child_len .. paste.child_len + paste_flushed]);
    try std.testing.expect(router.inPaste());
}
