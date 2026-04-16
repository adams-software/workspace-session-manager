const std = @import("std");
const term_engine = @import("term_engine");
const getTtySize = @import("ptyio_tty_size").getTtySize;

const max_input_bytes = 64 * 1024 * 1024;
const replay_chunk_size = 16 * 1024;

const OutputFormat = enum {
    plain,
    ansi,
};

const StyledLine = struct {
    cells: []term_engine.HostScreenCell,
    hyperlinks: []term_engine.HostHyperlink,
};

const Record = union(enum) {
    text_line: []u8,
    styled_line: StyledLine,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    format: OutputFormat,
    records: std.ArrayList(Record),
    in_alt: bool = false,

    fn init(allocator: std.mem.Allocator, format: OutputFormat) Builder {
        return .{
            .allocator = allocator,
            .format = format,
            .records = .{},
            .in_alt = false,
        };
    }

    fn deinit(self: *Builder) void {
        for (self.records.items) |rec| switch (rec) {
            .text_line => |line| self.allocator.free(line),
            .styled_line => |line| {
                self.allocator.free(line.cells);
                for (line.hyperlinks) |link| {
                    self.allocator.free(link.params);
                    self.allocator.free(link.uri);
                }
                self.allocator.free(line.hyperlinks);
            },
        };
        self.records.deinit(self.allocator);
    }

    fn cloneHyperlinks(self: *Builder, snapshot: ?*const term_engine.HostScreenSnapshot) ![]term_engine.HostHyperlink {
        const src = if (snapshot) |snap| snap.hyperlinks else &.{};
        var links = try self.allocator.alloc(term_engine.HostHyperlink, src.len);
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

    fn appendLineFromCells(self: *Builder, snapshot: ?*const term_engine.HostScreenSnapshot, cells: []const term_engine.HostScreenCell) !void {
        switch (self.format) {
            .plain => {
                const line = try cellSliceToUtf8(self.allocator, cells);
                try self.records.append(self.allocator, .{ .text_line = line });
            },
            .ansi => {
                const line = try self.allocator.dupe(term_engine.HostScreenCell, cells);
                errdefer self.allocator.free(line);
                const hyperlinks = try self.cloneHyperlinks(snapshot);
                try self.records.append(self.allocator, .{ .styled_line = .{ .cells = line, .hyperlinks = hyperlinks } });
            },
        }
    }

    fn processEvents(self: *Builder, events: []term_engine.HistoryEvent) !void {
        for (events) |ev| {
            switch (ev) {
                .line_committed => |lc| {
                    if (self.in_alt) continue;
                    try self.appendLineFromCells(null, lc.line.cells);
                },
                .alternate_enter => self.in_alt = true,
                .alternate_exit => self.in_alt = false,
                .resize => {},
            }
        }
    }

    fn appendVisibleTail(self: *Builder, engine: *term_engine.Engine) !void {
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

                while (tail_lines.items.len > 0 and tail_lines.items[tail_lines.items.len - 1].len == 0) {
                    self.allocator.free(tail_lines.pop().?);
                }

                for (tail_lines.items) |line| {
                    try self.records.append(self.allocator, .{ .text_line = try self.allocator.dupe(u8, line) });
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
                    try self.appendLineFromCells(&snapshot, line.cells);
                }
            },
        }
    }

    fn writeTo(self: *Builder, writer: anytype) !void {
        var style_state = StyleState{};
        for (self.records.items) |rec| {
            switch (rec) {
                .text_line => |line| try writer.print("{s}\n", .{line}),
                .styled_line => |line| {
                    try style_state.renderLine(writer, line.cells, line.hyperlinks);
                    try writer.writeAll("\x1b[0m\n");
                    style_state = .{};
                },
            }
        }
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

fn usage() void {
    std.debug.print(
        "NAME\n  scroll - transcript to normalized text buffer\n\nUSAGE\n  scroll [--ansi] [typescript-file]\n",
        .{},
    );
}

fn isValidUnicodeScalar(cp: u32) bool {
    if (cp > std.math.maxInt(u21)) return false;
    if (cp >= 0xD800 and cp <= 0xDFFF) return false;
    return true;
}

fn encodeCell(buf: *[32]u8, cell: term_engine.HostScreenCell) []const u8 {
    var len: usize = 0;
    var i: usize = 0;

    while (i < cell.chars_len and i < cell.chars.len) : (i += 1) {
        const cp = cell.chars[i];
        if (cp == 0) break;
        if (!isValidUnicodeScalar(cp)) continue;

        const scalar: u21 = @intCast(cp);
        const written = std.unicode.utf8Encode(scalar, buf[len..]) catch continue;
        len += written;
    }

    return buf[0..len];
}

fn cellSliceToUtf8(allocator: std.mem.Allocator, cells: []const term_engine.HostScreenCell) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var last_non_space: usize = 0;
    var col: usize = 0;
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
            try out.append(allocator, ' ');
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

fn replayReader(allocator: std.mem.Allocator, format: OutputFormat, rows: u16, cols: u16, reader: anytype, writer: anytype) !void {
    var engine = try term_engine.Engine.init(allocator, rows, cols);
    defer engine.deinit();

    var builder = Builder.init(allocator, format);
    defer builder.deinit();

    var buf: [replay_chunk_size]u8 = undefined;
    var total_bytes: usize = 0;

    while (true) {
        const n = try reader.readSliceShort(&buf);
        if (n == 0) break;
        total_bytes += n;
        if (total_bytes > max_input_bytes) return error.InputTooLarge;
        try engine.feed(buf[0..n]);
        try processPendingEvents(allocator, &engine, &builder);
    }

    try builder.appendVisibleTail(&engine);
    try builder.writeTo(writer);
}

fn defaultTerminalSize() struct { rows: u16, cols: u16 } {
    const stderr_fd = std.posix.STDERR_FILENO;
    const size = getTtySize(stderr_fd) catch return .{ .rows = 24, .cols = 80 };
    if (size.rows == 0 or size.cols == 0) return .{ .rows = 24, .cols = 80 };
    return .{ .rows = size.rows, .cols = size.cols };
}

pub fn main() !u8 {
    const allocator = std.heap.smp_allocator;
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var format: OutputFormat = .plain;
    var path_arg: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--ansi")) {
            format = .ansi;
        } else if (path_arg == null) {
            path_arg = arg;
        } else {
            usage();
            return 1;
        }
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const size = defaultTerminalSize();

    if (path_arg) |path| {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var file_buf: [4096]u8 = undefined;
        var file_reader = file.reader(&file_buf);
        try replayReader(allocator, format, size.rows, size.cols, &file_reader.interface, &stdout_writer.interface);
    } else {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
        try replayReader(allocator, format, size.rows, size.cols, &stdin_reader.interface, &stdout_writer.interface);
    }

    try stdout_writer.interface.flush();
    return 0;
}

