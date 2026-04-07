const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
});

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
pub const SideEffectForwarder = struct {
    allocator: std.mem.Allocator,
    state: State = .idle,
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) SideEffectForwarder {
        return .{
            .allocator = allocator,
            .state = .idle,
            .buf = .{},
        };
    }

    pub fn deinit(self: *SideEffectForwarder) void {
        self.buf.deinit(self.allocator);
    }

    fn startOsc(self: *SideEffectForwarder) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, "\x1b]");
        self.state = .osc;
    }

    fn append(self: *SideEffectForwarder, b: u8) !void {
        try self.buf.append(self.allocator, b);
    }
    fn flushOsc52(self: *SideEffectForwarder) void {
        writeAll(self.buf.items);
    }
    fn writeAll(bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(c.STDOUT_FILENO, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return;
            off += @intCast(n);
        }
    }
    fn reset(self: *SideEffectForwarder) void {
        self.buf.clearRetainingCapacity();
        self.state = .idle;
    }

    pub fn feed(self: *SideEffectForwarder, bytes: []const u8) !void {
        for (bytes) |b| {
            switch (self.state) {
                .idle => {
                    if (b == 0x1b) self.state = .esc;
                },

                .esc => {
                    if (b == ']') {
                        try self.startOsc();
                    } else {
                        self.state = .idle;
                    }
                },

                .osc => {
                    try self.append(b);
                    if (b == '5') {
                        self.state = .osc_seen_5;
                    } else {
                        self.state = .osc_other_body;
                    }
                },

                .osc_seen_5 => {
                    try self.append(b);
                    if (b == '2') {
                        self.state = .osc_seen_52;
                    } else {
                        self.state = .osc_other_body;
                    }
                },

                .osc_seen_52 => {
                    try self.append(b);
                    if (b == ';') {
                        self.state = .osc_52_body;
                    } else {
                        self.state = .osc_other_body;
                    }
                },

                .osc_52_body => {
                    try self.append(b);

                    if (b == 0x07) {
                        self.flushOsc52();
                        self.reset();
                    } else if (b == 0x1b) {
                        self.state = .osc_maybe_st_52;
                    }
                },

                .osc_other_body => {
                    try self.append(b);

                    if (b == 0x07) {
                        self.reset();
                    } else if (b == 0x1b) {
                        self.state = .osc_maybe_st_other;
                    }
                },

                .osc_maybe_st_52 => {
                    try self.append(b);

                    if (b == '\\') {
                        self.flushOsc52();
                        self.reset();
                    } else {
                        self.state = .osc_52_body;
                    }
                },

                .osc_maybe_st_other => {
                    try self.append(b);

                    if (b == '\\') {
                        self.reset();
                    } else {
                        self.state = .osc_other_body;
                    }
                },
            }
        }
    }
};
