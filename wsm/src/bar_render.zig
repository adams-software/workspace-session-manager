const std = @import("std");
const ui_state = @import("ui_state.zig");
const policy = @import("policy.zig");

fn appendHeader(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, model: policy.Provider.BarModel) !void {
    if (model.workspace.len == 0) return;
    try buf.appendSlice(allocator, model.workspace);
    if (model.session.len > 0) {
        try buf.appendSlice(allocator, "/");
        try buf.appendSlice(allocator, model.session);
    }
}

pub fn buildLine(
    allocator: std.mem.Allocator,
    state: *const ui_state.State,
    model: policy.Provider.BarModel,
    width: usize,
) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    switch (state.mode) {
        .passive => {
            if (model.scroll_view and model.session.len > 0) {
                try buf.appendSlice(allocator, "logs: ");
                try buf.appendSlice(allocator, model.session);
                if (std.mem.endsWith(u8, model.session, ".scroll")) {
                    buf.items.len -= ".scroll".len;
                }
                try buf.appendSlice(allocator, "   q exit");
            } else {
                try buf.appendSlice(allocator, model.passive_label);
                if (model.passive_label.len > 0) try buf.appendSlice(allocator, "   ");
                try buf.appendSlice(allocator, "^g menu");
            }
        },
        .active_menu => {
            try appendHeader(&buf, allocator, model);
            if (model.workspace.len > 0 and model.active_summary.len > 0) {
                try buf.appendSlice(allocator, "   ");
                try buf.appendSlice(allocator, model.active_summary);
                try buf.appendSlice(allocator, "  |  ");
            } else if (model.workspace.len > 0) {
                try buf.appendSlice(allocator, "   ");
            }
            try buf.appendSlice(allocator, "[a]ttach [c]reate [g]logs [d]etach [x]kill [esc]");
        },
        .prompt_attach => {
            try appendHeader(&buf, allocator, model);
            if (model.workspace.len > 0) try buf.appendSlice(allocator, "   ");
            try buf.appendSlice(allocator, "attach> ");
            try buf.appendSlice(allocator, state.input());
            if (state.selected_candidate) |idx| {
                if (idx < model.attach_candidates.len) {
                    try buf.appendSlice(allocator, "   < ");
                    try buf.appendSlice(allocator, model.attach_candidates[idx].label);
                    try buf.appendSlice(allocator, " >");
                }
            }
            try buf.appendSlice(allocator, "   [enter]go [tab/down]next [up]prev [esc]back");
        },
        .prompt_create => {
            try appendHeader(&buf, allocator, model);
            if (model.workspace.len > 0) try buf.appendSlice(allocator, "   ");
            try buf.appendSlice(allocator, "create> ");
            try buf.appendSlice(allocator, state.input());
            try buf.appendSlice(allocator, "   [enter]create [esc]back");
        },
        .prompt_kill => {
            try appendHeader(&buf, allocator, model);
            if (model.workspace.len > 0) try buf.appendSlice(allocator, "   ");
            try buf.appendSlice(allocator, "kill current session? [enter]TERM [esc]cancel");
        },
    }

    if (state.notice_kind != .none and state.notice().len > 0) {
        try buf.appendSlice(allocator, "   ! ");
        try buf.appendSlice(allocator, state.notice());
    }

    if (buf.items.len > width) buf.shrinkRetainingCapacity(width);
    while (buf.items.len < width) try buf.append(allocator, ' ');
    return buf.toOwnedSlice(allocator);
}

test "buildLine renders passive text and menu hint" {
    var state = ui_state.State.init(std.testing.allocator);
    defer state.deinit();

    const line = try buildLine(std.testing.allocator, &state, .{ .workspace = "", .session = "", .passive_label = "backend", .logs_exit_hint = false, .active_summary = "", .attach_candidates = &.{}, .detached = false, .scroll_view = false }, 20);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("backend             ", line);
}
