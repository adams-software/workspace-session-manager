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
            if (model.active_summary.len > 0) try appendLine(&frame, allocator, model.active_summary, cols, rows, &row);
            try appendLine(&frame, allocator, "", cols, rows, &row);
            try appendLine(&frame, allocator, "a  attach", cols, rows, &row);
            try appendLine(&frame, allocator, "c  create", cols, rows, &row);
            try appendLine(&frame, allocator, "g  logs", cols, rows, &row);
            try appendLine(&frame, allocator, "b  back", cols, rows, &row);
            try appendLine(&frame, allocator, "d  detach", cols, rows, &row);
            try appendLine(&frame, allocator, "x  force kill", cols, rows, &row);
            try appendLine(&frame, allocator, "", cols, rows, &row);
            try appendLine(&frame, allocator, "arrows or h/j/k/l navigate", cols, rows, &row);
            try appendLine(&frame, allocator, "esc, enter, or ctrl-g returns", cols, rows, &row);
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

test "active menu renders a full-screen action surface" {
    var state = ui_state.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .active_menu;

    const frame = try buildFrame(std.testing.allocator, &state, .{
        .workspace = "/tmp/workspace",
        .session = "dev",
        .active_summary = "[left] prev [right] next",
        .attach_candidates = &.{},
    }, 80, 24);
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.startsWith(u8, frame, screen_reset));
    try std.testing.expect(std.mem.indexOf(u8, frame, "/tmp/workspace / dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "a  attach") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "ctrl-g returns") != null);
}

test "menu clips rows and does not split UTF-8" {
    var state = ui_state.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .active_menu;

    const frame = try buildFrame(std.testing.allocator, &state, .{
        .workspace = "🙂workspace",
        .session = "dev",
        .active_summary = "",
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
        .active_summary = "",
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
        .active_summary = "",
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
