const std = @import("std");
const ui_state = @import("ui_state.zig");
const policy = @import("policy.zig");
const unicode_text = @import("unicode_text.zig");

const screen_reset = "\x1b[0m\x1b[2J\x1b[H\x1b[?25l";

pub fn buildFrame(
    allocator: std.mem.Allocator,
    state: *const ui_state.State,
    model: policy.Provider.MenuModel,
    cols: u16,
    rows: u16,
) ![]u8 {
    var frame: std.ArrayList(u8) = .empty;
    errdefer frame.deinit(allocator);
    try frame.appendSlice(allocator, screen_reset);

    var row: usize = 0;
    var prompt_cursor: ?CursorPosition = null;
    try appendLine(&frame, allocator, "WSM", cols, rows, &row);

    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(allocator);
    try header.appendSlice(allocator, model.workspace);
    if (model.session.len > 0) {
        try header.appendSlice(allocator, " / ");
        try header.appendSlice(allocator, model.session);
    }
    try appendLine(&frame, allocator, header.items, cols, rows, &row);
    try appendLine(&frame, allocator, "", cols, rows, &row);

    switch (state.mode) {
        .passive => {},
        .active_menu => {
            try appendSessionBrowser(&frame, allocator, state, model, cols, rows, &row);
        },
        .prompt_attach => {
            prompt_cursor = try appendPromptLine(&frame, allocator, "attach> ", state.input(), state.inputCursor(), cols, rows, &row);
            try appendLine(&frame, allocator, "", cols, rows, &row);
            for (model.attach_candidates, 0..) |candidate, index| {
                var candidate_line: std.ArrayList(u8) = .empty;
                defer candidate_line.deinit(allocator);
                try candidate_line.appendSlice(allocator, if (state.selected_candidate == index) "> " else "  ");
                try candidate_line.appendSlice(allocator, candidate.label);
                try appendLine(&frame, allocator, candidate_line.items, cols, rows, &row);
            }
            try appendLine(&frame, allocator, "", cols, rows, &row);
            try appendLine(&frame, allocator, "enter attaches; tab/arrows select; esc goes back", cols, rows, &row);
        },
        .prompt_create => {
            prompt_cursor = try appendPromptLine(&frame, allocator, "create> ", state.input(), state.inputCursor(), cols, rows, &row);
            try appendLine(&frame, allocator, "", cols, rows, &row);
            try appendLine(&frame, allocator, "./ nests under selected; / and bare names use root", cols, rows, &row);
            try appendLine(&frame, allocator, "enter creates; esc goes back", cols, rows, &row);
        },
        .prompt_kill => {
            try appendLine(&frame, allocator, "Force kill the current session?", cols, rows, &row);
            try appendLine(&frame, allocator, "", cols, rows, &row);
            try appendLine(&frame, allocator, "enter confirms; esc cancels", cols, rows, &row);
        },
    }

    if (state.notice_kind != .none and state.notice().len > 0) {
        try appendLine(&frame, allocator, "", cols, rows, &row);
        var notice: std.ArrayList(u8) = .empty;
        defer notice.deinit(allocator);
        try notice.appendSlice(allocator, if (state.notice_kind == .err) "error: " else "info: ");
        try notice.appendSlice(allocator, state.notice());
        try appendLine(&frame, allocator, notice.items, cols, rows, &row);
    }

    if (prompt_cursor) |cursor| {
        const sequence = try std.fmt.allocPrint(allocator, "\x1b[{d};{d}H\x1b[?25h", .{ cursor.row, cursor.col });
        defer allocator.free(sequence);
        try frame.appendSlice(allocator, sequence);
    }

    return frame.toOwnedSlice(allocator);
}

const BrowserLine = struct {
    path: []const u8,
    name: []const u8,
    depth: usize,
    session_index: ?usize,
    has_children: bool,
};

