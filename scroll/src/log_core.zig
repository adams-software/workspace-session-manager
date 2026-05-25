const std = @import("std");
const term_engine = @import("term_engine");

pub const max_input_bytes = 64 * 1024 * 1024;
pub const replay_chunk_size = 16 * 1024;
const normalize_lf_for_replay = true;

pub const OutputFormat = enum {
    plain,
    ansi,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    format: OutputFormat,
    in_alt: bool = false,
    pending_plain: std.ArrayList(u8) = .{},
    pending_styled_cells: std.ArrayList(term_engine.HostScreenCell) = .{},
    pending_styled_hyperlinks: []term_engine.HostHyperlink = &.{},
    out: std.ArrayList(u8) = .{},

    pub fn init(allocator: std.mem.Allocator, format: OutputFormat) Builder {
        return .{
            .allocator = allocator,
            .format = format,
            .in_alt = false,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.out.deinit(self.allocator);
        self.pending_plain.deinit(self.allocator);
        self.pending_styled_cells.deinit(self.allocator);
        if (self.pending_styled_hyperlinks.len > 0) {
            for (self.pending_styled_hyperlinks) |link| {
                self.allocator.free(link.params);
                self.allocator.free(link.uri);
            }
            self.allocator.free(self.pending_styled_hyperlinks);
        }
    }

    fn flushPending(self: *Builder) !void {
        switch (self.format) {
            .plain => {
                if (self.pending_plain.items.len == 0) return;
                try self.out.appendSlice(self.allocator, self.pending_plain.items);
                try self.out.append(self.allocator, '\n');
                self.pending_plain.clearRetainingCapacity();
            },
            .ansi => {
                if (self.pending_styled_cells.items.len == 0) return;
                var style_state = StyleState{};
                var buf = std.ArrayList(u8){};
                defer buf.deinit(self.allocator);
                try style_state.renderLine(buf.writer(self.allocator), self.pending_styled_cells.items, self.pending_styled_hyperlinks);
                try buf.appendSlice(self.allocator, "\x1b[0m\n");
                try self.out.appendSlice(self.allocator, buf.items);
                self.pending_styled_cells.clearRetainingCapacity();
                for (self.pending_styled_hyperlinks) |link| {
                    self.allocator.free(link.params);
                    self.allocator.free(link.uri);
                }
                if (self.pending_styled_hyperlinks.len > 0) self.allocator.free(self.pending_styled_hyperlinks);
                self.pending_styled_hyperlinks = &.{};
            },
        }
    }

    fn cloneHyperlinks(self: *Builder, snapshot: ?*const term_engine.HostScreenSnapshot) ![]term_engine.HostHyperlink {
        const src = if (snapshot) |snap| snap.hyperlinks else &.{};
        const links = try self.allocator.alloc(term_engine.HostHyperlink, src.len);
        errdefer {
            for (links[0..src.len]) |link| {
                if (link.params.len > 0) self.allocator.free(link.params);
                if (link.uri.len > 0) self.allocator.free(link.uri);
            }
            self.allocator.free(links);
        }
        for (src, 0..) |link, idx| {
            links[idx] = .{
                .params = try self.allocator.dupe(u8, link.params),
                .uri = try self.allocator.dupe(u8, link.uri),
            };
        }
        return links;
    }

    fn appendLineFromCells(self: *Builder, snapshot: ?*const term_engine.HostScreenSnapshot, line: term_engine.HostScreenLine) !void {
        switch (self.format) {
            .plain => {
                const text = try cellSliceToUtf8(self.allocator, line.cells);
                defer self.allocator.free(text);
                try self.pending_plain.appendSlice(self.allocator, text);
                if (line.eol) try self.flushPending();
            },
            .ansi => {
                const cells = trimTrailingBlankCells(line.cells);
                if (self.pending_styled_hyperlinks.len == 0) {
                    self.pending_styled_hyperlinks = try self.cloneHyperlinks(snapshot);
                }
                try self.pending_styled_cells.appendSlice(self.allocator, cells);
                if (line.eol) try self.flushPending();
            },
        }
    }

    pub fn processEvents(self: *Builder, events: []term_engine.HistoryEvent) !void {
        for (events) |ev| {
            switch (ev) {
                .line_committed => |lc| {
                    if (self.in_alt) continue;
                    try self.appendLineFromCells(null, lc.line);
                },
                .alternate_enter => self.in_alt = true,
                .alternate_exit => self.in_alt = false,
                .resize => {},
            }
        }
    }

    pub fn appendVisibleTail(self: *Builder, engine: *term_engine.Engine) !void {
        var snapshot = try engine.snapshot(self.allocator);
        defer term_engine.freeScreenSnapshot(self.allocator, &snapshot);

        if (snapshot.alt_screen) return;

        switch (self.format) {
            .plain => {
                var tail_lines = std.ArrayList([]u8){};
                defer {
                    for (tail_lines.items) |line| self.allocator.free(line);
                    tail_lines.deinit(self.allocator);
                }

                for (snapshot.lines) |line| {
                    const text = try cellSliceToUtf8(self.allocator, line.cells);
                    try tail_lines.append(self.allocator, text);
                }

                while (tail_lines.items.len > 0 and tail_lines.items[tail_lines.items.len - 1].len == 0) self.allocator.free(tail_lines.pop().?);

                for (tail_lines.items) |line| {
                    try self.out.appendSlice(self.allocator, line);
                    try self.out.append(self.allocator, '\n');
                }
            },
            .ansi => {
                var end: usize = snapshot.lines.len;
                while (end > 0) {
                    const text = try cellSliceToUtf8(self.allocator, snapshot.lines[end - 1].cells);
                    defer self.allocator.free(text);
                    if (text.len != 0) break;
                    end -= 1;
                }

                for (snapshot.lines[0..end]) |line| {
                    try self.appendLineFromCells(&snapshot, line);
                }
            },
        }
    }

    pub fn drainTo(self: *Builder, writer: anytype) !void {
        try self.flushPending();
        if (self.out.items.len == 0) return;
        try writer.writeAll(self.out.items);
        self.out.clearRetainingCapacity();
    }
};

const StyleState = struct {
    fg: term_engine.HostColor = .{},
    bg: term_engine.HostColor = .{},
    attrs: term_engine.HostCellAttrs = .{},
    active_hyperlink: u32 = 0,

    fn emitBool(writer: anytype, on_code: []const u8, off_code: []const u8, current: *bool, target: bool) !void {
        if (current.* == target) return;
        try writer.writeAll(if (target) on_code else off_code);
        current.* = target;
    }

    fn colorEq(a: term_engine.HostColor, b: term_engine.HostColor) bool {
        return a.kind == b.kind and
            a.palette_index == b.palette_index and
            a.red == b.red and
            a.green == b.green and
            a.blue == b.blue;
    }

    fn emitColor(writer: anytype, base: u8, color: term_engine.HostColor) !void {
        switch (color.kind) {
            .default => try writer.print("\x1b[{d}m", .{base + 1}),
            .indexed => try writer.print("\x1b[{d};5;{d}m", .{ base, color.palette_index }),
            .rgb => try writer.print("\x1b[{d};2;{d};{d};{d}m", .{ base, color.red, color.green, color.blue }),
        }
    }

    fn diffAndEmit(self: *StyleState, writer: anytype, cell: term_engine.HostScreenCell) !void {
        try emitBool(writer, "\x1b[1m", "\x1b[22m", &self.attrs.bold, cell.attrs.bold);
        try emitBool(writer, "\x1b[3m", "\x1b[23m", &self.attrs.italic, cell.attrs.italic);
        try emitBool(writer, "\x1b[4m", "\x1b[24m", &self.attrs.underline, cell.attrs.underline);
        try emitBool(writer, "\x1b[5m", "\x1b[25m", &self.attrs.blink, cell.attrs.blink);
        try emitBool(writer, "\x1b[7m", "\x1b[27m", &self.attrs.reverse, cell.attrs.reverse);
        try emitBool(writer, "\x1b[8m", "\x1b[28m", &self.attrs.conceal, cell.attrs.conceal);
        try emitBool(writer, "\x1b[9m", "\x1b[29m", &self.attrs.strike, cell.attrs.strike);

        if (!colorEq(self.fg, cell.fg)) {
            try emitColor(writer, 38, cell.fg);
            self.fg = cell.fg;
        }
        if (!colorEq(self.bg, cell.bg)) {
            try emitColor(writer, 48, cell.bg);
            self.bg = cell.bg;
        }
    }

    fn emitHyperlinkTransition(self: *StyleState, writer: anytype, hyperlinks: []const term_engine.HostHyperlink, target: u32) !void {
        if (self.active_hyperlink == target) return;

        if (self.active_hyperlink != 0) {
            try writer.writeAll("\x1b]8;;\x1b\\");
        }

        if (target != 0 and target <= hyperlinks.len) {
            const link = hyperlinks[target - 1];
            try writer.writeAll("\x1b]8;");
            try writer.writeAll(link.params);
            try writer.writeAll(";");
            try writer.writeAll(link.uri);
            try writer.writeAll("\x1b\\");
            self.active_hyperlink = target;
            return;
        }

        self.active_hyperlink = 0;
    }

    fn renderLine(self: *StyleState, writer: anytype, cells: []const term_engine.HostScreenCell, hyperlinks: []const term_engine.HostHyperlink) !void {
        var col: usize = 0;
        while (col < cells.len) {
            const cell = cells[col];
            if (cell.width == 0) {
                col += 1;
                continue;
            }
            try self.emitHyperlinkTransition(writer, hyperlinks, cell.hyperlink);
            try self.diffAndEmit(writer, cell);

            var buf: [32]u8 = undefined;
            const encoded = encodeCell(&buf, cell);
            if (encoded.len == 0) {
                if (cell.width == 1) try writer.writeAll(" ");
            } else {
                try writer.writeAll(encoded);
            }

            col += @max(@as(usize, 1), @as(usize, cell.width));
        }

        try self.emitHyperlinkTransition(writer, hyperlinks, 0);
    }
};

pub const StreamLogger = struct {
    allocator: std.mem.Allocator,
    engine: term_engine.Engine,
    builder: Builder,
    live_tail: std.ArrayList(u8) = .{},
    live_emitted_prefix: std.ArrayList(u8) = .{},
    emitted_tail_lines: usize = 0,
    prev_byte: ?u8 = null,

    pub fn init(allocator: std.mem.Allocator, format: OutputFormat, rows: u16, cols: u16) !StreamLogger {
        return .{
            .allocator = allocator,
            .engine = try term_engine.Engine.init(allocator, rows, cols),
            .builder = Builder.init(allocator, format),
            .prev_byte = null,
        };
    }

    pub fn deinit(self: *StreamLogger) void {
        self.live_tail.deinit(self.allocator);
        self.live_emitted_prefix.deinit(self.allocator);
        self.builder.deinit();
        self.engine.deinit();
    }

    pub fn feed(self: *StreamLogger, bytes: []const u8) !void {
        try feedReplayBytes(&self.engine, bytes, &self.prev_byte);
        try processPendingEvents(self.allocator, &self.engine, &self.builder);
    }

    pub fn resize(self: *StreamLogger, rows: u16, cols: u16) !void {
        try self.engine.resize(rows, cols);
        try processPendingEvents(self.allocator, &self.engine, &self.builder);
    }

    pub fn flush(self: *StreamLogger, writer: anytype) !void {
        try self.builder.drainTo(writer);
    }

    pub fn flushLive(self: *StreamLogger, writer: anytype) !void {
        try self.flushCommitted(writer);

        const tail = try renderVisibleTail(self.allocator, self.builder.format, &self.engine);
        defer self.allocator.free(tail);
        try self.promoteStableTailLines(writer, tail);
    }

    pub fn finish(self: *StreamLogger, writer: anytype) !void {
        try self.flushCommitted(writer);

        const tail = try renderVisibleTail(self.allocator, self.builder.format, &self.engine);
        defer self.allocator.free(tail);
        try self.promoteStableTailLines(writer, tail);
        try self.flushRemainingTail(writer, tail);
    }

    fn takeCommittedBytes(self: *StreamLogger) ![]u8 {
        var out = std.ArrayList(u8){};
        defer out.deinit(self.allocator);
        try self.builder.drainTo(out.writer(self.allocator));
        return try out.toOwnedSlice(self.allocator);
    }

    pub fn hasLiveTail(self: *const StreamLogger) bool {
        return self.live_tail.items.len != 0;
    }

    pub fn hasPendingCommitted(self: *const StreamLogger) bool {
        return self.builder.out.items.len != 0;
    }

    fn flushCommitted(self: *StreamLogger, writer: anytype) !void {
        if (self.builder.out.items.len == 0) return;

        const committed = try self.takeCommittedBytes();
        defer self.allocator.free(committed);
        const bytes_to_append = self.consumeLivePrefix(committed);
        if (bytes_to_append.len > 0) try writer.writeAll(bytes_to_append);
    }

    fn promoteStableTailLines(self: *StreamLogger, writer: anytype, tail: []const u8) !void {
        if (tail.len == 0) {
            self.live_tail.clearRetainingCapacity();
            self.emitted_tail_lines = 0;
            return;
        }

        const common = commonLinePrefixText(self.live_tail.items, tail);
        self.emitted_tail_lines = @min(self.emitted_tail_lines, common);

        const next_line_count = countLines(tail);
        const stable_count = if (next_line_count == 0) 0 else next_line_count - 1;
        if (stable_count > self.emitted_tail_lines) {
            const start = lineStartOffset(tail, self.emitted_tail_lines);
            const end = lineStartOffset(tail, stable_count);
            const promoted = tail[start..end];
            if (promoted.len > 0) {
                try writer.writeAll(promoted);
                try self.live_emitted_prefix.appendSlice(self.allocator, promoted);
            }
            self.emitted_tail_lines = stable_count;
        }

        self.live_tail.clearRetainingCapacity();
        try self.live_tail.appendSlice(self.allocator, tail);
    }

    fn flushRemainingTail(self: *StreamLogger, writer: anytype, tail: []const u8) !void {
        if (tail.len == 0) return;
        const tail_line_count = countLines(tail);
        if (self.emitted_tail_lines >= tail_line_count) return;

        const start = lineStartOffset(tail, self.emitted_tail_lines);
        const remaining = tail[start..];
        if (remaining.len > 0) try writer.writeAll(remaining);

        self.live_tail.clearRetainingCapacity();
        self.live_emitted_prefix.clearRetainingCapacity();
        self.emitted_tail_lines = 0;
    }

    fn consumeLivePrefix(self: *StreamLogger, committed: []const u8) []const u8 {
        if (self.live_emitted_prefix.items.len == 0) return committed;

        const live_prefix = comparableTailPrefix(self.live_emitted_prefix.items);
        if (committed.len >= live_prefix.len and std.mem.startsWith(u8, committed, live_prefix)) {
            self.live_emitted_prefix.clearRetainingCapacity();
            return committed[live_prefix.len..];
        }

        self.live_emitted_prefix.clearRetainingCapacity();
        return committed;
    }
};

fn comparableTailPrefix(tail: []const u8) []const u8 {
    if (std.mem.endsWith(u8, tail, "\x1b[0m")) {
        return tail[0 .. tail.len - 4];
    }
    return tail;
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    return std.mem.count(u8, text, "\n") + 1;
}

fn commonLinePrefixText(a: []const u8, b: []const u8) usize {
    var a_it = std.mem.splitScalar(u8, a, '\n');
    var b_it = std.mem.splitScalar(u8, b, '\n');
    var count: usize = 0;
    while (true) {
        const a_line = a_it.next() orelse break;
        const b_line = b_it.next() orelse break;
        if (!std.mem.eql(u8, a_line, b_line)) break;
        count += 1;
    }
    return count;
}

fn lineStartOffset(text: []const u8, count: usize) usize {
    if (count == 0 or text.len == 0) return 0;
    var offset: usize = 0;
    var lines_seen: usize = 0;
    while (offset < text.len and lines_seen < count) : (offset += 1) {
        if (text[offset] == '\n') lines_seen += 1;
    }
    return offset;
}

pub fn replayReader(allocator: std.mem.Allocator, format: OutputFormat, rows: u16, cols: u16, reader: anytype, writer: anytype) !void {
    var logger = try StreamLogger.init(allocator, format, rows, cols);
    defer logger.deinit();

    var buf: [replay_chunk_size]u8 = undefined;
    var total_bytes: usize = 0;

    while (true) {
        const n = try reader.readSliceShort(&buf);
        if (n == 0) break;
        total_bytes += n;
        if (total_bytes > max_input_bytes) return error.InputTooLarge;
        try logger.feed(buf[0..n]);
        try logger.flush(writer);
    }

    try logger.finish(writer);
}

fn processPendingEvents(allocator: std.mem.Allocator, engine: *term_engine.Engine, builder: *Builder) !void {
    const events = try engine.takeEvents(allocator);
    defer {
        for (events) |ev| switch (ev) {
            .line_committed => |lc| allocator.free(lc.line.cells),
            else => {},
        };
        allocator.free(events);
    }
    try builder.processEvents(events);
}

fn renderVisibleTail(allocator: std.mem.Allocator, format: OutputFormat, engine: *term_engine.Engine) ![]u8 {
    var builder = Builder.init(allocator, format);
    defer builder.deinit();
    try builder.appendVisibleTail(engine);

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try builder.drainTo(out.writer(allocator));
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        out.items.len -= 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn feedReplayBytes(engine: *term_engine.Engine, bytes: []const u8, prev_byte: *?u8) !void {
    if (!normalize_lf_for_replay) return engine.feed(bytes);

    var normalized = std.ArrayList(u8){};
    defer normalized.deinit(std.heap.smp_allocator);

    for (bytes) |b| {
        if (b == '\n' and prev_byte.* != '\r') {
            try normalized.append(std.heap.smp_allocator, '\r');
        }
        try normalized.append(std.heap.smp_allocator, b);
        prev_byte.* = b;
    }

    try engine.feed(normalized.items);
}

fn encodeCell(buf: *[32]u8, cell: term_engine.HostScreenCell) []const u8 {
    if (cell.chars_len == 0) return "";

    var written: usize = 0;
    var i: usize = 0;
    while (i < cell.chars_len and i < cell.chars.len) : (i += 1) {
        const cp = cell.chars[i];
        if (cp == 0) break;
        const len = std.unicode.utf8Encode(@intCast(cp), buf[written..]) catch break;
        written += len;
    }

    return buf[0..written];
}

fn isBlankCell(cell: term_engine.HostScreenCell) bool {
    if (cell.width == 0) return true;
    if (cell.chars_len == 0) return true;
    if (cell.chars_len == 1 and cell.chars[0] == ' ') return true;
    return false;
}

fn trimTrailingBlankCells(cells: []const term_engine.HostScreenCell) []const term_engine.HostScreenCell {
    var end = cells.len;
    while (end > 0) {
        const cell = cells[end - 1];
        if (!isBlankCell(cell)) break;
        end -= 1;
    }
    return cells[0..end];
}

fn cellSliceToUtf8(allocator: std.mem.Allocator, cells: []const term_engine.HostScreenCell) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var col: usize = 0;
    var last_non_space: usize = 0;
    while (col < cells.len) {
        const cell = cells[col];
        if (cell.width == 0) {
            col += 1;
            continue;
        }

        const before_len = out.items.len;
        var buf: [32]u8 = undefined;
        const encoded = encodeCell(&buf, cell);
        if (encoded.len == 0) {
            if (cell.width == 1) try out.append(allocator, ' ');
        } else {
            try out.appendSlice(allocator, encoded);
        }

        var only_spaces = true;
        var idx = before_len;
        while (idx < out.items.len) : (idx += 1) {
            if (out.items[idx] != ' ') {
                only_spaces = false;
                break;
            }
        }
        if (!only_spaces) last_non_space = out.items.len;

        col += @max(@as(usize, 1), @as(usize, cell.width));
    }

    if (last_non_space < out.items.len) {
        out.shrinkRetainingCapacity(last_non_space);
    }

    return out.toOwnedSlice(allocator);
}

test "stream logger flushLive emits visible tail without committed newline" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    try logger.feed("prompt> ");

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try logger.flushLive(out.writer(allocator));

    try std.testing.expectEqualStrings("", out.items);
}