test "scroll suppresses alternate screen and keeps surrounding shell lines" {
    const allocator = std.testing.allocator;
    const transcript = "$ echo hi\r\nhi\r\n$ nvim foo.txt\r\n\x1b[?1049h[editor noise]\x1b[?1049l$ echo done\r\ndone\r\n";

    var stream = std.io.fixedBufferStream(transcript);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try replayReader(allocator, .plain, 24, 80, stream.reader(), out.writer(allocator));

    try std.testing.expectEqualStrings(
        "$ echo hi\nhi\n$ nvim foo.txt\n$ echo done\ndone\n",
        out.items,
    );
}

test "scroll preserves blank lines" {
    const allocator = std.testing.allocator;
    const transcript = "$ printf 'a\\n\\n b\\n'\r\na\r\n\r\n b\r\n";

    var stream = std.io.fixedBufferStream(transcript);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try replayReader(allocator, .plain, 24, 80, stream.reader(), out.writer(allocator));

    try std.testing.expectEqualStrings(
        "$ printf 'a\\n\\n b\\n'\na\n\n b\n",
        out.items,
    );
}

test "scroll keeps emoji variation selector cluster without trailing placeholder" {
    const allocator = std.testing.allocator;
    const transcript = "\xe2\xad\x95\xef\xb8\x8f!\r\n";

    var stream = std.io.fixedBufferStream(transcript);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try replayReader(allocator, .plain, 24, 80, stream.reader(), out.writer(allocator));

    try std.testing.expectEqualStrings("⭕️!\n", out.items);
}

test "scroll ansi mode preserves simple sgr styling" {
    const allocator = std.testing.allocator;
    const transcript = "\x1b[31mred\x1b[0m\r\n";

    var stream = std.io.fixedBufferStream(transcript);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try replayReader(allocator, .ansi, 24, 80, stream.reader(), out.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[") != null);
}

test "scroll ansi mode preserves osc8 hyperlinks" {
    const allocator = std.testing.allocator;
    const transcript = "\x1b]8;;https://example.com\x1b\\hi\x1b]8;;\x1b\\\r\n";

    var stream = std.io.fixedBufferStream(transcript);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try replayReader(allocator, .ansi, 24, 80, stream.reader(), out.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;;https://example.com\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "hi") != null);
}
