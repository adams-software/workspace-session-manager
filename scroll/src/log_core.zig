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
                if (self.pending_styled_hyperlinks.len == 0) {
                    self.pending_styled_hyperlinks = try self.cloneHyperlinks(snapshot);
                }
                try self.pending_styled_cells.appendSlice(self.allocator, line.cells);
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
    last_live_tail: std.ArrayList(u8) = .{},
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
        self.last_live_tail.deinit(self.allocator);
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
        const had_committed = self.builder.out.items.len != 0;
        if (had_committed) {
            if (self.last_live_tail.items.len > 0 and !std.mem.endsWith(u8, self.last_live_tail.items, "\n")) {
                try writer.writeAll("\n");
            }
            try self.builder.drainTo(writer);
            self.last_live_tail.clearRetainingCapacity();
            return;
        }

        const tail = try renderVisibleTail(self.allocator, self.builder.format, &self.engine);
        defer self.allocator.free(tail);

        if (tail.len == 0) {
            self.last_live_tail.clearRetainingCapacity();
            return;
        }
        if (std.mem.eql(u8, tail, self.last_live_tail.items)) return;

        var bytes_to_append = tail;
        if (self.last_live_tail.items.len > 0) {
            if (tail.len > self.last_live_tail.items.len and std.mem.startsWith(u8, tail, self.last_live_tail.items)) {
                bytes_to_append = tail[self.last_live_tail.items.len..];
            } else if (tail.len < self.last_live_tail.items.len and std.mem.startsWith(u8, self.last_live_tail.items, tail)) {
                self.last_live_tail.clearRetainingCapacity();
                try self.last_live_tail.appendSlice(self.allocator, tail);
                return;
            } else if (!std.mem.endsWith(u8, self.last_live_tail.items, "\n")) {
                try writer.writeAll("\n");
            }
        }

        if (bytes_to_append.len > 0) try writer.writeAll(bytes_to_append);

        self.last_live_tail.clearRetainingCapacity();
        try self.last_live_tail.appendSlice(self.allocator, tail);
    }

    pub fn finish(self: *StreamLogger, writer: anytype) !void {
        const had_committed = self.builder.out.items.len != 0;
        if (had_committed) {
            if (self.last_live_tail.items.len > 0 and !std.mem.endsWith(u8, self.last_live_tail.items, "\n")) {
                try writer.writeAll("\n");
            }
            try self.builder.drainTo(writer);
            self.last_live_tail.clearRetainingCapacity();
        }

        // In the live logger path, flushLive already materialized the latest
        // visible tail. Avoid appending the same tail again on graceful exit.
        if (self.last_live_tail.items.len > 0) return;

        const tail = try renderVisibleTail(self.allocator, self.builder.format, &self.engine);
        defer self.allocator.free(tail);
        if (tail.len == 0 or std.mem.eql(u8, tail, self.last_live_tail.items)) return;

        if (self.last_live_tail.items.len > 0 and !std.mem.endsWith(u8, self.last_live_tail.items, "\n")) {
            try writer.writeAll("\n");
        }
        try writer.writeAll(tail);

        self.last_live_tail.clearRetainingCapacity();
        try self.last_live_tail.appendSlice(self.allocator, tail);
    }
};

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

    try std.testing.expectEqualStrings("prompt> ", out.items);
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

    try std.testing.expectEqualStrings("prompt> ", out.items);
}

test "stream logger flushLive appends prompt growth as suffix" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("prompt> ");
    try logger.flushLive(out.writer(allocator));
    try logger.feed("x");
    try logger.flushLive(out.writer(allocator));

    try std.testing.expectEqualStrings("prompt> x", out.items);
}

test "stream logger finish does not duplicate previously flushed live tail" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("prompt> ");
    try logger.flushLive(out.writer(allocator));
    try logger.finish(out.writer(allocator));

    try std.testing.expectEqualStrings("prompt> ", out.items);
}

test "stream logger flushLive includes committed line plus prompt tail" {
    const allocator = std.testing.allocator;
    var logger = try StreamLogger.init(allocator, .plain, 24, 80);
    defer logger.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try logger.feed("hello\r\nprompt> ");
    try logger.flushLive(out.writer(allocator));

    try std.testing.expectEqualStrings("hello\nprompt> ", out.items);
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

    try std.testing.expectEqualStrings("$ nvim foo.txt\n$ echo done\ndone\n$ ", out.items);
}