test "stream logger flushLive dedupes unchanged visible tail" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    try logger.feed("prompt> ");

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try logger.flushLive(out.writer(allocator));
    try logger.flushLive(out.writer(allocator));

    try std.testing.expectEqualStrings("", out.items);
}

test "stream logger flushLive suppresses prompt-growth snapshots until commit" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("prompt> ");
    try logger.flushLive(out.writer(allocator));
    try logger.feed("x");
    try logger.flushLive(out.writer(allocator));

    try std.testing.expectEqualStrings("", out.items);
}

test "stream logger finish does not duplicate previously flushed live tail" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("hello\r\nprompt> ");
    try logger.flushLive(out.writer(allocator));
    try logger.finish(out.writer(allocator));

    try std.testing.expectEqualStrings("hello\nprompt>", out.items);
}

test "stream logger flushLive includes committed line plus prompt tail" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("hello\r\nprompt> ");
    try logger.flushLive(out.writer(allocator));

    try std.testing.expectEqualStrings("hello\n", out.items);
}

test "stream logger flushLive does not duplicate committed prompt line after live growth" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("prompt> ls");
    try logger.flushLive(out.writer(allocator));
    try logger.feed("\r\nfile.txt\r\nprompt> ");
    try logger.flushLive(out.writer(allocator));

    try std.testing.expectEqualStrings("prompt> ls\nfile.txt\n", out.items);
}

