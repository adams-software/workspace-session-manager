const std = @import("std");
const host = @import("session_host_vpty");

pub const VirtualCursor = struct {
    visible: bool = true,
    row: u16 = 0,
    col: u16 = 0,
};

pub const Viewport = struct {
    origin_row: u16 = 0,
    origin_col: u16 = 0,
    rows: u16 = 0,
    cols: u16 = 0,

    pub fn init(origin_row: u16, origin_col: u16, rows: u16, cols: u16) Viewport {
        return .{
            .origin_row = origin_row,
            .origin_col = origin_col,
            .rows = rows,
            .cols = cols,
        };
    }
};

pub const TextRun = struct {
    start_col: u16,
    end_col: u16,
    cells: []const host.HostScreenCell,

    pub fn init(start_col: u16, end_col: u16, cells: []const host.HostScreenCell) TextRun {
        return .{
            .start_col = start_col,
            .end_col = end_col,
            .cells = cells,
        };
    }
};

pub const RowPatch = struct {
    row: u16,
    runs: std.ArrayList(TextRun),
    clear_remaining: bool = true,

    pub fn init(row: u16) RowPatch {
        return .{
            .row = row,
            .runs = .{},
            .clear_remaining = true,
        };
    }

    pub fn deinit(self: *RowPatch, allocator: std.mem.Allocator) void {
        self.runs.deinit(allocator);
    }
};

pub const ViewportPatch = struct {
    full_redraw: bool,
    rows: std.ArrayList(RowPatch),
    cursor: VirtualCursor,

    pub fn init(full_redraw: bool, allocator: std.mem.Allocator) ViewportPatch {
        _ = allocator;
        return .{
            .full_redraw = full_redraw,
            .rows = .{},
            .cursor = .{},
        };
    }

    pub fn deinit(self: *ViewportPatch, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.deinit(allocator);
        self.rows.deinit(allocator);
    }
};

const StyleState = struct {
    attrs: host.HostCellAttrs = .{},
    fg: host.HostColor = .{ .kind = .default },
    bg: host.HostColor = .{ .kind = .default },
    active_hyperlink: u32 = 0,

    fn reset(self: *StyleState, sink: anytype) void {
        sink.resetStyle();
        self.* = .{};
    }

    fn emitBool(sink: anytype, on_code: []const u8, off_code: []const u8, current: *bool, target: bool) void {
        if (current.* == target) return;
        sink.writeBytes(if (target) on_code else off_code);
        current.* = target;
    }

    fn diffAndEmit(self: *StyleState, sink: anytype, cell: host.HostScreenCell) void {
        emitBool(sink, "\x1b[1m", "\x1b[22m", &self.attrs.bold, cell.attrs.bold);
        emitBool(sink, "\x1b[3m", "\x1b[23m", &self.attrs.italic, cell.attrs.italic);
        emitBool(sink, "\x1b[4m", "\x1b[24m", &self.attrs.underline, cell.attrs.underline);
        emitBool(sink, "\x1b[5m", "\x1b[25m", &self.attrs.blink, cell.attrs.blink);
        emitBool(sink, "\x1b[7m", "\x1b[27m", &self.attrs.reverse, cell.attrs.reverse);
        emitBool(sink, "\x1b[8m", "\x1b[28m", &self.attrs.conceal, cell.attrs.conceal);

        if (!colorEq(self.fg, cell.fg)) {
            emitColor(sink, 38, cell.fg);
            self.fg = cell.fg;
        }
        if (!colorEq(self.bg, cell.bg)) {
            emitColor(sink, 48, cell.bg);
            self.bg = cell.bg;
        }
    }
};

