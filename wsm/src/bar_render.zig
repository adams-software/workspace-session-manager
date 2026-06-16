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
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    switch (state.mode) {
        .passive => {
            try buf.appendSlice(allocator, model.passive_label);
            if (model.passive_label.len > 0) try buf.appendSlice(allocator, "   ");
            try buf.appendSlice(allocator, "^g menu");
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
            try buf.appendSlice(allocator, "[a]ttach [c]reate [g]logs [b]ack [d]etach [x]force kill [enter/esc]");
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
            try buf.appendSlice(allocator, "force kill current session? [enter]KILL [esc]cancel");
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

    const line = try buildLine(std.testing.allocator, &state, .{ .workspace = "", .session = "", .passive_label = "backend", .active_summary = "", .attach_candidates = &.{}, .detached = false }, 20);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("backend   ^g menu   ", line);
}

test "buildLine includes back hint in active menu" {
    var state = ui_state.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .active_menu;

    const line = try buildLine(std.testing.allocator, &state, .{ .workspace = "", .session = "", .passive_label = "", .active_summary = "", .attach_candidates = &.{}, .detached = false }, 80);
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "[b]ack") != null);
}
