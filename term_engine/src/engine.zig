const std = @import("std");
const c = @import("c.zig").c;
const screen_types = @import("vterm_screen_types.zig");
const snapshot_helpers = @import("snapshot.zig");

pub const HistoryEvent = union(enum) {
    line_committed: struct {
        line: screen_types.HostScreenLine,
        continuation: bool,
    },
    alternate_enter,
    alternate_exit,
    resize: struct {
        rows: u16,
        cols: u16,
    },
};

pub const Engine = struct {
    handle: ?*c.msr_vterm_handle,
    allocator: std.mem.Allocator,
    event_queue: std.ArrayList(HistoryEvent),
    last_alt_screen: bool = false,

    pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Engine {
        const handle = c.msr_vterm_new(@intCast(rows), @intCast(cols), 0) orelse return error.OutOfMemory;
        c.msr_vterm_enable_history_events(handle, 1);
        return .{
            .handle = handle,
            .allocator = allocator,
            .event_queue = .empty,
            .last_alt_screen = false,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.clearEvents();
        self.event_queue.deinit(self.allocator);
        if (self.handle) |handle| {
            c.msr_vterm_free(handle);
            self.handle = null;
        }
    }

    pub fn feed(self: *Engine, bytes: []const u8) !void {
        const handle = self.handle orelse return error.InvalidState;
        c.msr_vterm_feed(handle, bytes.ptr, bytes.len);
        try self.drainHistoryEvents();
        self.last_alt_screen = c.msr_vterm_get_alt_screen(handle) != 0;
    }

    pub fn resize(self: *Engine, rows: u16, cols: u16) !void {
        const handle = self.handle orelse return error.InvalidState;
        c.msr_vterm_set_size(handle, @intCast(rows), @intCast(cols));
        try self.drainHistoryEvents();
        self.last_alt_screen = c.msr_vterm_get_alt_screen(handle) != 0;
    }

    pub fn snapshot(self: *const Engine, allocator: std.mem.Allocator) !screen_types.HostScreenSnapshot {
        const handle = self.handle orelse return error.InvalidState;
        return snapshot_helpers.snapshotFromHandle(handle, allocator);
    }

    pub fn takeEvents(self: *Engine, allocator: std.mem.Allocator) ![]HistoryEvent {
        const out = try allocator.dupe(HistoryEvent, self.event_queue.items);
        self.event_queue.clearRetainingCapacity();
        return out;
    }

    pub fn clearEvents(self: *Engine) void {
        for (self.event_queue.items) |*event| {
            switch (event.*) {
                .line_committed => |*line| self.allocator.free(line.line.cells),
                else => {},
            }
        }
        self.event_queue.clearRetainingCapacity();
    }

    fn drainHistoryEvents(self: *Engine) !void {
        const handle = self.handle orelse return error.InvalidState;
        while (true) {
            var raw: c.msr_vterm_history_event = undefined;
            if (c.msr_vterm_next_history_event(handle, &raw) == 0) break;
            switch (raw.kind) {
                c.MSR_VTERM_HISTORY_LINE_COMMITTED => {
                    const cols: usize = @intCast(raw.cols);
                    const cells = try self.allocator.alloc(screen_types.HostScreenCell, cols);
                    for (0..cols) |i| {
                        const src = raw.cells[i];
                        var chars: [6]u32 = [_]u32{0} ** 6;
                        var j: usize = 0;
                        while (j < src.chars_len and j < chars.len) : (j += 1) chars[j] = src.chars[j];
                        cells[i] = .{
                            .chars = chars,
                            .chars_len = src.chars_len,
                            .width = src.width,
                            .hyperlink = src.hyperlink_handle,
                            .fg = snapshot_helpers.convertColor(src.fg, true),
                            .bg = snapshot_helpers.convertColor(src.bg, false),
                            .attrs = .{
                                .bold = src.attrs.bold != 0,
                                .italic = src.attrs.italic != 0,
                                .underline = src.attrs.underline != 0,
                                .blink = src.attrs.blink != 0,
                                .reverse = src.attrs.reverse != 0,
                                .conceal = src.attrs.conceal != 0,
                                .strike = src.attrs.strike != 0,
                                .font = src.attrs.font,
                            },
                        };
                    }
                    const continuation = raw.continuation != 0;
                    try self.event_queue.append(self.allocator, .{ .line_committed = .{
                        .line = .{ .cells = cells, .eol = !continuation },
                        .continuation = continuation,
                    } });
                },
                c.MSR_VTERM_HISTORY_ALT_ENTER => try self.event_queue.append(self.allocator, .alternate_enter),
                c.MSR_VTERM_HISTORY_ALT_EXIT => try self.event_queue.append(self.allocator, .alternate_exit),
                c.MSR_VTERM_HISTORY_RESIZE => try self.event_queue.append(self.allocator, .{ .resize = .{ .rows = @intCast(raw.rows), .cols = @intCast(raw.cols) } }),
                else => {},
            }
        }
    }
};

test "engine snapshot preserves ansi provenance for classic, bright, and extended indexed colors" {
    var engine = try Engine.init(std.testing.allocator, 2, 16);
    defer engine.deinit();

    try engine.feed("\x1b[34mA\x1b[94mB\x1b[38;5;27mC\x1b[0m");

    var snapshot = try engine.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    const a = snapshot.lines[0].cells[0].fg;
    try std.testing.expectEqual(screen_types.HostColor{ .kind = .indexed, .palette_index = 4, .ansi_class = .classic_low, .promoted_by_bold = false }, a);

    const b = snapshot.lines[0].cells[1].fg;
    try std.testing.expectEqual(screen_types.HostColor{ .kind = .indexed, .palette_index = 12, .ansi_class = .classic_bright, .promoted_by_bold = false }, b);

    const c_fg = snapshot.lines[0].cells[2].fg;
    try std.testing.expectEqual(screen_types.HostColor{ .kind = .indexed, .palette_index = 27, .ansi_class = .indexed_extended, .promoted_by_bold = false }, c_fg);
}

test "engine committed-line events preserve bold promoted ansi provenance" {
    var engine = try Engine.init(std.testing.allocator, 2, 16);
    defer engine.deinit();

    try engine.feed("\x1b[1;34mA\x1b[0m\r\n");

    const events = try engine.takeEvents(std.testing.allocator);
    defer {
        for (events) |event| {
            switch (event) {
                .line_committed => |line| std.testing.allocator.free(line.line.cells),
                else => {},
            }
        }
        std.testing.allocator.free(events);
    }

    try std.testing.expect(events.len > 0);
    const first = switch (events[0]) {
        .line_committed => |line| line,
        else => return error.TestUnexpectedResult,
    };
    const fg = first.line.cells[0].fg;
    try std.testing.expectEqual(@as(u8, 12), fg.palette_index);
    try std.testing.expectEqual(screen_types.HostAnsiClass.classic_low, fg.ansi_class);
    try std.testing.expect(fg.promoted_by_bold);
}
