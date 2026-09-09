const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");

// Routes terminal output by semantic effect: ordinary screen/model bytes stay on the
// virtual path, while selected outer-terminal control sequences are handled specially.
//
// Current policy:
// - OSC 52 is forwarded to the real terminal control channel
// - OSC 8 stays in screen/model bytes so vterm can own hyperlink state
// - selected terminal-mode CSI toggles are forwarded to the real terminal
// - other OSC/CSI content remains in screen bytes unless explicitly peeled off here

const State = enum {
    idle,
    esc,
    csi,
    csi_discard,
    osc,
    osc_seen_5,
    osc_seen_52,
    osc_52_body,
    osc_other_body,
    osc_maybe_st_52,
    osc_maybe_st_other,
    osc_discard,
    osc_discard_maybe_st,
};

const max_osc_bytes = 1024 * 1024;
const max_csi_bytes = 4096;

pub const FeedResult = struct {
    emitted_osc52: bool = false,
    screen_bytes: []const u8,
};

const TestStdoutActor = struct {
    allocator: std.mem.Allocator,
    controls: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) TestStdoutActor {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestStdoutActor) void {
        for (self.controls.items) |bytes| self.allocator.free(bytes);
        self.controls.deinit(self.allocator);
    }

    fn enqueueControl(self: *TestStdoutActor, chunk: actor_mailboxes.ControlChunk) !void {
        const owned = try self.allocator.dupe(u8, chunk.bytes);
        try self.controls.append(self.allocator, owned);
    }
};

