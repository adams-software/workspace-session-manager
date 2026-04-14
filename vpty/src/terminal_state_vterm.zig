const std = @import("std");
const c = @cImport({
    @cInclude("vterm_shim.h");
    @cInclude("stdlib.h");
});
const screen_types = @import("vterm_screen_types");

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

pub const VTermAdapter = struct {
    handle: ?*c.msr_vterm_handle,

    pub const GraphemeMode = enum(c_int) {
        legacy = 0,
        unicode = 1,
    };

    pub const Size = struct {
        rows: u16,
        cols: u16,
    };

    pub fn init(rows: u16, cols: u16) !VTermAdapter {
        return initWithMode(rows, cols, .legacy);
    }

    pub fn initWithMode(rows: u16, cols: u16, mode: GraphemeMode) !VTermAdapter {
        const handle = c.msr_vterm_new(@intCast(rows), @intCast(cols), @intFromEnum(mode)) orelse return error.OutOfMemory;
        return .{
            .handle = handle,
        };
    }

    pub fn deinit(self: *VTermAdapter) void {
        if (self.handle) |handle| {
            c.msr_vterm_free(handle);
            self.handle = null;
        }
    }

    pub fn feed(self: *VTermAdapter, bytes: []const u8) void {
        if (self.handle) |handle| {
            c.msr_vterm_feed(handle, bytes.ptr, bytes.len);
        }
    }

    pub fn resize(self: *VTermAdapter, rows: u16, cols: u16) void {
        if (self.handle) |handle| c.msr_vterm_set_size(handle, @intCast(rows), @intCast(cols));
    }

    pub fn currentSize(self: *const VTermAdapter) ?Size {
        const handle = self.handle orelse return null;
        return .{
            .rows = @intCast(handle.rows),
            .cols = @intCast(handle.cols),
        };
    }

    pub fn snapshot(self: *const VTermAdapter, allocator: std.mem.Allocator) !screen_types.HostScreenSnapshot {
        if (self.handle == null) return error.InvalidState;
        const handle = self.handle.?;

        const rows = handle.rows;
        const cols = handle.cols;

        var lines = try allocator.alloc(screen_types.HostScreenLine, @intCast(rows));
        var hyperlink_map = std.AutoHashMap(u32, u32).init(allocator);
        defer hyperlink_map.deinit();
        var hyperlinks = std.ArrayList(screen_types.HostHyperlink){};
        var initialized_rows: usize = 0;
        errdefer {
            for (lines[0..initialized_rows]) |line| {
                allocator.free(line.cells);
            }
            allocator.free(lines);
            for (hyperlinks.items) |link| {
                allocator.free(link.params);
                allocator.free(link.uri);
            }
            hyperlinks.deinit(allocator);
        }

        for (0..@intCast(rows)) |r| {
            const row_cells = try allocator.alloc(screen_types.HostScreenCell, @intCast(cols));
            lines[r] = .{
                .cells = row_cells,
                .eol = c.msr_vterm_row_is_eol(handle, @intCast(r)) != 0,
            };
            initialized_rows += 1;

            for (0..@intCast(cols)) |col_idx| {
                var raw: c.msr_vterm_cell = undefined;
                c.msr_vterm_get_cell(handle, @intCast(r), @intCast(col_idx), &raw);

                var chars: [6]u32 = [_]u32{0} ** 6;
                var i: usize = 0;
                while (i < raw.chars_len and i < chars.len) : (i += 1) {
                    chars[i] = raw.chars[i];
                }

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
};

test "OSC 8 hyperlinks are captured as snapshot-local metadata" {
    var adapter = try VTermAdapter.init(4, 12);
    defer adapter.deinit();

    adapter.feed("\x1b]8;;https://example.com\x1b\\hi\x1b]8;;\x1b\\!");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(usize, 1), snapshot.hyperlinks.len);
    try std.testing.expectEqualStrings("", snapshot.hyperlinks[0].params);
    try std.testing.expectEqualStrings("https://example.com", snapshot.hyperlinks[0].uri);
    try std.testing.expectEqual(@as(u32, 1), snapshot.lines[0].cells[0].hyperlink);
    try std.testing.expectEqual(@as(u32, 1), snapshot.lines[0].cells[1].hyperlink);
    try std.testing.expectEqual(@as(u32, 0), snapshot.lines[0].cells[2].hyperlink);
}

test "OSC 8 preserves params and distinguishes same uri with different params" {
    var adapter = try VTermAdapter.init(2, 16);
    defer adapter.deinit();

    adapter.feed("\x1b]8;id=1;https://example.com\x1b\\a\x1b]8;;\x1b\\\x1b]8;id=2;https://example.com\x1b\\b\x1b]8;;\x1b\\");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(usize, 2), snapshot.hyperlinks.len);
    try std.testing.expectEqualStrings("id=1", snapshot.hyperlinks[0].params);
    try std.testing.expectEqualStrings("https://example.com", snapshot.hyperlinks[0].uri);
    try std.testing.expectEqualStrings("id=2", snapshot.hyperlinks[1].params);
    try std.testing.expectEqualStrings("https://example.com", snapshot.hyperlinks[1].uri);
    try std.testing.expectEqual(@as(u32, 1), snapshot.lines[0].cells[0].hyperlink);
    try std.testing.expectEqual(@as(u32, 2), snapshot.lines[0].cells[1].hyperlink);
}

test "malformed OSC 8 is ignored without leaking hyperlink metadata" {
    var adapter = try VTermAdapter.init(2, 12);
    defer adapter.deinit();

    adapter.feed("\x1b]8broken\x1b\\ok");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(usize, 0), snapshot.hyperlinks.len);
    try std.testing.expectEqual(@as(u32, 0), snapshot.lines[0].cells[0].hyperlink);
    try std.testing.expectEqual(@as(u32, 0), snapshot.lines[0].cells[1].hyperlink);
}