pub const SingleViewportAdapter = struct {
    viewport: Viewport,
    render_buf: *std.ArrayList(u8),

    pub fn writeBytes(self: *SingleViewportAdapter, bytes: []const u8) void {
        self.render_buf.appendSlice(std.heap.page_allocator, bytes) catch return;
    }

    pub fn out(self: *SingleViewportAdapter, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.writeBytes(rendered);
    }

    pub fn resetStyle(self: *SingleViewportAdapter) void {
        self.writeBytes("\x1b[0m");
    }

    fn moveCursor(self: *SingleViewportAdapter, row: u16, col: u16) void {
        const max_row = if (self.viewport.rows == 0) @as(u16, 0) else self.viewport.rows - 1;
        const max_col = if (self.viewport.cols == 0) @as(u16, 0) else self.viewport.cols - 1;
        const clamped_row = @min(row, max_row);
        const clamped_col = @min(col, max_col);
        self.out("\x1b[{d};{d}H", .{
            self.viewport.origin_row + clamped_row + 1,
            self.viewport.origin_col + clamped_col + 1,
        });
    }

    fn emitRealCursor(self: *SingleViewportAdapter, cursor: VirtualCursor) void {
        if (!cursor.visible) {
            self.writeBytes("\x1b[?25l");
            return;
        }

        self.writeBytes("\x1b[?25h");
        self.moveCursor(cursor.row, cursor.col);
    }

    fn fillRemainingViewportColumns(self: *SingleViewportAdapter, style_state: *StyleState, written_cols: usize) void {
        const viewport_cols: usize = self.viewport.cols;
        if (written_cols >= viewport_cols) return;

        style_state.reset(self);
        var remaining = viewport_cols - written_cols;
        while (remaining > 0) : (remaining -= 1) {
            self.writeBytes(" ");
        }
    }

    pub fn emitPatch(self: *SingleViewportAdapter, patch: *const ViewportPatch, snapshot: *const host.HostScreenSnapshot) void {
        self.writeBytes("\x1b[?25l");
        self.writeBytes("\x1b[0m");

        var style_state = StyleState{};
        style_state.reset(self);

        for (patch.rows.items) |row_patch| {
            var written_cols: usize = 0;
            for (row_patch.runs.items) |run| {
                self.moveCursor(row_patch.row, run.start_col);
                written_cols = run.start_col;

                var src_col: usize = 0;
                const run_end = @min(@as(usize, run.end_col), @as(usize, self.viewport.cols));
                while (src_col < run.cells.len and written_cols < run_end) {
                    const cell = run.cells[src_col];
                    if (cell.width == 0) {
                        src_col += 1;
                        continue;
                    }
                    const cell_width = @max(@as(usize, 1), @as(usize, cell.width));
                    if (written_cols + cell_width > run_end) break;
                    emitHyperlinkTransition(self, snapshot, cell.hyperlink, &style_state.active_hyperlink);
                    emitCell(self, cell, &style_state);
                    written_cols += cell_width;
                    src_col += 1;
                }
            }

            emitHyperlinkTransition(self, snapshot, 0, &style_state.active_hyperlink);
            if (row_patch.clear_remaining) {
                self.fillRemainingViewportColumns(&style_state, written_cols);
            }
        }

        emitHyperlinkTransition(self, snapshot, 0, &style_state.active_hyperlink);
        style_state.reset(self);
        self.emitRealCursor(patch.cursor);
    }
};

fn isValidUnicodeScalar(cp: u32) bool {
    if (cp > 0x10FFFF) return false;
    if (cp >= 0xD800 and cp <= 0xDFFF) return false;
    return true;
}

fn encodeCodepoints(buf: *[32]u8, cell: host.HostScreenCell) []const u8 {
    var len: usize = 0;
    var i: usize = 0;

    while (i < cell.chars_len and i < cell.chars.len) : (i += 1) {
        const cp = cell.chars[i];
        if (cp == 0) break;
        if (!isValidUnicodeScalar(cp)) continue;

        const remaining = buf[len..];
        const written = std.unicode.utf8Encode(@as(u21, @intCast(cp)), remaining) catch continue;
        len += written;
        if (len >= buf.len) break;
    }

    return buf[0..len];
}