pub const SideEffectForwarder = struct {
    allocator: std.mem.Allocator,
    state: State = .idle,
    osc_buf: std.ArrayList(u8),
    csi_buf: std.ArrayList(u8),
    screen_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) SideEffectForwarder {
        return .{
            .allocator = allocator,
            .state = .idle,
            .osc_buf = .empty,
            .csi_buf = .empty,
            .screen_buf = .empty,
        };
    }

    pub fn deinit(self: *SideEffectForwarder) void {
        self.osc_buf.deinit(self.allocator);
        self.csi_buf.deinit(self.allocator);
        self.screen_buf.deinit(self.allocator);
    }

    fn startOsc(self: *SideEffectForwarder) !void {
        self.osc_buf.clearRetainingCapacity();
        try self.osc_buf.appendSlice(self.allocator, "\x1b]");
        self.state = .osc;
    }

    fn appendOsc(self: *SideEffectForwarder, b: u8) !void {
        if (self.osc_buf.items.len >= max_osc_bytes) return error.OscTooLong;
        try self.osc_buf.append(self.allocator, b);
    }

    fn startCsi(self: *SideEffectForwarder) !void {
        self.csi_buf.clearRetainingCapacity();
        try self.csi_buf.appendSlice(self.allocator, "\x1b[");
        self.state = .csi;
    }

    fn appendCsi(self: *SideEffectForwarder, b: u8) !void {
        try self.csi_buf.append(self.allocator, b);
    }

    fn appendScreen(self: *SideEffectForwarder, b: u8) !void {
        try self.screen_buf.append(self.allocator, b);
    }

    fn appendScreenSlice(self: *SideEffectForwarder, bytes: []const u8) !void {
        try self.screen_buf.appendSlice(self.allocator, bytes);
    }

    fn flushOsc52(self: *SideEffectForwarder, stdout_actor: anytype) !void {
        try stdout_actor.enqueueControl(actor_mailboxes.ControlChunk{ .bytes = self.osc_buf.items });
    }

    fn isPassthroughCsi(self: *SideEffectForwarder) bool {
        const csi = self.csi_buf.items;
        return std.mem.eql(u8, csi, "\x1b[?1h") or
            std.mem.eql(u8, csi, "\x1b[?1l") or
            std.mem.eql(u8, csi, "\x1b[?2004h") or
            std.mem.eql(u8, csi, "\x1b[?2004l") or
            std.mem.eql(u8, csi, "\x1b[?1004h") or
            std.mem.eql(u8, csi, "\x1b[?1004l") or
            std.mem.eql(u8, csi, "\x1b[?1000h") or
            std.mem.eql(u8, csi, "\x1b[?1000l") or
            std.mem.eql(u8, csi, "\x1b[?1002h") or
            std.mem.eql(u8, csi, "\x1b[?1002l") or
            std.mem.eql(u8, csi, "\x1b[?1003h") or
            std.mem.eql(u8, csi, "\x1b[?1003l") or
            std.mem.eql(u8, csi, "\x1b[?1005h") or
            std.mem.eql(u8, csi, "\x1b[?1005l") or
            std.mem.eql(u8, csi, "\x1b[?1006h") or
            std.mem.eql(u8, csi, "\x1b[?1006l") or
            std.mem.eql(u8, csi, "\x1b[?1015h") or
            std.mem.eql(u8, csi, "\x1b[?1015l") or
            std.mem.eql(u8, csi, "\x1b[?2005h") or
            std.mem.eql(u8, csi, "\x1b[?2005l") or
            std.mem.eql(u8, csi, "\x1b[?2006h") or
            std.mem.eql(u8, csi, "\x1b[?2006l");
    }

    fn flushCsi(self: *SideEffectForwarder, stdout_actor: anytype) !void {
        if (self.isPassthroughCsi()) {
            try stdout_actor.enqueueControl(actor_mailboxes.ControlChunk{ .bytes = self.csi_buf.items });
        } else {
            try self.appendScreenSlice(self.csi_buf.items);
        }
        self.csi_buf.clearRetainingCapacity();
        self.state = .idle;
    }

    fn resetOsc(self: *SideEffectForwarder) void {
        self.osc_buf.clearRetainingCapacity();
        self.state = .idle;
    }

    fn discardOscByte(self: *SideEffectForwarder, b: u8) void {
        const terminated = b == 0x07 or (b == '\\' and (self.state == .osc_maybe_st_52 or self.state == .osc_maybe_st_other));
        self.osc_buf.clearRetainingCapacity();
        self.state = if (terminated) .idle else if (b == 0x1b) .osc_discard_maybe_st else .osc_discard;
    }

    pub fn feed(self: *SideEffectForwarder, stdout_actor: anytype, bytes: []const u8) !FeedResult {
        self.screen_buf.clearRetainingCapacity();
        var result = FeedResult{
            .emitted_osc52 = false,
            .screen_bytes = &.{},
        };

        for (bytes) |b| {
            switch (self.state) {
                .idle => {
                    if (b == 0x1b) {
                        self.state = .esc;
                    } else {
                        try self.appendScreen(b);
                    }
                },

                .esc => {
                    if (b == ']') {
                        try self.startOsc();
                    } else if (b == '[') {
                        try self.startCsi();
                    } else {
                        try self.appendScreen(0x1b);
                        try self.appendScreen(b);
                        self.state = .idle;
                    }
                },

                .csi => {
                    if (self.csi_buf.items.len >= max_csi_bytes) {
                        self.csi_buf.clearRetainingCapacity();
                        self.state = if (b >= 0x40 and b <= 0x7e) .idle else .csi_discard;
                        continue;
                    }
                    try self.appendCsi(b);
                    if (b >= 0x40 and b <= 0x7e) {
                        try self.flushCsi(stdout_actor);
                    }
                },

                .csi_discard => {
                    if (b >= 0x40 and b <= 0x7e) self.state = .idle;
                },

                .osc => {
                    self.appendOsc(b) catch {
                        self.discardOscByte(b);
                        continue;
                    };
                    if (b == '5') {
                        self.state = .osc_seen_5;
                    } else {
                        self.state = .osc_other_body;
                    }
                },

                .osc_seen_5 => {
                    self.appendOsc(b) catch {
                        self.discardOscByte(b);
                        continue;
                    };
                    if (b == '2') {
                        self.state = .osc_seen_52;
                    } else {
                        self.state = .osc_other_body;
                    }
                },

                .osc_seen_52 => {
                    self.appendOsc(b) catch {
                        self.discardOscByte(b);
                        continue;
                    };
                    if (b == ';') {
                        self.state = .osc_52_body;
                    } else {
                        self.state = .osc_other_body;
                    }
                },

                .osc_52_body => {
                    self.appendOsc(b) catch {
                        self.discardOscByte(b);
                        continue;
                    };

                    if (b == 0x07) {
                        try self.flushOsc52(stdout_actor);
                        result.emitted_osc52 = true;
                        self.resetOsc();
                    } else if (b == 0x1b) {
                        self.state = .osc_maybe_st_52;
                    }
                },

                .osc_other_body => {
                    self.appendOsc(b) catch {
                        self.discardOscByte(b);
                        continue;
                    };

                    if (b == 0x07) {
                        try self.appendScreenSlice(self.osc_buf.items);
                        self.resetOsc();
                    } else if (b == 0x1b) {
                        self.state = .osc_maybe_st_other;
                    }
                },

                .osc_maybe_st_52 => {
                    self.appendOsc(b) catch {
                        self.discardOscByte(b);
                        continue;
                    };

                    if (b == '\\') {
                        try self.flushOsc52(stdout_actor);
                        result.emitted_osc52 = true;
                        self.resetOsc();
                    } else {
                        self.state = .osc_52_body;
                    }
                },

                .osc_discard => {
                    if (b == 0x07) {
                        self.resetOsc();
                    } else if (b == 0x1b) {
                        self.state = .osc_discard_maybe_st;
                    }
                },

                .osc_discard_maybe_st => {
                    if (b == '\\') {
                        self.resetOsc();
                    } else if (b == 0x07) {
                        self.resetOsc();
                    } else if (b != 0x1b) {
                        self.state = .osc_discard;
                    }
                },

                .osc_maybe_st_other => {
                    self.appendOsc(b) catch {
                        self.discardOscByte(b);
                        continue;
                    };

                    if (b == '\\') {
                        try self.appendScreenSlice(self.osc_buf.items);
                        self.resetOsc();
                    } else {
                        self.state = .osc_other_body;
                    }
                },
            }
        }

        result.screen_bytes = self.screen_buf.items;
        return result;
    }
};