test "malformed OSC 8 after valid open leaves current hyperlink active" {
    var adapter = try VTermAdapter.init(2, 16);
    defer adapter.deinit();

    adapter.feed("\x1b]8;;https://example.com\x1b\\a\x1b]8broken\x1b\\b\x1b]8;;\x1b\\");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(usize, 1), snapshot.hyperlinks.len);
    try std.testing.expectEqualStrings("https://example.com", snapshot.hyperlinks[0].uri);
    try std.testing.expectEqual(@as(u32, 1), snapshot.lines[0].cells[0].hyperlink);
    try std.testing.expectEqual(@as(u32, 1), snapshot.lines[0].cells[1].hyperlink);
}

test "BEL-terminated OSC 8 hyperlinks are captured" {
    var adapter = try VTermAdapter.init(2, 12);
    defer adapter.deinit();

    adapter.feed("\x1b]8;;https://example.com\x07hi\x1b]8;;\x07");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(usize, 1), snapshot.hyperlinks.len);
    try std.testing.expectEqualStrings("https://example.com", snapshot.hyperlinks[0].uri);
    try std.testing.expectEqual(@as(u32, 1), snapshot.lines[0].cells[0].hyperlink);
    try std.testing.expectEqual(@as(u32, 1), snapshot.lines[0].cells[1].hyperlink);
}

test "emoji variation selector cluster stays width 2 and advances cursor once" {
    var adapter = try VTermAdapter.init(2, 12);
    defer adapter.deinit();

    adapter.feed("\xe2\xad\x95\xef\xb8\x8f!");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(u8, 2), snapshot.lines[0].cells[0].width);
    try std.testing.expectEqual(@as(u32, 0x2b55), snapshot.lines[0].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u32, 0xfe0f), snapshot.lines[0].cells[0].chars[1]);
    try std.testing.expectEqual(@as(u32, '!'), snapshot.lines[0].cells[2].chars[0]);
    try std.testing.expectEqual(@as(u16, 3), snapshot.cursor_col);
}

test "single emoji codepoint stays width 2 and advances cursor once" {
    var adapter = try VTermAdapter.init(2, 12);
    defer adapter.deinit();

    adapter.feed("\xf0\x9f\xa5\x93!");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(u8, 2), snapshot.lines[0].cells[0].width);
    try std.testing.expectEqual(@as(u32, 0x1f953), snapshot.lines[0].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u32, '!'), snapshot.lines[0].cells[2].chars[0]);
    try std.testing.expectEqual(@as(u16, 3), snapshot.cursor_col);
}

test "zwj emoji cluster stays width 2 and does not over-advance cursor" {
    var adapter = try VTermAdapter.init(2, 20);
    defer adapter.deinit();

    adapter.feed("\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb!");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(u8, 2), snapshot.lines[0].cells[0].width);
    try std.testing.expectEqual(@as(u16, 3), snapshot.cursor_col);
}

