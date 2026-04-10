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
    // Current renderer policy is intentionally simple: generate a full-frame redraw,
    // track only generated/committed versions, and avoid retaining whole snapshots
    // until committed-diff rendering is intentionally reintroduced.
    output_state: OutputState = .{},
    stdout_actor: ?*StdoutThread = null,
    latest_model_changed: ?actor_mailboxes.ModelChanged = null,
    latest_commit_notice: ?actor_mailboxes.CommitNotice = null,
    needs_render: bool = true,
    last_generated_version: u64 = 0,
    committed_version: u64 = 0,
    render_buf: std.ArrayList(u8) = .{},

    pub fn init(stdout_actor: *StdoutThread) RenderActor {
        var self = RenderActor{};
        self.setStdoutActor(stdout_actor);
        return self;
    }

    pub fn deinit(self: *RenderActor) void {
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

        host.freeScreenSnapshot(std.heap.page_allocator, &owned_snapshot);
        self.last_generated_version = version;

        const stdout_actor = self.stdout_actor orelse return;
        stdout_actor.publishRenderCandidate(actor_mailboxes.RenderPublish{
            .version = self.last_generated_version,
            .bytes = self.render_buf.items,
        }) catch return;
    }

    pub fn reset(self: *RenderActor) void {
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
        if (self.last_generated_version == 0 or self.last_generated_version > notice.version) return;
        self.committed_version = self.last_generated_version;
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

        if (!colorEq(self.fg, cell.fg)) {
            emitColor(actor, 38, cell.fg);
            self.fg = cell.fg;
        }
        if (!colorEq(self.bg, cell.bg)) {
            emitColor(actor, 48, cell.bg);
            self.bg = cell.bg;
        }
    }
};

fn colorEq(a: host.HostColor, b: host.HostColor) bool {
    return a.kind == b.kind and
        a.palette_index == b.palette_index and
        a.red == b.red and
        a.green == b.green and
        a.blue == b.blue;
}

fn emitColor(actor: *RenderActor, base: u8, color: host.HostColor) void {
    switch (color.kind) {
        .default => actor.out("\x1b[{d}m", .{base + 1}),
        .indexed => actor.out("\x1b[{d};5;{d}m", .{ base, color.palette_index }),
        .rgb => actor.out("\x1b[{d};2;{d};{d};{d}m", .{ base, color.red, color.green, color.blue }),
    }
}

fn emitCell(actor: *RenderActor, cell: host.HostScreenCell, style_state: *StyleState) void {
    style_state.diffAndEmit(actor, cell);

    var buf: [32]u8 = undefined;
    const text = encodeCodepoints(&buf, cell);
    if (text.len == 0) {
        actor.writeBytes(" ");
    } else {
        actor.writeBytes(text);
    }
}
