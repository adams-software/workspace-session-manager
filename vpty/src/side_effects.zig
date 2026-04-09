const std = @import("std");
const StdoutActor = @import("stdout_actor").StdoutActor;

const State = enum {
    idle,
    esc,
    osc,
    osc_seen_5,
    osc_seen_52,
    osc_52_body,
    osc_other_body,
    osc_maybe_st_52,
    osc_maybe_st_other,
};

pub const FeedResult = struct {
    emitted_osc52: bool = false,
    screen_bytes: []const u8,
};

pub const SideEffectForwarder = struct {
    allocator: std.mem.Allocator,
    state: State = .idle,
    osc_buf: std.ArrayList(u8),
    screen_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) SideEffectForwarder {
        return .{
            .allocator = allocator,
            .state = .idle,
            .osc_buf = .{},
            .screen_buf = .{},
        };
    }

    pub fn deinit(self: *SideEffectForwarder) void {
        self.osc_buf.deinit(self.allocator);
        self.screen_buf.deinit(self.allocator);
    }

    fn startOsc(self: *SideEffectForwarder) !void {
        self.osc_buf.clearRetainingCapacity();
        try self.osc_buf.appendSlice(self.allocator, "\x1b]");
        self.state = .osc;
    }

    fn appendOsc(self: *SideEffectForwarder, b: u8) !void {
        try self.osc_buf.append(self.allocator, b);
    }

    fn appendScreen(self: *SideEffectForwarder, b: u8) !void {
        try self.screen_buf.append(self.allocator, b);
    }

    fn flushOsc52(self: *SideEffectForwarder, stdout_actor: *StdoutActor) !void {
        try stdout_actor.enqueueControl(self.osc_buf.items);
    }

    fn resetOsc(self: *SideEffectForwarder) void {
        self.osc_buf.clearRetainingCapacity();
        self.state = .idle;
    }

    pub fn feed(self: *SideEffectForwarder, stdout_actor: *StdoutActor, bytes: []const u8) !FeedResult {
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
                    } else {
                        try self.appendScreen(0x1b);
                        try self.appendScreen(b);
                        self.state = .idle;
                    }
                },

                .osc => {
                    try self.appendOsc(b);
                    if (b == '5') {
                        self.state = .osc_seen_5;
                    } else {
                        self.state = .osc_other_body;
                    }
                },

                .osc_seen_5 => {
                    try self.appendOsc(b);
                    if (b == '2') {
                        self.state = .osc_seen_52;
                    } else {
                        self.state = .osc_other_body;
                    }
                },

                .osc_seen_52 => {
                    try self.appendOsc(b);
                    if (b == ';') {
                        self.state = .osc_52_body;
                    } else {
                        self.state = .osc_other_body;
                    }
                },

                .osc_52_body => {
                    try self.appendOsc(b);

                    if (b == 0x07) {
                        try self.flushOsc52(stdout_actor);
                        result.emitted_osc52 = true;
                        self.resetOsc();
                    } else if (b == 0x1b) {
                        self.state = .osc_maybe_st_52;
                    }
                },

                .osc_other_body => {
                    try self.appendOsc(b);

                    if (b == 0x07) {
                        self.resetOsc();
                    } else if (b == 0x1b) {
                        self.state = .osc_maybe_st_other;
                    }
                },

                .osc_maybe_st_52 => {
                    try self.appendOsc(b);

                    if (b == '\\') {
                        try self.flushOsc52(stdout_actor);
                        result.emitted_osc52 = true;
                        self.resetOsc();
                    } else {
                        self.state = .osc_52_body;
                    }
                },

                .osc_maybe_st_other => {
                    try self.appendOsc(b);

                    if (b == '\\') {
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
