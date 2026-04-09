const std = @import("std");
const host = @import("session_host_vpty");
const c = @cImport({
    @cInclude("unistd.h");
});

pub const OutputState = struct {
    alt_screen: bool = false,
    cursor_visible: bool = true,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    has_drawn: bool = false,
};

var global_output_state: OutputState = .{};
var global_session_host: ?*host.SessionHost = null;
var needs_render: bool = true;
var last_frame: ?host.HostScreenSnapshot = null;

fn writeBytes(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(c.STDOUT_FILENO, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeBytes(rendered);
}

fn resetStyle() void {
    writeBytes("\x1b[0m");
}

fn moveCursor(row: u16, col: u16) void {
    out("\x1b[{d};{d}H", .{ row + 1, col + 1 });
}

fn clearScreen() void {
    writeBytes("\x1b[2J\x1b[H");
}

fn eraseToEndOfLine() void {
    writeBytes("\x1b[K");
}

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

    fn reset(self: *StyleState) void {
        resetStyle();
        self.* = .{};
    }

    fn emitBool(on_code: []const u8, off_code: []const u8, current: *bool, target: bool) void {
        if (current.* == target) return;
        writeBytes(if (target) on_code else off_code);
        current.* = target;
    }

    fn diffAndEmit(self: *StyleState, cell: host.HostScreenCell) void {
        emitBool("\x1b[1m", "\x1b[22m", &self.attrs.bold, cell.attrs.bold);
        emitBool("\x1b[3m", "\x1b[23m", &self.attrs.italic, cell.attrs.italic);
        emitBool("\x1b[4m", "\x1b[24m", &self.attrs.underline, cell.attrs.underline);
        emitBool("\x1b[5m", "\x1b[25m", &self.attrs.blink, cell.attrs.blink);
        emitBool("\x1b[7m", "\x1b[27m", &self.attrs.reverse, cell.attrs.reverse);
        emitBool("\x1b[8m", "\x1b[28m", &self.attrs.conceal, cell.attrs.conceal);
        emitBool("\x1b[9m", "\x1b[29m", &self.attrs.strike, cell.attrs.strike);

        if (self.attrs.font != cell.attrs.font) {
            if (cell.attrs.font == 0) {
                writeBytes("\x1b[10m");
            } else {
                out("\x1b[{d}m", .{10 + cell.attrs.font});
            }
            self.attrs.font = cell.attrs.font;
        }

        if (!std.meta.eql(self.fg, cell.fg)) {
            switch (cell.fg.kind) {
                .default => writeBytes("\x1b[39m"),
                .indexed => out("\x1b[38;5;{d}m", .{cell.fg.palette_index}),
                .rgb => out("\x1b[38;2;{d};{d};{d}m", .{ cell.fg.red, cell.fg.green, cell.fg.blue }),
            }
            self.fg = cell.fg;
        }

        if (!std.meta.eql(self.bg, cell.bg)) {
            switch (cell.bg.kind) {
                .default => writeBytes("\x1b[49m"),
                .indexed => out("\x1b[48;5;{d}m", .{cell.bg.palette_index}),
                .rgb => out("\x1b[48;2;{d};{d};{d}m", .{ cell.bg.red, cell.bg.green, cell.bg.blue }),
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

fn emitCell(cell: host.HostScreenCell, style_state: *StyleState) void {
    if (cell.width == 0) return;

    style_state.diffAndEmit(cell);

    if (cell.chars_len == 0) {
        writeBytes(" ");
        return;
    }

    var buf: [32]u8 = undefined;
    const text = encodeCodepoints(&buf, cell);
    writeBytes(text);
}

fn renderChangedRun(
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

    moveCursor(@intCast(row_idx), @intCast(draw_start));

    var col = draw_start;
    while (col < end_col and col < line.cells.len) : (col += 1) {
        emitCell(line.cells[col], style_state);
    }
}

fn renderFullFrame(snapshot: *const host.HostScreenSnapshot) void {
    clearScreen();

    var style_state = StyleState{};
    style_state.reset();

    for (snapshot.lines, 0..) |line, row_idx| {
        moveCursor(@intCast(row_idx), 0);

        var col: usize = 0;
        while (col < line.cells.len) : (col += 1) {
            emitCell(line.cells[col], &style_state);
        }

        if (line.eol) {
            eraseToEndOfLine();
        }
    }
}

fn renderDiff(prev: *const host.HostScreenSnapshot, next: *const host.HostScreenSnapshot) void {
    if (prev.rows != next.rows or prev.cols != next.cols) {
        renderFullFrame(next);
        return;
    }

    var style_state = StyleState{};
    style_state.reset();

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

            renderChangedRun(row_idx, run_start, col, next_line, &style_state);
        }

        const prev_end = lineVisibleEnd(prev_line);
        const next_end = lineVisibleEnd(next_line);
        if (prev_end > next_end or next_line.eol != prev_line.eol) {
            moveCursor(@intCast(row_idx), @intCast(next_end));
            eraseToEndOfLine();
        }
    }
}

fn freeLastFrame() void {
    if (last_frame) |*snap| {
        host.freeScreenSnapshot(std.heap.page_allocator, snap);
        last_frame = null;
    }
}

pub fn renderDamaged() void {
    needs_render = true;
}

pub fn doRender() void {
    if (!needs_render) return;
    needs_render = false;

    const session = global_session_host orelse return;
    const ts = session.terminal_state orelse return;

    var snapshot = ts.snapshot(std.heap.page_allocator) catch return;
    errdefer host.freeScreenSnapshot(std.heap.page_allocator, &snapshot);

    if (!global_output_state.has_drawn or last_frame == null) {
        if (snapshot.alt_screen != global_output_state.alt_screen or !global_output_state.has_drawn) {
            writeBytes(if (snapshot.alt_screen) "\x1b[?1049h" else "\x1b[?1049l");
            global_output_state.alt_screen = snapshot.alt_screen;
        }

        writeBytes("\x1b[?25l");
        renderFullFrame(&snapshot);
    } else {
        if (snapshot.alt_screen != global_output_state.alt_screen) {
            writeBytes(if (snapshot.alt_screen) "\x1b[?1049h" else "\x1b[?1049l");
            global_output_state.alt_screen = snapshot.alt_screen;
            writeBytes("\x1b[?25l");
            renderFullFrame(&snapshot);
        } else {
            writeBytes("\x1b[?25l");
            renderDiff(&(last_frame.?), &snapshot);
        }
    }

    moveCursor(snapshot.cursor_row, snapshot.cursor_col);

    if (snapshot.cursor_visible != global_output_state.cursor_visible) {
        writeBytes(if (snapshot.cursor_visible) "\x1b[?25h" else "\x1b[?25l");
        global_output_state.cursor_visible = snapshot.cursor_visible;
    } else if (snapshot.cursor_visible) {
        writeBytes("\x1b[?25h");
    }

    global_output_state.cursor_row = snapshot.cursor_row;
    global_output_state.cursor_col = snapshot.cursor_col;
    global_output_state.has_drawn = true;

    freeLastFrame();
    last_frame = snapshot;

}

pub fn setGlobalSessionHost(h: *host.SessionHost) void {
    global_session_host = h;
}

pub fn reset() void {
    freeLastFrame();
    global_output_state = .{};
    needs_render = true;
}

pub fn shutdown() void {
    if (global_output_state.alt_screen) {
        writeBytes("\x1b[?1049l");
    }
    writeBytes("\x1b[?25h");
    resetStyle();
    writeBytes("\x1b(B");
    freeLastFrame();
    global_output_state = .{};
    needs_render = false;
}

fn restoreTerminalStateForFutureOutput() void {
    resetStyle();
    writeBytes("\x1b(B");
}
