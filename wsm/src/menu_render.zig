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
            var prompt: std.ArrayList(u8) = .empty;
            defer prompt.deinit(allocator);
            try prompt.appendSlice(allocator, "attach> ");
            try prompt.appendSlice(allocator, state.input());
            try appendLine(&frame, allocator, prompt.items, cols, rows, &row);
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
            var prompt: std.ArrayList(u8) = .empty;
            defer prompt.deinit(allocator);
            try prompt.appendSlice(allocator, "create> ");
            try prompt.appendSlice(allocator, state.input());
            try appendLine(&frame, allocator, prompt.items, cols, rows, &row);
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

    return frame.toOwnedSlice(allocator);
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

test "menu clipping keeps combining and emoji graphemes whole" {
    var state = ui_state.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .prompt_create;
    _ = state.handleText(.{}, "e\u{301}🙂z");

    const frame = try buildFrame(std.testing.allocator, &state, .{
        .workspace = "w",
        .session = "s",
        .active_summary = "",
        .attach_candidates = &.{},
    }, 11, 5);
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.indexOf(u8, frame, "create> e\u{301}🙂") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "🙂z") == null);
}