fn appendSessionBrowser(
    frame: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    state: *const ui_state.State,
    model: policy.Provider.MenuModel,
    cols: u16,
    rows: u16,
    row: *usize,
) !void {
    try appendLine(frame, allocator, "Sessions", cols, rows, row);

    const lines = try buildBrowserLines(allocator, model.sessions);
    defer allocator.free(lines);
    if (lines.len == 0) {
        try appendLine(frame, allocator, "", cols, rows, row);
        try appendLine(frame, allocator, "  No live sessions", cols, rows, row);
    } else {
        const footer_rows: usize = 5;
        const remaining = @as(usize, rows) -| row.*;
        const visible_count = @min(lines.len, remaining -| @min(footer_rows, remaining));
        var start: usize = 0;
        if (visible_count > 0) {
            if (selectedDisplayIndex(lines, state.selected_session)) |selected| {
                if (selected >= visible_count) start = selected - visible_count + 1;
            }
        }

        for (lines[start..@min(lines.len, start + visible_count)]) |line| {
            var rendered: std.ArrayList(u8) = .empty;
            defer rendered.deinit(allocator);
            const selected = line.session_index != null and line.session_index == state.selected_session;
            try rendered.appendSlice(allocator, if (selected) "> " else "  ");
            for (0..line.depth) |_| try rendered.appendSlice(allocator, "  ");
            if (line.session_index != null) {
                const is_current = if (model.current_session) |current| std.mem.eql(u8, line.path, current) else false;
                try rendered.appendSlice(allocator, if (is_current) "● " else "○ ");
            } else {
                try rendered.appendSlice(allocator, "  ");
            }
            try rendered.appendSlice(allocator, line.name);
            if (line.has_children) try rendered.append(allocator, '/');
            try appendLine(frame, allocator, rendered.items, cols, rows, row);
        }
    }

    try appendLine(frame, allocator, "", cols, rows, row);
    try appendLine(frame, allocator, "up/down or j/k select; enter attaches", cols, rows, row);
    try appendLine(frame, allocator, "c  create   g  logs current", cols, rows, row);
    try appendLine(frame, allocator, "x  force kill current   d  detach", cols, rows, row);
    try appendLine(frame, allocator, "esc, ctrl-c, or ctrl-g returns", cols, rows, row);
}

fn buildBrowserLines(allocator: std.mem.Allocator, sessions: []const []const u8) ![]BrowserLine {
    var lines: std.ArrayList(BrowserLine) = .empty;
    errdefer lines.deinit(allocator);
    var emitted = std.StringHashMap(void).init(allocator);
    defer emitted.deinit();

    for (sessions, 0..) |session, session_index| {
        var slash = std.mem.indexOfScalar(u8, session, '/');
        while (slash) |end| {
            const directory = session[0..end];
            if (!emitted.contains(directory)) {
                try emitted.put(directory, {});
                try lines.append(allocator, .{
                    .path = directory,
                    .name = std.fs.path.basename(directory),
                    .depth = std.mem.count(u8, directory, "/"),
                    .session_index = null,
                    .has_children = true,
                });
            }
            const next_start = end + 1;
            slash = if (next_start < session.len)
                if (std.mem.indexOfScalar(u8, session[next_start..], '/')) |relative| next_start + relative else null
            else
                null;
        }

        if (!emitted.contains(session)) {
            try emitted.put(session, {});
            const has_children = if (session_index + 1 < sessions.len) blk: {
                const next = sessions[session_index + 1];
                break :blk next.len > session.len and next[session.len] == '/' and std.mem.startsWith(u8, next, session);
            } else false;
            try lines.append(allocator, .{
                .path = session,
                .name = std.fs.path.basename(session),
                .depth = std.mem.count(u8, session, "/"),
                .session_index = session_index,
                .has_children = has_children,
            });
        }
    }
    return lines.toOwnedSlice(allocator);
}

fn selectedDisplayIndex(lines: []const BrowserLine, selected_session: ?usize) ?usize {
    const selected = selected_session orelse return null;
    for (lines, 0..) |line, index| {
        if (line.session_index == selected) return index;
    }
    return null;
}

const CursorPosition = struct {
    row: usize,
    col: usize,
};

fn appendPromptLine(
    frame: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    label: []const u8,
    input: []const u8,
    input_cursor: usize,
    cols: u16,
    rows: u16,
    row: *usize,
) !?CursorPosition {
    if (row.* >= rows) return null;
    if (cols == 0) {
        try appendLine(frame, allocator, "", cols, rows, row);
        return null;
    }

    const visible_label = unicode_text.prefixForWidth(label, @as(usize, cols) - 1);
    const label_cells = unicode_text.displayWidth(visible_label);
    const input_cells = @as(usize, cols) - label_cells;
    const viewport = unicode_text.viewportAroundCursor(input, input_cursor, input_cells);

    try frame.appendSlice(allocator, visible_label);
    try frame.appendSlice(allocator, input[viewport.start..viewport.end]);
    const cursor = CursorPosition{
        .row = row.* + 1,
        .col = label_cells + viewport.cursor_cells + 1,
    };

    row.* += 1;
    if (row.* < rows) try frame.appendSlice(allocator, "\r\n");
    return cursor;
}

