const std = @import("std");
const c = @cImport({
    @cInclude("vterm_shim.h");
    @cInclude("stdlib.h");
});
const screen_types = @import("vterm_screen_types.zig");

fn convertColor(raw: c.msr_vterm_color, is_fg: bool) screen_types.HostColor {
    if ((is_fg and raw.is_default_fg != 0) or (!is_fg and raw.is_default_bg != 0)) {
        return .{ .kind = .default };
    }

    return switch (raw.type) {
        1 => .{ .kind = .indexed, .palette_index = raw.palette_index },
        2 => .{ .kind = .rgb, .red = raw.red, .green = raw.green, .blue = raw.blue },
        else => .{ .kind = .default },
    };
}

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
            .event_queue = .{},
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
        return snapshotFromHandle(handle, allocator);
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
                            .fg = convertColor(src.fg, true),
                            .bg = convertColor(src.bg, false),
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
                    try self.event_queue.append(self.allocator, .{ .line_committed = .{
                        .line = .{ .cells = cells, .eol = true },
                        .continuation = raw.continuation != 0,
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

pub fn snapshotFromHandle(handle: *c.msr_vterm_handle, allocator: std.mem.Allocator) !screen_types.HostScreenSnapshot {
    const rows = handle.rows;
    const cols = handle.cols;

    var lines = try allocator.alloc(screen_types.HostScreenLine, @intCast(rows));
    var hyperlink_map = std.AutoHashMap(u32, u32).init(allocator);
    defer hyperlink_map.deinit();
    var hyperlinks = std.ArrayList(screen_types.HostHyperlink){};
    var initialized_rows: usize = 0;
    errdefer {
        for (lines[0..initialized_rows]) |line| allocator.free(line.cells);
        allocator.free(lines);
        for (hyperlinks.items) |link| {
            allocator.free(link.params);
            allocator.free(link.uri);
        }
        hyperlinks.deinit(allocator);
    }

    for (0..@intCast(rows)) |r| {
        const row_cells = try allocator.alloc(screen_types.HostScreenCell, @intCast(cols));
        lines[r] = .{ .cells = row_cells, .eol = c.msr_vterm_row_is_eol(handle, @intCast(r)) != 0 };
        initialized_rows += 1;

        for (0..@intCast(cols)) |col_idx| {
            var raw: c.msr_vterm_cell = undefined;
            c.msr_vterm_get_cell(handle, @intCast(r), @intCast(col_idx), &raw);
            var chars: [6]u32 = [_]u32{0} ** 6;
            var i: usize = 0;
            while (i < raw.chars_len and i < chars.len) : (i += 1) chars[i] = raw.chars[i];
            row_cells[col_idx] = .{
                .chars = chars,
                .chars_len = raw.chars_len,
                .width = raw.width,
                .hyperlink = 0,
                .fg = convertColor(raw.fg, true),
                .bg = convertColor(raw.bg, false),
                .attrs = .{
                    .bold = raw.attrs.bold != 0,
                    .italic = raw.attrs.italic != 0,
                    .underline = raw.attrs.underline != 0,
                    .blink = raw.attrs.blink != 0,
                    .reverse = raw.attrs.reverse != 0,
                    .conceal = raw.attrs.conceal != 0,
                    .strike = raw.attrs.strike != 0,
                    .font = raw.attrs.font,
                },
            };

            if (raw.hyperlink_handle != 0) {
                const gop = try hyperlink_map.getOrPut(raw.hyperlink_handle);
                if (!gop.found_existing) {
                    var params_len: usize = 0;
                    const params_ptr = c.msr_vterm_get_hyperlink_params(handle, raw.hyperlink_handle, &params_len) orelse {
                        _ = hyperlink_map.remove(raw.hyperlink_handle);
                        continue;
                    };
                    var uri_len: usize = 0;
                    const uri_ptr = c.msr_vterm_get_hyperlink_uri(handle, raw.hyperlink_handle, &uri_len) orelse {
                        _ = hyperlink_map.remove(raw.hyperlink_handle);
                        continue;
                    };
                    const params = try allocator.dupe(u8, params_ptr[0..params_len]);
                    errdefer allocator.free(params);
                    const uri = try allocator.dupe(u8, uri_ptr[0..uri_len]);
                    errdefer allocator.free(uri);
                    try hyperlinks.append(allocator, .{ .params = params, .uri = uri });
                    gop.value_ptr.* = @intCast(hyperlinks.items.len);
                }
                row_cells[col_idx].hyperlink = gop.value_ptr.*;
            }
        }
    }

    var cursor_row: c_int = 0;
    var cursor_col: c_int = 0;
    var cursor_visible: c_int = 0;
    c.msr_vterm_get_cursor(handle, &cursor_row, &cursor_col, &cursor_visible);

    return .{
        .rows = @intCast(rows),
        .cols = @intCast(cols),
        .cursor_row = @intCast(cursor_row),
        .cursor_col = @intCast(cursor_col),
        .cursor_visible = cursor_visible != 0,
        .alt_screen = c.msr_vterm_get_alt_screen(handle) != 0,
        .title = null,
        .seq = 0,
        .hyperlinks = try hyperlinks.toOwnedSlice(allocator),
        .lines = lines,
    };
}
