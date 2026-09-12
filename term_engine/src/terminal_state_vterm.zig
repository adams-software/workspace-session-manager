const std = @import("std");
const c = @import("c.zig").c;
const screen_types = @import("vterm_screen_types.zig");
const snapshot_helpers = @import("snapshot.zig");

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
        return snapshot_helpers.snapshotFromHandle(self.handle.?, allocator);
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

test "snapshot preserves ansi provenance for classic, bright, and extended indexed colors" {
    var adapter = try VTermAdapter.init(2, 16);
    defer adapter.deinit();

    adapter.feed("\x1b[34mA\x1b[94mB\x1b[38;5;27mC\x1b[0m");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    const a = snapshot.lines[0].cells[0].fg;
    try std.testing.expectEqual(screen_types.HostColor{ .kind = .indexed, .palette_index = 4, .ansi_class = .classic_low, .promoted_by_bold = false }, a);

    const b = snapshot.lines[0].cells[1].fg;
    try std.testing.expectEqual(screen_types.HostColor{ .kind = .indexed, .palette_index = 12, .ansi_class = .classic_bright, .promoted_by_bold = false }, b);

    const c_fg = snapshot.lines[0].cells[2].fg;
    try std.testing.expectEqual(screen_types.HostColor{ .kind = .indexed, .palette_index = 27, .ansi_class = .indexed_extended, .promoted_by_bold = false }, c_fg);
}

test "snapshot keeps bold classic-low colors unpromoted by default" {
    var adapter = try VTermAdapter.init(2, 16);
    defer adapter.deinit();

    adapter.feed("\x1b[1;34mA\x1b[0m");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    const cell = snapshot.lines[0].cells[0];
    try std.testing.expectEqual(screen_types.HostColor{ .kind = .indexed, .palette_index = 4, .ansi_class = .classic_low, .promoted_by_bold = false }, cell.fg);
    try std.testing.expect(cell.attrs.bold);
}

test "snapshot preserves bold promoted classic-low provenance" {
    var adapter = try VTermAdapter.init(2, 16);
    defer adapter.deinit();

    // Promotion is opt-in; the runtime leaves libvterm's default disabled.
    c.vterm_state_set_bold_highbright(adapter.handle.?.state, 1);
    adapter.feed("\x1b[1;34mA\x1b[0m");

    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);

    const fg = snapshot.lines[0].cells[0].fg;
    try std.testing.expectEqual(@as(u8, 12), fg.palette_index);
    try std.testing.expectEqual(screen_types.HostAnsiClass.classic_low, fg.ansi_class);
    try std.testing.expect(fg.promoted_by_bold);
}

test "hyperlink cache expires stale handles without aliasing and snapshots keep ownership" {
    var adapter = try VTermAdapter.init(2, 20);
    defer adapter.deinit();
    adapter.feed("\x1b]8;;https://old.example\x1b\\old\x1b]8;;\x1b\\");
    var old = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &old);
    for (0..c.MSR_HYPERLINK_SLOTS + 10) |i| {
        var buf: [128]u8 = undefined;
        adapter.feed(try std.fmt.bufPrint(&buf, "\x1b[2;1H\x1b]8;;https://new/{d}\x1b\\new\x1b]8;;\x1b\\", .{i}));
    }
    var current = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &current);
    try std.testing.expectEqual(@as(u32, 0), current.lines[0].cells[0].hyperlink);
    try std.testing.expectEqual(@as(usize, 1), current.hyperlinks.len);
    try std.testing.expectEqualStrings("https://old.example", old.hyperlinks[0].uri);
    try std.testing.expect(adapter.handle.?.hyperlink_bytes <= c.MSR_HYPERLINK_BYTES);
    try std.testing.expectEqual(@as(usize, c.MSR_HYPERLINK_SLOTS), adapter.handle.?.hyperlinks_len);
}

test "hyperlink byte budget bounds long URLs independently of entry count" {
    var adapter = try VTermAdapter.init(2, 20);
    defer adapter.deinit();
    var buf: [7000]u8 = undefined;
    for (0..400) |i| {
        const prefix = try std.fmt.bufPrint(&buf, "\x1b]8;;https://example/{d}/", .{i});
        @memset(buf[prefix.len .. buf.len - 5], 'a');
        @memcpy(buf[buf.len - 5 ..], "\x1b\\x\r\n");
        adapter.feed(&buf);
        try std.testing.expect(adapter.handle.?.hyperlink_bytes <= c.MSR_HYPERLINK_BYTES);
    }
    var uri_len: usize = 0;
    try std.testing.expect(c.msr_vterm_get_hyperlink_uri(adapter.handle.?, 1, &uri_len) == null);
}

test "hyperlink cache deduplicates metadata and never reuses exhausted IDs" {
    var adapter = try VTermAdapter.init(2, 20);
    defer adapter.deinit();
    adapter.feed("\x1b]8;id=a;https://example\x1b\\a");
    adapter.feed("\x1b]8;id=b;https://example\x1b\\b");
    const bytes = adapter.handle.?.hyperlink_bytes;
    adapter.feed("\x1b]8;id=a;https://example\x1b\\c");
    try std.testing.expectEqual(@as(u32, 2), adapter.handle.?.next_hyperlink_id);
    try std.testing.expectEqual(bytes, adapter.handle.?.hyperlink_bytes);
    var snapshot = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &snapshot);
    try std.testing.expectEqual(@as(usize, 2), snapshot.hyperlinks.len);
    try std.testing.expectEqual(snapshot.lines[0].cells[0].hyperlink, snapshot.lines[0].cells[2].hyperlink);
    try std.testing.expect(snapshot.lines[0].cells[0].hyperlink != snapshot.lines[0].cells[1].hyperlink);

    // A rejected new link must clear the previous pen URL, not mislabel text.
    adapter.handle.?.next_hyperlink_id = std.math.maxInt(i32);
    adapter.feed("\x1b]8;;https://new.example\x1b\\d");
    var exhausted = try adapter.snapshot(std.testing.allocator);
    defer screen_types.freeScreenSnapshot(std.testing.allocator, &exhausted);
    try std.testing.expectEqual(@as(u32, 0), exhausted.lines[0].cells[3].hyperlink);
    try std.testing.expectEqual(bytes, adapter.handle.?.hyperlink_bytes);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(i32)), adapter.handle.?.next_hyperlink_id);
}
