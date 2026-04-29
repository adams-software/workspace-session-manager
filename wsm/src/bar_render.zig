const std = @import("std");
const ui_state = @import("ui_state.zig");

fn appendHeader(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, ctx: ui_state.ExternalContext) !void {
    if (ctx.passive_workspace.len == 0) return;
    try buf.appendSlice(allocator, "\x1b[2m");
    try buf.appendSlice(allocator, ctx.passive_workspace);
    try buf.appendSlice(allocator, "\x1b[0m");
    if (ctx.passive_session.len > 0) {
        try buf.appendSlice(allocator, "/");
        try buf.appendSlice(allocator, "\x1b[1m");
        try buf.appendSlice(allocator, ctx.passive_session);
        try buf.appendSlice(allocator, "\x1b[0m");
    }
}

pub fn buildLine(
    allocator: std.mem.Allocator,
    state: *const ui_state.State,
    ctx: ui_state.ExternalContext,
    width: usize,
) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    try appendHeader(&buf, allocator, ctx);

    switch (state.mode) {
        .passive => {
            if (ctx.passive_workspace.len == 0) {
                try buf.appendSlice(allocator, ctx.passive_text);
            } else {
                if (ctx.passive_text.len > 0) {
                    try buf.appendSlice(allocator, "   ");
                    try buf.appendSlice(allocator, ctx.passive_text);
                }
                try buf.appendSlice(allocator, "   \x1b[2m^g menu\x1b[0m");
            }
        },
        .active_menu => {
            if (ctx.passive_workspace.len > 0 and ctx.active_text.len > 0) {
                try buf.appendSlice(allocator, "   \x1b[1m");
                try buf.appendSlice(allocator, ctx.active_text);
                try buf.appendSlice(allocator, "\x1b[0m");
                try buf.appendSlice(allocator, "   ");
            } else if (ctx.passive_workspace.len > 0) {
                try buf.appendSlice(allocator, "   ");
            }
            try buf.appendSlice(allocator, "\x1b[1m[d]detach [a]attach [c]create [g]logs [q]quit [esc/^g]back\x1b[0m");
        },
        .prompt_attach => {
            if (ctx.passive_workspace.len > 0) try buf.appendSlice(allocator, "   ");
            try buf.appendSlice(allocator, "attach> ");
            try buf.appendSlice(allocator, state.input());
            if (state.selected_candidate) |idx| {
                if (idx < ctx.attach_candidates.len) {
                    try buf.appendSlice(allocator, "   < ");
                    try buf.appendSlice(allocator, ctx.attach_candidates[idx].label);
                    try buf.appendSlice(allocator, " >");
                }
            }
            try buf.appendSlice(allocator, "   [enter]go [tab/down]next [up]prev [esc]back");
        },
        .prompt_create => {
            if (ctx.passive_workspace.len > 0) try buf.appendSlice(allocator, "   ");
            try buf.appendSlice(allocator, "create> ");
            try buf.appendSlice(allocator, state.input());
            try buf.appendSlice(allocator, "   [enter]create [esc]back");
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

    const line = try buildLine(std.testing.allocator, &state, .{ .passive_text = "backend" }, 20);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("backend             ", line);
}