test "OSC 52 is passed through and removed from screen bytes" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    const input = "hello\x1b]52;c;Zm9v\x07world";
    const result = try forwarder.feed(&stdout_actor, input);

    try std.testing.expect(result.emitted_osc52);
    try std.testing.expectEqualStrings("helloworld", result.screen_bytes);
    try std.testing.expectEqual(@as(usize, 1), stdout_actor.controls.items.len);
    try std.testing.expectEqualStrings("\x1b]52;c;Zm9v\x07", stdout_actor.controls.items[0]);
}

test "bracketed paste mode enable is passed through and removed from screen bytes" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    const input = "a\x1b[?2004hb";
    const result = try forwarder.feed(&stdout_actor, input);

    try std.testing.expect(!result.emitted_osc52);
    try std.testing.expectEqualStrings("ab", result.screen_bytes);
    try std.testing.expectEqual(@as(usize, 1), stdout_actor.controls.items.len);
    try std.testing.expectEqualStrings("\x1b[?2004h", stdout_actor.controls.items[0]);
}

test "bracketed paste mode disable is passed through and removed from screen bytes" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    const input = "a\x1b[?2004lb";
    const result = try forwarder.feed(&stdout_actor, input);

    try std.testing.expectEqualStrings("ab", result.screen_bytes);
    try std.testing.expectEqual(@as(usize, 1), stdout_actor.controls.items.len);
    try std.testing.expectEqualStrings("\x1b[?2004l", stdout_actor.controls.items[0]);
}

test "split chunk bracketed paste CSI is passed through only after completion" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    const first = try forwarder.feed(&stdout_actor, "x\x1b[?20");
    try std.testing.expectEqualStrings("x", first.screen_bytes);
    try std.testing.expectEqual(@as(usize, 0), stdout_actor.controls.items.len);

    const second = try forwarder.feed(&stdout_actor, "04hy");
    try std.testing.expectEqualStrings("y", second.screen_bytes);
    try std.testing.expectEqual(@as(usize, 1), stdout_actor.controls.items.len);
    try std.testing.expectEqualStrings("\x1b[?2004h", stdout_actor.controls.items[0]);
}

test "focus reporting enable is passed through and removed from screen bytes" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    const input = "a\x1b[?1004hb";
    const result = try forwarder.feed(&stdout_actor, input);

    try std.testing.expectEqualStrings("ab", result.screen_bytes);
    try std.testing.expectEqual(@as(usize, 1), stdout_actor.controls.items.len);
    try std.testing.expectEqualStrings("\x1b[?1004h", stdout_actor.controls.items[0]);
}

test "application cursor mode enable is passed through and removed from screen bytes" {
    const allocator = std.testing.allocator;
    var actor = TestStdoutActor.init(allocator);
    defer actor.deinit();

    var forwarder = SideEffectForwarder.init(allocator);
    defer forwarder.deinit();

    const result = try forwarder.feed(&actor, "\x1b[?1hhello");
    try std.testing.expectEqualStrings("hello", result.screen_bytes);
    try std.testing.expectEqual(@as(usize, 1), actor.controls.items.len);
    try std.testing.expectEqualStrings("\x1b[?1h", actor.controls.items[0]);
}

