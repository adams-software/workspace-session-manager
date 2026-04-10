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

pub const RenderActor = struct {
    output_state: OutputState = .{},
    stdout_actor: ?*StdoutThread = null,
    latest_model_changed: ?actor_mailboxes.ModelChanged = null,
    latest_commit_notice: ?actor_mailboxes.CommitNotice = null,
    needs_render: bool = true,
    last_generated_frame: ?host.HostScreenSnapshot = null,
    last_generated_version: u64 = 0,
    committed_frame: ?host.HostScreenSnapshot = null,
    committed_version: u64 = 0,
    render_buf: std.ArrayList(u8) = .{},

    pub fn init(stdout_actor: *StdoutThread) RenderActor {
        var self = RenderActor{};
        self.setStdoutActor(stdout_actor);
        return self;
    }

    pub fn deinit(self: *RenderActor) void {
        self.freeLastGeneratedFrame();
        self.freeCommittedFrame();
        self.render_buf.deinit(std.heap.page_allocator);
    }

    fn setStdoutActor(self: *RenderActor, stdout_actor: *StdoutThread) void {
        self.stdout_actor = stdout_actor;
        if (self.render_buf.capacity == 0) {
            self.render_buf.ensureTotalCapacity(std.heap.page_allocator, 4096) catch {};
        }
    }

    pub fn publishModelChanged(self: *RenderActor, changed: actor_mailboxes.ModelChanged) void {
        self.latest_model_changed = changed;
    }

    pub fn renderDamaged(self: *RenderActor) void {
        self.needs_render = true;
    }

    pub fn needsRender(self: *const RenderActor) bool {
        return self.needs_render;
    }

    pub fn takeSnapshot(self: *RenderActor, model: *const TerminalModel) ?struct { version: u64, snapshot: host.HostScreenSnapshot } {
        if (!self.needs_render) return null;

        const snapshot = model.snapshot(std.heap.page_allocator) catch return null;
        return .{ .version = model.currentVersion(), .snapshot = snapshot };
    }

    pub fn renderSnapshot(self: *RenderActor, version: u64, snapshot: host.HostScreenSnapshot) void {
        if (!self.needs_render) {
            var discarded = snapshot;
            host.freeScreenSnapshot(std.heap.page_allocator, &discarded);
            return;
        }
        self.needs_render = false;

        self.render_buf.clearRetainingCapacity();

        var owned_snapshot = snapshot;
        errdefer host.freeScreenSnapshot(std.heap.page_allocator, &owned_snapshot);

        if (owned_snapshot.alt_screen != self.output_state.alt_screen or !self.output_state.has_drawn) {
            self.writeBytes(if (owned_snapshot.alt_screen) "\x1b[?1049h" else "\x1b[?1049l");
            self.output_state.alt_screen = owned_snapshot.alt_screen;
        }

        self.writeBytes("\x1b[?25l");
        self.renderFullFrame(&owned_snapshot);

        self.moveCursor(owned_snapshot.cursor_row, owned_snapshot.cursor_col);

        if (owned_snapshot.cursor_visible != self.output_state.cursor_visible) {
            self.writeBytes(if (owned_snapshot.cursor_visible) "\x1b[?25h" else "\x1b[?25l");
            self.output_state.cursor_visible = owned_snapshot.cursor_visible;
        } else if (owned_snapshot.cursor_visible) {
            self.writeBytes("\x1b[?25h");
        }

        self.output_state.cursor_row = owned_snapshot.cursor_row;
        self.output_state.cursor_col = owned_snapshot.cursor_col;
        self.output_state.has_drawn = true;

        self.freeLastGeneratedFrame();
        self.last_generated_frame = owned_snapshot;
        self.last_generated_version = version;

        const stdout_actor = self.stdout_actor orelse return;
        stdout_actor.publishRenderCandidate(actor_mailboxes.RenderPublish{
            .version = self.last_generated_version,
            .bytes = self.render_buf.items,
        }) catch return;
    }

    pub fn reset(self: *RenderActor) void {
        self.freeLastGeneratedFrame();
        self.freeCommittedFrame();
        self.render_buf.clearRetainingCapacity();
        self.output_state = .{};
        self.latest_model_changed = null;
        self.latest_commit_notice = null;
        self.last_generated_version = 0;
        self.committed_version = 0;
        self.needs_render = true;
    }

    pub fn noteCommitted(self: *RenderActor, notice: actor_mailboxes.CommitNotice) void {
        self.latest_commit_notice = notice;
        if (self.last_generated_frame == null) return;
        if (self.last_generated_version == 0 or self.last_generated_version > notice.version) return;

        self.freeCommittedFrame();
        self.committed_frame = self.last_generated_frame;
        self.committed_version = self.last_generated_version;
        self.last_generated_frame = null;
    }

    fn noteCommittedThrough(self: *RenderActor, version: u64) void {
        self.noteCommitted(.{ .version = version });
    }

    pub fn shutdown(self: *RenderActor, version: u64) void {
        self.render_buf.clearRetainingCapacity();

        if (self.output_state.alt_screen) {
            self.writeBytes("\x1b[?1049l");
        }
        self.writeBytes("\x1b[?25h");
        self.resetStyle();
        self.writeBytes("\x1b(B");

        if (self.stdout_actor) |stdout_actor| {
            stdout_actor.publishRenderCandidate(actor_mailboxes.RenderPublish{
                .version = version,
                .bytes = self.render_buf.items,
            }) catch {};
        }

        self.freeLastGeneratedFrame();
        self.freeCommittedFrame();
        self.render_buf.clearRetainingCapacity();
        self.output_state = .{};
        self.latest_model_changed = null;
        self.latest_commit_notice = null;
        self.last_generated_version = 0;
        self.committed_version = 0;
        self.needs_render = false;
    }

    fn writeBytes(self: *RenderActor, bytes: []const u8) void {
        self.render_buf.appendSlice(std.heap.page_allocator, bytes) catch return;
    }

    fn out(self: *RenderActor, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.writeBytes(rendered);
    }

    fn resetStyle(self: *RenderActor) void {
        self.writeBytes("\x1b[0m");
    }

    fn moveCursor(self: *RenderActor, row: u16, col: u16) void {
        self.out("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    fn clearScreen(self: *RenderActor) void {
        self.writeBytes("\x1b[2J\x1b[H");
    }

    fn eraseToEndOfLine(self: *RenderActor) void {
        self.writeBytes("\x1b[K");
    }

    fn renderFullFrame(self: *RenderActor, snapshot: *const host.HostScreenSnapshot) void {
        self.clearScreen();

        var style_state = StyleState{};
        style_state.reset(self);

        for (snapshot.lines, 0..) |line, row_idx| {
            self.moveCursor(@intCast(row_idx), 0);

            var col: usize = 0;
            while (col < line.cells.len) : (col += 1) {
                emitCell(self, line.cells[col], &style_state);
            }

            if (line.eol) {
                self.eraseToEndOfLine();
            }
        }
    }

    fn renderDiff(self: *RenderActor, prev: *const host.HostScreenSnapshot, next: *const host.HostScreenSnapshot) void {
        if (prev.rows != next.rows or prev.cols != next.cols) {
            self.renderFullFrame(next);
            return;
        }

        var style_state = StyleState{};
        style_state.reset(self);

        for (next.lines, 0..) |next_line, row_idx| {
            const prev_line = prev.lines[row_idx];

            if (lineEqual(prev_line, next_line)) continue;

            var col: usize = 0;
            while (col < next_line.cells.len) {
                if (cellEqual(prev_line.cells[col], next_line.cells[col])) {
                    col += 1;
                    continue;
                }

                const run_start = col;
                col += 1;

                while (col < next_line.cells.len and !cellEqual(prev_line.cells[col], next_line.cells[col])) : (col += 1) {}

                renderChangedRun(self, row_idx, run_start, col, next_line, &style_state);
            }

            const prev_end = lineVisibleEnd(prev_line);
            const next_end = lineVisibleEnd(next_line);
            if (prev_end > next_end or next_line.eol != prev_line.eol) {
                self.moveCursor(@intCast(row_idx), @intCast(next_end));
                self.eraseToEndOfLine();
            }
        }
    }

    fn freeLastGeneratedFrame(self: *RenderActor) void {
        if (self.last_generated_frame) |*snap| {
            host.freeScreenSnapshot(std.heap.page_allocator, snap);
            self.last_generated_frame = null;
        }
    }

    fn freeCommittedFrame(self: *RenderActor) void {
        if (self.committed_frame) |*snap| {
            host.freeScreenSnapshot(std.heap.page_allocator, snap);
            self.committed_frame = null;
        }
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

        if (!isValidUnicodeScalar(cp)) {
            if (len < buf.len) {
                buf[len] = '?';
                len += 1;
            }
            continue;
        }

        const written = std.unicode.utf8Encode(@as(u21, @intCast(cp)), buf[len..]) catch {
            if (len < buf.len) {
                buf[len] = '?';
                len += 1;
            }
            continue;
        };
        len += written;
    }

    return buf[0..len];
}

const StyleState = struct {
    fg: host.HostColor = .{},
    bg: host.HostColor = .{},
    attrs: host.HostCellAttrs = .{},

    fn reset(self: *StyleState, actor: *RenderActor) void {
        actor.resetStyle();
        self.* = .{};
    }

    fn emitBool(actor: *RenderActor, on_code: []const u8, off_code: []const u8, current: *bool, target: bool) void {
        if (current.* == target) return;
        actor.writeBytes(if (target) on_code else off_code);
        current.* = target;
    }

    fn diffAndEmit(self: *StyleState, actor: *RenderActor, cell: host.HostScreenCell) void {
        emitBool(actor, "\x1b[1m", "\x1b[22m", &self.attrs.bold, cell.attrs.bold);
        emitBool(actor, "\x1b[3m", "\x1b[23m", &self.attrs.italic, cell.attrs.italic);
        emitBool(actor, "\x1b[4m", "\x1b[24m", &self.attrs.underline, cell.attrs.underline);
        emitBool(actor, "\x1b[5m", "\x1b[25m", &self.attrs.blink, cell.attrs.blink);
        emitBool(actor, "\x1b[7m", "\x1b[27m", &self.attrs.reverse, cell.attrs.reverse);
        emitBool(actor, "\x1b[8m", "\x1b[28m", &self.attrs.conceal, cell.attrs.conceal);
        emitBool(actor, "\x1b[9m", "\x1b[29m", &self.attrs.strike, cell.attrs.strike);

        if (self.attrs.font != cell.attrs.font) {
            if (cell.attrs.font == 0) {
                actor.writeBytes("\x1b[10m");
            } else {
                actor.out("\x1b[{d}m", .{10 + cell.attrs.font});
            }
            self.attrs.font = cell.attrs.font;
        }

        if (!std.meta.eql(self.fg, cell.fg)) {
            switch (cell.fg.kind) {
                .default => actor.writeBytes("\x1b[39m"),
                .indexed => actor.out("\x1b[38;5;{d}m", .{cell.fg.palette_index}),
                .rgb => actor.out("\x1b[38;2;{d};{d};{d}m", .{ cell.fg.red, cell.fg.green, cell.fg.blue }),
            }
            self.fg = cell.fg;
        }

        if (!std.meta.eql(self.bg, cell.bg)) {
            switch (cell.bg.kind) {
                .default => actor.writeBytes("\x1b[49m"),
                .indexed => actor.out("\x1b[48;5;{d}m", .{cell.bg.palette_index}),
                .rgb => actor.out("\x1b[48;2;{d};{d};{d}m", .{ cell.bg.red, cell.bg.green, cell.bg.blue }),
            }
            self.bg = cell.bg;
        }
    }
};

fn cellEqual(a: host.HostScreenCell, b: host.HostScreenCell) bool {
    return a.chars_len == b.chars_len and
        a.width == b.width and
        std.mem.eql(u32, a.chars[0..a.chars_len], b.chars[0..b.chars_len]) and
        std.meta.eql(a.fg, b.fg) and
        std.meta.eql(a.bg, b.bg) and
        std.meta.eql(a.attrs, b.attrs);
}

fn lineEqual(a: host.HostScreenLine, b: host.HostScreenLine) bool {
    if (a.eol != b.eol) return false;
    if (a.cells.len != b.cells.len) return false;
    for (a.cells, b.cells) |ac, bc| {
        if (!cellEqual(ac, bc)) return false;
    }
    return true;
}

fn lineVisibleEnd(line: host.HostScreenLine) usize {
    var col = line.cells.len;
    while (col > 0) {
        const cell = line.cells[col - 1];
        if (cell.width == 0) {
            col -= 1;
            continue;
        }
        return col;
    }
    return 0;
}

fn emitCell(actor: *RenderActor, cell: host.HostScreenCell, style_state: *StyleState) void {
    if (cell.width == 0) return;

    style_state.diffAndEmit(actor, cell);

    if (cell.chars_len == 0) {
        actor.writeBytes(" ");
        return;
    }

    var buf: [32]u8 = undefined;
    const text = encodeCodepoints(&buf, cell);
    actor.writeBytes(text);
}

fn renderChangedRun(
    actor: *RenderActor,
    row_idx: usize,
    start_col: usize,
    end_col: usize,
    line: host.HostScreenLine,
    style_state: *StyleState,
) void {
    var draw_start = start_col;
    while (draw_start > 0 and line.cells[draw_start].width == 0) {
        draw_start -= 1;
    }

    actor.moveCursor(@intCast(row_idx), @intCast(draw_start));

    var col = draw_start;
    while (col < end_col and col < line.cells.len) : (col += 1) {
        emitCell(actor, line.cells[col], style_state);
    }
}
