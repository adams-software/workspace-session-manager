const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");
const host = @import("session_host_vpty");
const TerminalModel = @import("terminal_model").TerminalModel;
const StdoutThread = @import("stdout_thread").StdoutThread;

pub const OutputState = struct {
    alt_screen: bool = false,
    cursor_visible: bool = true,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    has_drawn: bool = false,
};

pub const Renderer = struct {
    output_state: OutputState = .{},
    pending_output_state: ?OutputState = null,
    pending_output_version: u64 = 0,

    committed_snapshot: ?host.HostScreenSnapshot = null,
    pending_snapshot: ?host.HostScreenSnapshot = null,

    stdout_thread: *StdoutThread,
    needs_render: bool = true,
    force_full_render: bool = true,
    last_generated_version: u64 = 0,
    render_buf: std.ArrayList(u8) = .{},

    pub fn init(stdout_thread: *StdoutThread) Renderer {
        var self = Renderer{ .stdout_thread = stdout_thread };
        self.ensureBufferCapacity();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.freeStoredSnapshots();
        self.render_buf.deinit(std.heap.page_allocator);
    }

    fn ensureBufferCapacity(self: *Renderer) void {
        if (self.render_buf.capacity == 0) {
            self.render_buf.ensureTotalCapacity(std.heap.page_allocator, 4096) catch {};
        }
    }

    pub fn publishModelChanged(self: *Renderer, changed: actor_mailboxes.ModelChanged) void {
        self.needs_render = true;
        if (changed.force_full_render) {
            self.force_full_render = true;
        }
    }

    pub fn needsRender(self: *const Renderer) bool {
        return self.needs_render;
    }

    pub fn takeSnapshot(self: *Renderer, model: *const TerminalModel) ?struct { version: u64, snapshot: host.HostScreenSnapshot } {
        if (!self.needs_render) return null;

        const snapshot = model.snapshot(std.heap.page_allocator) catch return null;
        return .{ .version = model.currentVersion(), .snapshot = snapshot };
    }

    pub fn renderSnapshot(self: *Renderer, version: u64, snapshot: host.HostScreenSnapshot) void {
        if (!self.needs_render) {
            var discarded = snapshot;
            host.freeScreenSnapshot(std.heap.page_allocator, &discarded);
            return;
        }
        self.needs_render = false;

        self.render_buf.clearRetainingCapacity();

        var owned_snapshot = snapshot;
        errdefer host.freeScreenSnapshot(std.heap.page_allocator, &owned_snapshot);

        var next_output_state = self.output_state;

        const must_full_redraw =
            self.force_full_render or
            !self.output_state.has_drawn or
            self.committed_snapshot == null or
            self.output_state.alt_screen != owned_snapshot.alt_screen or
            snapshotShapeChanged(self.committed_snapshot.?, &owned_snapshot);

        if (owned_snapshot.alt_screen != self.output_state.alt_screen or !self.output_state.has_drawn) {
            self.writeBytes(if (owned_snapshot.alt_screen) "\x1b[?1049h" else "\x1b[?1049l");
            next_output_state.alt_screen = owned_snapshot.alt_screen;
        }

        self.writeBytes("\x1b[?25l");

        if (must_full_redraw) {
            self.renderFullFrame(&owned_snapshot);
        } else {
            self.renderChangedRows(&self.committed_snapshot.?, &owned_snapshot);
        }
        self.force_full_render = false;

        self.moveCursor(owned_snapshot.cursor_row, owned_snapshot.cursor_col);

        if (owned_snapshot.cursor_visible != self.output_state.cursor_visible) {
            self.writeBytes(if (owned_snapshot.cursor_visible) "\x1b[?25h" else "\x1b[?25l");
            next_output_state.cursor_visible = owned_snapshot.cursor_visible;
        } else if (owned_snapshot.cursor_visible) {
            self.writeBytes("\x1b[?25h");
        }

        next_output_state.cursor_row = owned_snapshot.cursor_row;
        next_output_state.cursor_col = owned_snapshot.cursor_col;
        next_output_state.has_drawn = true;

        self.last_generated_version = version;

        self.stdout_thread.publishRenderCandidate(actor_mailboxes.RenderPublish{
            .version = self.last_generated_version,
            .bytes = self.render_buf.items,
        }) catch return;

        self.pending_output_state = next_output_state;
        self.pending_output_version = self.last_generated_version;
        self.replacePendingSnapshot(owned_snapshot);
    }

    pub fn reset(self: *Renderer) void {
        self.render_buf.clearRetainingCapacity();
        self.output_state = .{};
        self.pending_output_state = null;
        self.pending_output_version = 0;
        self.last_generated_version = 0;
        self.needs_render = true;
        self.force_full_render = true;
        self.ensureBufferCapacity();
    }

    pub fn noteCommitted(self: *Renderer, notice: actor_mailboxes.CommitNotice) void {
        if (self.pending_output_state) |state| {
            if (notice.version >= self.pending_output_version) {
                self.output_state = state;
                self.pending_output_state = null;

                if (self.pending_snapshot) |snapshot| {
                    if (self.committed_snapshot) |*old| {
                        host.freeScreenSnapshot(std.heap.page_allocator, old);
                    }
                    self.committed_snapshot = snapshot;
                    self.pending_snapshot = null;
                }

                self.pending_output_version = 0;
            }
        }
    }
    pub fn shutdown(self: *Renderer, version: u64) void {
        self.render_buf.clearRetainingCapacity();

        self.writeBytes("\x1b]8;;\x1b\\");
        if (self.output_state.alt_screen) {
            self.writeBytes("\x1b[?1049l");
        }
        self.writeBytes("\x1b[?25h");
        self.resetStyle();
        self.writeBytes("\x1b(B");
        self.writeBytes("\r\n");

        self.stdout_thread.publishRenderCandidate(actor_mailboxes.RenderPublish{
            .version = version,
            .bytes = self.render_buf.items,
        }) catch {};

        self.render_buf.clearRetainingCapacity();
        self.output_state = .{};
        self.pending_output_state = null;
        self.pending_output_version = 0;
        self.last_generated_version = 0;
        self.freeStoredSnapshots();
        self.needs_render = false;
    }

    fn writeBytes(self: *Renderer, bytes: []const u8) void {
        self.render_buf.appendSlice(std.heap.page_allocator, bytes) catch return;
    }

    fn out(self: *Renderer, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.writeBytes(rendered);
    }

    fn resetStyle(self: *Renderer) void {
        self.writeBytes("\x1b[0m");
    }

    fn moveCursor(self: *Renderer, row: u16, col: u16) void {
        self.out("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    fn clearScreen(self: *Renderer) void {
        self.writeBytes("\x1b[2J\x1b[H");
    }

    fn eraseToEndOfLine(self: *Renderer) void {
        self.writeBytes("\x1b[K");
    }

    fn renderFullFrame(self: *Renderer, snapshot: *const host.HostScreenSnapshot) void {
        self.clearScreen();

        var style_state = StyleState{};
        style_state.reset(self);

        for (snapshot.lines, 0..) |line, row_idx| {
            self.moveCursor(@intCast(row_idx), 0);

            var col: usize = 0;
            while (col < line.cells.len) {
                const cell = line.cells[col];
                if (cell.width == 0) {
                    col += 1;
                    continue;
                }
                emitHyperlinkTransition(self, snapshot, cell.hyperlink, &style_state.active_hyperlink);
                emitCell(self, cell, &style_state);
                col += @max(@as(usize, 1), @as(usize, cell.width));
            }

            emitHyperlinkTransition(self, snapshot, 0, &style_state.active_hyperlink);
            self.eraseToEndOfLine();
        }

        emitHyperlinkTransition(self, snapshot, 0, &style_state.active_hyperlink);
    }
    fn freeStoredSnapshots(self: *Renderer) void {
        if (self.committed_snapshot) |*snapshot| {
            host.freeScreenSnapshot(std.heap.page_allocator, snapshot);
            self.committed_snapshot = null;
        }
        if (self.pending_snapshot) |*snapshot| {
            host.freeScreenSnapshot(std.heap.page_allocator, snapshot);
            self.pending_snapshot = null;
        }
    }

    fn replacePendingSnapshot(self: *Renderer, snapshot: host.HostScreenSnapshot) void {
        if (self.pending_snapshot) |*old| {
            host.freeScreenSnapshot(std.heap.page_allocator, old);
        }
        self.pending_snapshot = snapshot;
    }

    fn renderChangedRows(self: *Renderer, prev: *const host.HostScreenSnapshot, next: *const host.HostScreenSnapshot) void {
        var row_idx: usize = 0;
        while (row_idx < next.lines.len) : (row_idx += 1) {
            const prev_line = prev.lines[row_idx];
            const next_line = next.lines[row_idx];

            if (!lineEq(prev_line, next_line)) {
                self.renderWholeRow(@intCast(row_idx), next, next_line);
            }
        }
    }

    fn renderWholeRow(
        self: *Renderer,
        row: u16,
        snapshot: *const host.HostScreenSnapshot,
        line: host.HostScreenLine,
    ) void {
        self.moveCursor(row, 0);

        var style_state = StyleState{};
        style_state.reset(self);

        var col: usize = 0;
        while (col < line.cells.len) {
            const cell = line.cells[col];
            if (cell.width == 0) {
                col += 1;
                continue;
            }
            emitHyperlinkTransition(self, snapshot, cell.hyperlink, &style_state.active_hyperlink);
            emitCell(self, cell, &style_state);
            col += @max(@as(usize, 1), @as(usize, cell.width));
        }

        emitHyperlinkTransition(self, snapshot, 0, &style_state.active_hyperlink);
        self.eraseToEndOfLine();
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

        const written = std.unicode.utf8Encode(@as(u21, @intCast(cp)), buf[len..]) catch continue;
        len += written;
    }

    return buf[0..len];
}

const StyleState = struct {
    fg: host.HostColor = .{},
    bg: host.HostColor = .{},
    attrs: host.HostCellAttrs = .{},
    active_hyperlink: u32 = 0,

    fn reset(self: *StyleState, renderer: *Renderer) void {
        renderer.resetStyle();
        self.* = .{};
    }

    fn emitBool(renderer: *Renderer, on_code: []const u8, off_code: []const u8, current: *bool, target: bool) void {
        if (current.* == target) return;
        renderer.writeBytes(if (target) on_code else off_code);
        current.* = target;
    }

    fn diffAndEmit(self: *StyleState, renderer: *Renderer, cell: host.HostScreenCell) void {
        emitBool(renderer, "\x1b[1m", "\x1b[22m", &self.attrs.bold, cell.attrs.bold);
        emitBool(renderer, "\x1b[3m", "\x1b[23m", &self.attrs.italic, cell.attrs.italic);
        emitBool(renderer, "\x1b[4m", "\x1b[24m", &self.attrs.underline, cell.attrs.underline);
        emitBool(renderer, "\x1b[5m", "\x1b[25m", &self.attrs.blink, cell.attrs.blink);
        emitBool(renderer, "\x1b[7m", "\x1b[27m", &self.attrs.reverse, cell.attrs.reverse);
        emitBool(renderer, "\x1b[8m", "\x1b[28m", &self.attrs.conceal, cell.attrs.conceal);

        if (!colorEq(self.fg, cell.fg)) {
            emitColor(renderer, 38, cell.fg);
            self.fg = cell.fg;
        }
        if (!colorEq(self.bg, cell.bg)) {
            emitColor(renderer, 48, cell.bg);
            self.bg = cell.bg;
        }
    }
};

fn emitHyperlinkTransition(renderer: *Renderer, snapshot: *const host.HostScreenSnapshot, target: u32, current: *u32) void {
    if (current.* == target) return;

    if (current.* != 0) renderer.writeBytes("\x1b]8;;\x1b\\");

    if (target != 0 and target <= snapshot.hyperlinks.len) {
        const link = snapshot.hyperlinks[target - 1];
        renderer.writeBytes("\x1b]8;");
        renderer.writeBytes(link.params);
        renderer.writeBytes(";");
        renderer.writeBytes(link.uri);
        renderer.writeBytes("\x1b\\");
        current.* = target;
        return;
    }

    current.* = 0;
}

fn colorEq(a: host.HostColor, b: host.HostColor) bool {
    return a.kind == b.kind and
        a.palette_index == b.palette_index and
        a.red == b.red and
        a.green == b.green and
        a.blue == b.blue and
        a.ansi_class == b.ansi_class and
        a.promoted_by_bold == b.promoted_by_bold;
}

fn emitColor(renderer: *Renderer, base: u8, color: host.HostColor) void {
    switch (color.kind) {
        .default => renderer.out("\x1b[{d}m", .{base + 1}),
        .indexed => switch (color.ansi_class) {
            .classic_low => renderer.out("\x1b[{d}m", .{(if (base == 38) @as(u8, 30) else @as(u8, 40)) + color.palette_index}),
            .classic_bright => renderer.out("\x1b[{d}m", .{(if (base == 38) @as(u8, 90) else @as(u8, 100)) + (color.palette_index - 8)}),
            .indexed_extended => renderer.out("\x1b[{d};5;{d}m", .{ base, color.palette_index }),
            .none => renderer.out("\x1b[{d};5;{d}m", .{ base, color.palette_index }),
        },
        .rgb => renderer.out("\x1b[{d};2;{d};{d};{d}m", .{ base, color.red, color.green, color.blue }),
    }
}

fn emitCell(renderer: *Renderer, cell: host.HostScreenCell, style_state: *StyleState) void {
    style_state.diffAndEmit(renderer, cell);

    var buf: [32]u8 = undefined;
    const text = encodeCodepoints(&buf, cell);
    if (text.len != 0) {
        renderer.writeBytes(text);
        return;
    }

    if (cell.width == 1) {
        renderer.writeBytes(" ");
    }
}
fn snapshotShapeChanged(a: host.HostScreenSnapshot, b: *const host.HostScreenSnapshot) bool {
    return a.rows != b.rows or a.cols != b.cols or a.lines.len != b.lines.len;
}

fn lineEq(a: host.HostScreenLine, b: host.HostScreenLine) bool {
    if (a.eol != b.eol) return false;
    if (a.cells.len != b.cells.len) return false;

    var i: usize = 0;
    while (i < a.cells.len) : (i += 1) {
        if (!cellEq(a.cells[i], b.cells[i])) return false;
    }
    return true;
}

fn cellEq(a: host.HostScreenCell, b: host.HostScreenCell) bool {
    return a.width == b.width and
        a.hyperlink == b.hyperlink and
        colorEq(a.fg, b.fg) and
        colorEq(a.bg, b.bg) and
        attrsEq(a.attrs, b.attrs) and
        a.chars_len == b.chars_len and
        std.mem.eql(u32, a.chars[0..a.chars_len], b.chars[0..b.chars_len]);
}

fn attrsEq(a: host.HostCellAttrs, b: host.HostCellAttrs) bool {
    return a.bold == b.bold and
        a.italic == b.italic and
        a.underline == b.underline and
        a.blink == b.blink and
        a.reverse == b.reverse and
        a.conceal == b.conceal and
        a.strike == b.strike and
        a.font == b.font;
}

test "hyperlink transitions open once per run and close on change/end" {
    var renderer = Renderer{ .stdout_thread = undefined };
    renderer.ensureBufferCapacity();
    defer renderer.deinit();

    const links = [_]host.HostHyperlink{
        .{ .params = "id=1", .uri = "https://a.test" },
        .{ .params = "id=2", .uri = "https://b.test" },
    };

    var current: u32 = 0;
    emitHyperlinkTransition(&renderer, &.{
        .rows = 0,
        .cols = 0,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = false,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = links[0..],
        .lines = &.{},
    }, 1, &current);
    emitHyperlinkTransition(&renderer, &.{
        .rows = 0,
        .cols = 0,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = false,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = links[0..],
        .lines = &.{},
    }, 1, &current);
    emitHyperlinkTransition(&renderer, &.{
        .rows = 0,
        .cols = 0,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = false,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = links[0..],
        .lines = &.{},
    }, 2, &current);
    emitHyperlinkTransition(&renderer, &.{
        .rows = 0,
        .cols = 0,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = false,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = links[0..],
        .lines = &.{},
    }, 0, &current);

    try std.testing.expectEqualStrings(
        "\x1b]8;id=1;https://a.test\x1b\\\x1b]8;;\x1b\\\x1b]8;id=2;https://b.test\x1b\\\x1b]8;;\x1b\\",
        renderer.render_buf.items,
    );
}

test "emitColor preserves classic ansi and extended indexed encodings" {
    var renderer = Renderer{ .stdout_thread = undefined };
    renderer.ensureBufferCapacity();
    defer renderer.deinit();

    emitColor(&renderer, 38, .{ .kind = .indexed, .palette_index = 4, .ansi_class = .classic_low });
    emitColor(&renderer, 38, .{ .kind = .indexed, .palette_index = 12, .ansi_class = .classic_bright });
    emitColor(&renderer, 38, .{ .kind = .indexed, .palette_index = 27, .ansi_class = .indexed_extended });
    emitColor(&renderer, 48, .{ .kind = .indexed, .palette_index = 5, .ansi_class = .classic_low });
    emitColor(&renderer, 48, .{ .kind = .indexed, .palette_index = 13, .ansi_class = .classic_bright });
    emitColor(&renderer, 48, .{ .kind = .indexed, .palette_index = 200, .ansi_class = .indexed_extended });

    try std.testing.expectEqualStrings(
        "\x1b[34m\x1b[94m\x1b[38;5;27m\x1b[45m\x1b[105m\x1b[48;5;200m",
        renderer.render_buf.items,
    );
}