test "application cursor mode disable is passed through and removed from screen bytes" {
    const allocator = std.testing.allocator;
    var actor = TestStdoutActor.init(allocator);
    defer actor.deinit();

    var forwarder = SideEffectForwarder.init(allocator);
    defer forwarder.deinit();

    const result = try forwarder.feed(&actor, "\x1b[?1lbye");
    try std.testing.expectEqualStrings("bye", result.screen_bytes);
    try std.testing.expectEqual(@as(usize, 1), actor.controls.items.len);
    try std.testing.expectEqualStrings("\x1b[?1l", actor.controls.items[0]);
}

test "mouse reporting enable is passed through and removed from screen bytes" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    const input = "a\x1b[?1006hb";
    const result = try forwarder.feed(&stdout_actor, input);

    try std.testing.expectEqualStrings("ab", result.screen_bytes);
    try std.testing.expectEqual(@as(usize, 1), stdout_actor.controls.items.len);
    try std.testing.expectEqualStrings("\x1b[?1006h", stdout_actor.controls.items[0]);
}

test "split chunk focus reporting CSI is passed through only after completion" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    const first = try forwarder.feed(&stdout_actor, "x\x1b[?10");
    try std.testing.expectEqualStrings("x", first.screen_bytes);
    try std.testing.expectEqual(@as(usize, 0), stdout_actor.controls.items.len);

    const second = try forwarder.feed(&stdout_actor, "04hy");
    try std.testing.expectEqualStrings("y", second.screen_bytes);
    try std.testing.expectEqual(@as(usize, 1), stdout_actor.controls.items.len);
    try std.testing.expectEqualStrings("\x1b[?1004h", stdout_actor.controls.items[0]);
}

test "ordinary CSI screen control stays in screen bytes" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    const input = "a\x1b[2Jb";
    const result = try forwarder.feed(&stdout_actor, input);

    try std.testing.expectEqualStrings("a\x1b[2Jb", result.screen_bytes);
    try std.testing.expectEqual(@as(usize, 0), stdout_actor.controls.items.len);
}

test "OSC 8 stays in screen bytes while OSC 52 still bypasses" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    const input = "a\x1b]8;id=1;https://example.com\x1b\\b\x1b]52;c;Zm9v\x07c\x1b]8;;\x1b\\d";
    const result = try forwarder.feed(&stdout_actor, input);

    try std.testing.expectEqualStrings("a\x1b]8;id=1;https://example.com\x1b\\bc\x1b]8;;\x1b\\d", result.screen_bytes);
    try std.testing.expectEqual(@as(usize, 1), stdout_actor.controls.items.len);
    try std.testing.expectEqualStrings("\x1b]52;c;Zm9v\x07", stdout_actor.controls.items[0]);
}

test "split chunk OSC 8 is emitted only after completion" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    const first = try forwarder.feed(&stdout_actor, "x\x1b]8;id=1;https://example");
    try std.testing.expectEqualStrings("x", first.screen_bytes);
    try std.testing.expectEqual(@as(usize, 0), stdout_actor.controls.items.len);

    const second = try forwarder.feed(&stdout_actor, ".com\x1b\\y");
    try std.testing.expectEqualStrings("\x1b]8;id=1;https://example.com\x1b\\y", second.screen_bytes);
    try std.testing.expectEqual(@as(usize, 0), stdout_actor.controls.items.len);
}

test "oversized OSC 52 is discarded without leaking payload to screen" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);

    try big.appendSlice(std.testing.allocator, "hello\x1b]52;c;");
    try big.appendNTimes(std.testing.allocator, 'A', max_osc_bytes + 100);
    try big.append(std.testing.allocator, 0x07);
    try big.appendSlice(std.testing.allocator, "world");

    const result = try forwarder.feed(&stdout_actor, big.items);

    try std.testing.expect(!result.emitted_osc52);
    try std.testing.expectEqualStrings("helloworld", result.screen_bytes);
    try std.testing.expectEqual(@as(usize, 0), stdout_actor.controls.items.len);
}

test "oversized OSC 52 split across feeds is discarded without leaking payload" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();

    var stdout_actor = TestStdoutActor.init(std.testing.allocator);
    defer stdout_actor.deinit();

    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(std.testing.allocator);
    try first.appendSlice(std.testing.allocator, "x\x1b]52;c;");
    try first.appendNTimes(std.testing.allocator, 'A', max_osc_bytes);

    const r1 = try forwarder.feed(&stdout_actor, first.items);
    try std.testing.expectEqualStrings("x", r1.screen_bytes);
    try std.testing.expectEqual(@as(usize, 0), stdout_actor.controls.items.len);

    const r2 = try forwarder.feed(&stdout_actor, "AAAA\x07y");
    try std.testing.expectEqualStrings("y", r2.screen_bytes);
    try std.testing.expectEqual(@as(usize, 0), stdout_actor.controls.items.len);
    try std.testing.expect(!r2.emitted_osc52);
}