fn appendLine(frame: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8, cols: u16, rows: u16, row: *usize) !void {
    if (row.* >= rows) return;
    try frame.appendSlice(allocator, unicode_text.prefixForWidth(line, cols));
    row.* += 1;
    if (row.* < rows) try frame.appendSlice(allocator, "\r\n");
}

test "active menu renders a full-screen session browser" {
    var state = ui_state.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .active_menu;
    state.selected_session = 0;

    const frame = try buildFrame(std.testing.allocator, &state, .{
        .workspace = "/tmp/workspace",
        .session = "dev",
        .current_session = "dev",
        .sessions = &.{ "dev", "projects/api", "projects/web" },
        .attach_candidates = &.{},
    }, 80, 24);
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.startsWith(u8, frame, screen_reset));
    try std.testing.expect(std.mem.indexOf(u8, frame, "/tmp/workspace / dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "> ● dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "projects/") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "○ api") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "ctrl-g returns") != null);
}

test "browser merges a live session with its directory node" {
    const lines = try buildBrowserLines(std.testing.allocator, &.{ "projects", "projects/api", "tools/lint" });
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings("projects", lines[0].path);
    try std.testing.expectEqual(@as(?usize, 0), lines[0].session_index);
    try std.testing.expect(lines[0].has_children);
    try std.testing.expectEqualStrings("projects/api", lines[1].path);
    try std.testing.expectEqualStrings("tools", lines[2].path);
    try std.testing.expect(lines[2].session_index == null);
    try std.testing.expectEqualStrings("tools/lint", lines[3].path);
}

test "detached browser does not mark a session named detached as current" {
    var state = ui_state.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .active_menu;
    state.selected_session = 0;

    const frame = try buildFrame(std.testing.allocator, &state, .{
        .workspace = "w",
        .session = "detached",
        .current_session = null,
        .sessions = &.{"detached"},
        .attach_candidates = &.{},
    }, 80, 24);
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.indexOf(u8, frame, "> ○ detached") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "● detached") == null);
}

test "menu clips rows and does not split UTF-8" {
    var state = ui_state.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .active_menu;

    const frame = try buildFrame(std.testing.allocator, &state, .{
        .workspace = "🙂workspace",
        .session = "dev",
        .current_session = "dev",
        .sessions = &.{"dev"},
        .attach_candidates = &.{},
    }, 5, 2);
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.unicode.utf8ValidateSlice(frame[screen_reset.len..]));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, frame, "\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "🙂wor") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "🙂work") == null);
}

test "prompt viewport keeps its grapheme cursor visible" {
    var state = ui_state.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .prompt_create;
    _ = state.handleText(.{}, "ab🙂e\u{301}z");

    const frame = try buildFrame(std.testing.allocator, &state, .{
        .workspace = "w",
        .session = "s",
        .current_session = "s",
        .sessions = &.{"s"},
        .attach_candidates = &.{},
    }, 12, 5);
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.indexOf(u8, frame, "create> e\u{301}z") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "🙂") == null);
    try std.testing.expect(std.mem.endsWith(u8, frame, "\x1b[4;11H\x1b[?25h"));
}

test "prompt cursor handles home narrow resizes and unavailable rows" {
    var state = ui_state.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .prompt_attach;
    _ = state.handleText(.{}, "ab🙂z");
    _ = state.handleKey(.{}, .home);

    const model: policy.Provider.MenuModel = .{
        .workspace = "w",
        .session = "s",
        .current_session = "s",
        .sessions = &.{"s"},
        .attach_candidates = &.{},
    };

    const wide = try buildFrame(std.testing.allocator, &state, model, 12, 5);
    defer std.testing.allocator.free(wide);
    try std.testing.expect(std.mem.indexOf(u8, wide, "attach> ab🙂") != null);
    try std.testing.expect(std.mem.endsWith(u8, wide, "\x1b[4;9H\x1b[?25h"));

    const narrow = try buildFrame(std.testing.allocator, &state, model, 4, 5);
    defer std.testing.allocator.free(narrow);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "cre") == null);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "att") != null);
    try std.testing.expect(std.mem.endsWith(u8, narrow, "\x1b[4;4H\x1b[?25h"));

    const short = try buildFrame(std.testing.allocator, &state, model, 12, 3);
    defer std.testing.allocator.free(short);
    try std.testing.expect(std.mem.indexOf(u8, short, "\x1b[?25h") == null);
}