fn colorEq(a: host.HostColor, b: host.HostColor) bool {
    return a.kind == b.kind and
        a.palette_index == b.palette_index and
        a.red == b.red and
        a.green == b.green and
        a.blue == b.blue and
        a.ansi_class == b.ansi_class;
}

fn emitColor(sink: anytype, base: u8, color: host.HostColor) void {
    switch (color.kind) {
        .default => sink.out("\x1b[{d}m", .{base + 1}),
        .indexed => switch (color.ansi_class) {
            .classic_low => sink.out("\x1b[{d}m", .{(if (base == 38) @as(u8, 30) else @as(u8, 40)) + color.palette_index}),
            .classic_bright => sink.out("\x1b[{d}m", .{(if (base == 38) @as(u8, 90) else @as(u8, 100)) + (color.palette_index - 8)}),
            .indexed_extended => sink.out("\x1b[{d};5;{d}m", .{ base, color.palette_index }),
            .none => sink.out("\x1b[{d};5;{d}m", .{ base, color.palette_index }),
        },
        .rgb => sink.out("\x1b[{d};2;{d};{d};{d}m", .{ base, color.red, color.green, color.blue }),
    }
}

fn emitCell(sink: anytype, cell: host.HostScreenCell, style_state: *StyleState) void {
    style_state.diffAndEmit(sink, cell);

    var buf: [32]u8 = undefined;
    const text = encodeCodepoints(&buf, cell);
    if (text.len != 0) {
        sink.writeBytes(text);
        return;
    }

    if (cell.width == 1) {
        sink.writeBytes(" ");
    }
}

fn emitHyperlinkTransition(sink: anytype, snapshot: *const host.HostScreenSnapshot, target: u32, current: *u32) void {
    if (current.* == target) return;

    if (current.* != 0) sink.writeBytes("\x1b]8;;\x1b\\");

    if (target != 0 and target <= snapshot.hyperlinks.len) {
        const link = snapshot.hyperlinks[target - 1];
        sink.writeBytes("\x1b]8;");
        sink.writeBytes(link.params);
        sink.writeBytes(";");
        sink.writeBytes(link.uri);
        sink.writeBytes("\x1b\\");
        current.* = target;
        return;
    }

    current.* = 0;
}

test "emitPatch applies visible final cursor state" {
    var render_buf = std.ArrayList(u8){};
    defer render_buf.deinit(std.testing.allocator);

    var adapter = SingleViewportAdapter{
        .viewport = Viewport.init(2, 3, 4, 5),
        .render_buf = &render_buf,
    };
    var patch = ViewportPatch.init(false, std.testing.allocator);
    defer patch.deinit(std.testing.allocator);
    patch.cursor = .{ .visible = true, .row = 1, .col = 2 };

    const snapshot = host.HostScreenSnapshot{
        .rows = 0,
        .cols = 0,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = true,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = &.{},
        .lines = &.{},
    };

    adapter.emitPatch(&patch, &snapshot);

    try std.testing.expect(std.mem.indexOf(u8, render_buf.items, "\x1b[?25l") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_buf.items, "\x1b[?25h") != null);
    try std.testing.expect(std.mem.endsWith(u8, render_buf.items, "\x1b[4;6H"));
}

test "emitPatch preserves hidden final cursor state" {
    var render_buf = std.ArrayList(u8){};
    defer render_buf.deinit(std.testing.allocator);

    var adapter = SingleViewportAdapter{
        .viewport = Viewport.init(2, 3, 4, 5),
        .render_buf = &render_buf,
    };
    var patch = ViewportPatch.init(false, std.testing.allocator);
    defer patch.deinit(std.testing.allocator);
    patch.cursor = .{ .visible = false, .row = 1, .col = 2 };

    const snapshot = host.HostScreenSnapshot{
        .rows = 0,
        .cols = 0,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = false,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = &.{},
        .lines = &.{},
    };

    adapter.emitPatch(&patch, &snapshot);

    try std.testing.expect(std.mem.indexOf(u8, render_buf.items, "\x1b[?25l") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_buf.items, "\x1b[?25h") == null);
    try std.testing.expect(!std.mem.endsWith(u8, render_buf.items, "H"));
}