test "variation-selector emoji wraps at right edge without pulling next line backward" {
    var adapter = try VTermAdapter.init(3, 4);
    defer adapter.deinit();

    adapter.feed("ab\xe2\xad\x95\xef\xb8\x8fc");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(u32, 'a'), snapshot.lines[0].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u32, 'b'), snapshot.lines[0].cells[1].chars[0]);
    try std.testing.expectEqual(@as(u8, 2), snapshot.lines[0].cells[2].width);
    try std.testing.expectEqual(@as(u32, 0x2b55), snapshot.lines[0].cells[2].chars[0]);
    try std.testing.expectEqual(@as(u32, 0xfe0f), snapshot.lines[0].cells[2].chars[1]);
    try std.testing.expectEqual(@as(u32, 'c'), snapshot.lines[1].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u16, 1), snapshot.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), snapshot.cursor_col);
}

test "regional-indicator pair wraps at right edge without pulling next line backward" {
    var adapter = try VTermAdapter.init(3, 4);
    defer adapter.deinit();

    adapter.feed("ab\xf0\x9f\x87\xba\xf0\x9f\x87\xb8c");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(u32, 'a'), snapshot.lines[0].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u32, 'b'), snapshot.lines[0].cells[1].chars[0]);
    try std.testing.expectEqual(@as(u8, 2), snapshot.lines[0].cells[2].width);
    try std.testing.expectEqual(@as(u32, 0x1f1fa), snapshot.lines[0].cells[2].chars[0]);
    try std.testing.expectEqual(@as(u32, 0x1f1f8), snapshot.lines[0].cells[2].chars[1]);
    try std.testing.expectEqual(@as(u32, 'c'), snapshot.lines[1].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u16, 1), snapshot.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), snapshot.cursor_col);
}

test "zwj emoji wraps at right edge without pulling next line backward" {
    var adapter = try VTermAdapter.init(3, 4);
    defer adapter.deinit();

    adapter.feed("ab\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbbc");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(u32, 'a'), snapshot.lines[0].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u32, 'b'), snapshot.lines[0].cells[1].chars[0]);
    try std.testing.expectEqual(@as(u8, 2), snapshot.lines[0].cells[2].width);
    try std.testing.expectEqual(@as(u32, 0x1f469), snapshot.lines[0].cells[2].chars[0]);
    try std.testing.expectEqual(@as(u32, 0x200d), snapshot.lines[0].cells[2].chars[1]);
    try std.testing.expectEqual(@as(u32, 0x1f4bb), snapshot.lines[0].cells[2].chars[2]);
    try std.testing.expectEqual(@as(u32, 'c'), snapshot.lines[1].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u16, 1), snapshot.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), snapshot.cursor_col);
}

test "legacy mode keeps regional indicators together" {
    var adapter = try VTermAdapter.initWithMode(2, 8, .legacy);
    defer adapter.deinit();

    adapter.feed("\xf0\x9f\x87\xba\xf0\x9f\x87\xb8!");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(u32, 0x1f1fa), snapshot.lines[0].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u32, 0x1f1f8), snapshot.lines[0].cells[0].chars[1]);
    try std.testing.expectEqual(@as(u32, '!'), snapshot.lines[0].cells[2].chars[0]);
}

test "unicode mode keeps regional indicators together" {
    var adapter = try VTermAdapter.initWithMode(2, 8, .unicode);
    defer adapter.deinit();

    adapter.feed("\xf0\x9f\x87\xba\xf0\x9f\x87\xb8!");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(u32, 0x1f1fa), snapshot.lines[0].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u32, 0x1f1f8), snapshot.lines[0].cells[0].chars[1]);
    try std.testing.expectEqual(@as(u32, '!'), snapshot.lines[0].cells[2].chars[0]);
}

test "unicode mode keeps combining mark attached to previous base" {
    var adapter = try VTermAdapter.initWithMode(2, 8, .unicode);
    defer adapter.deinit();

    adapter.feed("e\xcc\x81!");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    try std.testing.expectEqual(@as(u32, 'e'), snapshot.lines[0].cells[0].chars[0]);
    try std.testing.expectEqual(@as(u32, 0x0301), snapshot.lines[0].cells[0].chars[1]);
    try std.testing.expectEqual(@as(u32, '!'), snapshot.lines[0].cells[1].chars[0]);
}