test "stream logger flushLive suppresses alt-screen body and resumes shell tail" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("$ nvim foo.txt\r\n");
    try logger.feed("\x1b[?1049h[editor noise]");
    try logger.feed("\x1b[?1049l$ echo done\r\ndone\r\n$ ");
    try logger.flushLive(out.writer(allocator));

    try std.testing.expectEqualStrings("$ nvim foo.txt\n$ echo done\ndone\n", out.items);
}

test "stream logger finish flushes pending prompt tail after live stable lines" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("$ echo done\r\ndone\r\n$ ");
    try logger.flushLive(out.writer(allocator));
    try logger.finish(out.writer(allocator));

    try std.testing.expectEqualStrings("$ echo done\ndone\n$", out.items);
}

test "stream logger finish preserves no-newline output tail" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("partial output");
    try logger.flushLive(out.writer(allocator));
    try logger.finish(out.writer(allocator));

    try std.testing.expectEqualStrings("partial output", out.items);
}

test "stream logger suppresses line editing noise before command commit" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("prompt> lsx\x08 \x08");
    try logger.flushLive(out.writer(allocator));
    try logger.feed("\r\nfile.txt\r\nprompt> ");
    try logger.flushLive(out.writer(allocator));
    try logger.finish(out.writer(allocator));

    try std.testing.expectEqualStrings("prompt> ls\nfile.txt\nprompt>", out.items);
}

test "stream logger finish preserves prompt tail across resize" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 20);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("prompt> echo hi");
    try logger.flushLive(out.writer(allocator));
    try logger.resize(24, 40);
    try logger.finish(out.writer(allocator));

    try std.testing.expectEqualStrings("prompt> echo hi", out.items);
}

test "stream logger live flush keeps multiple committed lines but defers final prompt" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("$ printf one\r\none\r\n$ printf two\r\ntwo\r\n$ ");
    try logger.flushLive(out.writer(allocator));
    try std.testing.expectEqualStrings("$ printf one\none\n$ printf two\ntwo\n", out.items);

    try logger.finish(out.writer(allocator));
    try std.testing.expectEqualStrings("$ printf one\none\n$ printf two\ntwo\n$", out.items);
}