test "emitPatch advances source cells independently from display width" {
    var render_buf = std.ArrayList(u8){};
    defer render_buf.deinit(std.testing.allocator);

    var adapter = SingleViewportAdapter{
        .viewport = Viewport.init(0, 0, 1, 4),
        .render_buf = &render_buf,
    };
    var patch = ViewportPatch.init(false, std.testing.allocator);
    defer patch.deinit(std.testing.allocator);

    var row = RowPatch.init(0);
    defer row.deinit(std.testing.allocator);

    const wide = host.HostScreenCell{
        .chars = [_]u32{ 0x4E2D, 0, 0, 0, 0, 0 },
        .chars_len = 1,
        .width = 2,
        .attrs = .{},
        .fg = .{ .kind = .default },
        .bg = .{ .kind = .default },
        .hyperlink = 0,
    };
    const narrow = host.HostScreenCell{
        .chars = [_]u32{ 'A', 0, 0, 0, 0, 0 },
        .chars_len = 1,
        .width = 1,
        .attrs = .{},
        .fg = .{ .kind = .default },
        .bg = .{ .kind = .default },
        .hyperlink = 0,
    };
    const cells = [_]host.HostScreenCell{ wide, narrow };

    try row.runs.append(std.testing.allocator, TextRun.init(0, 4, cells[0..]));
    try patch.rows.append(std.testing.allocator, row);
    _ = patch.rows.pop();

    const snapshot = host.HostScreenSnapshot{
        .rows = 1,
        .cols = 4,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = true,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = &.{},
        .lines = &.{},
    };

    adapter.emitPatch(&patch, &snapshot);

    try std.testing.expect(std.mem.indexOf(u8, render_buf.items, "A") != null);
}

test "emitPatch closes active hyperlink and resets style before final cursor" {
    var render_buf = std.ArrayList(u8){};
    defer render_buf.deinit(std.testing.allocator);

    var adapter = SingleViewportAdapter{
        .viewport = Viewport.init(0, 0, 1, 4),
        .render_buf = &render_buf,
    };
    var patch = ViewportPatch.init(false, std.testing.allocator);
    defer patch.deinit(std.testing.allocator);
    patch.cursor = .{ .visible = true, .row = 0, .col = 1 };

    var row = RowPatch.init(0);
    defer row.deinit(std.testing.allocator);

    const linked = host.HostScreenCell{
        .chars = [_]u32{ 'X', 0, 0, 0, 0, 0 },
        .chars_len = 1,
        .width = 1,
        .attrs = .{ .bold = true },
        .fg = .{ .kind = .default },
        .bg = .{ .kind = .default },
        .hyperlink = 1,
    };
    const cells = [_]host.HostScreenCell{ linked };

    try row.runs.append(std.testing.allocator, TextRun.init(0, 1, cells[0..]));
    try patch.rows.append(std.testing.allocator, row);
    _ = patch.rows.pop();

    const hyperlink = [_]host.HostHyperlink{.{ .id = 1, .params = "id=1", .uri = "https://example.com" }};
    const snapshot = host.HostScreenSnapshot{
        .rows = 1,
        .cols = 4,
        .cursor_row = 0,
        .cursor_col = 1,
        .cursor_visible = true,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = hyperlink[0..],
        .lines = &.{},
    };

    adapter.emitPatch(&patch, &snapshot);

    try std.testing.expect(std.mem.indexOf(u8, render_buf.items, "\x1b]8;id=1;https://example.com\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_buf.items, "\x1b]8;;\x1b\\") != null);
    try std.testing.expect(std.mem.count(u8, render_buf.items, "\x1b[0m") >= 2);
    try std.testing.expect(std.mem.endsWith(u8, render_buf.items, "\x1b[?25h\x1b[1;2H"));
}