test "bounded CSI discards through its final byte and resumes normal routing" {
    for ([_]usize{ 4094, 32768 }) |body_len| {
        var forwarder = SideEffectForwarder.init(std.testing.allocator);
        defer forwarder.deinit();
        var actor = TestStdoutActor.init(std.testing.allocator);
        defer actor.deinit();
        _ = try forwarder.feed(&actor, "\x1b[");
        const body = try std.testing.allocator.alloc(u8, body_len);
        defer std.testing.allocator.free(body);
        @memset(body, '1');
        const pending = try forwarder.feed(&actor, body);
        try std.testing.expectEqualStrings("", pending.screen_bytes);
        try std.testing.expect(forwarder.csi_buf.items.len <= 4096);
        try std.testing.expect(forwarder.csi_buf.capacity <= 8192);
        const result = try forwarder.feed(&actor, "mOK\x1b[?2004h");
        try std.testing.expectEqualStrings("OK", result.screen_bytes);
        try std.testing.expectEqual(@as(usize, 1), actor.controls.items.len);
        try std.testing.expectEqualStrings("\x1b[?2004h", actor.controls.items[0]);
    }
}

test "bounded OSC discards oversized clipboard hyperlink and title sequences" {
    const limit = 1024 * 1024;
    for ([_][]const u8{ "\x1b]52;c;", "\x1b]8;;", "\x1b]0;" }) |prefix| {
        for ([_][]const u8{ "\x07", "\x1b\\" }) |terminator| {
            // Cross the limit on either terminator byte, or before the terminator.
            for ([_]usize{ limit - prefix.len, limit - prefix.len + 1024, limit - prefix.len - terminator.len + 1 }) |body_len| {
                var forwarder = SideEffectForwarder.init(std.testing.allocator);
                defer forwarder.deinit();
                var actor = TestStdoutActor.init(std.testing.allocator);
                defer actor.deinit();
                _ = try forwarder.feed(&actor, prefix);
                const body = try std.testing.allocator.alloc(u8, body_len);
                defer std.testing.allocator.free(body);
                @memset(body, 'A');
                const pending = try forwarder.feed(&actor, body);
                try std.testing.expectEqualStrings("", pending.screen_bytes);
                try std.testing.expect(forwarder.osc_buf.items.len <= limit);
                try std.testing.expect(forwarder.osc_buf.capacity <= limit * 2);
                // Feed terminators one byte at a time to cover split ESC-backslash.
                for (terminator) |byte| {
                    const part = try forwarder.feed(&actor, &.{byte});
                    try std.testing.expectEqualStrings("", part.screen_bytes);
                    try std.testing.expect(!part.emitted_osc52);
                }
                const result = try forwarder.feed(&actor, "OK\x1b[?1h");
                try std.testing.expectEqualStrings("OK", result.screen_bytes);
                try std.testing.expectEqual(@as(usize, 1), actor.controls.items.len);
                try std.testing.expectEqualStrings("\x1b[?1h", actor.controls.items[0]);
            }
        }
    }
}

test "bounded control limits include complete sequences exactly at the limit" {
    var forwarder = SideEffectForwarder.init(std.testing.allocator);
    defer forwarder.deinit();
    var actor = TestStdoutActor.init(std.testing.allocator);
    defer actor.deinit();
    const osc = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(osc);
    @memset(osc, 'A');
    @memcpy(osc[0..7], "\x1b]52;c;");
    osc[osc.len - 1] = 0x07;
    const result = try forwarder.feed(&actor, osc);
    try std.testing.expect(result.emitted_osc52);
    try std.testing.expectEqual(@as(usize, 1), actor.controls.items.len);
    try std.testing.expectEqualSlices(u8, osc, actor.controls.items[0]);

    var csi: [4096]u8 = @splat('1');
    @memcpy(csi[0..2], "\x1b[");
    csi[csi.len - 1] = 'm';
    const screen = try forwarder.feed(&actor, &csi);
    try std.testing.expectEqualSlices(u8, &csi, screen.screen_bytes);
}
