const std = @import("std");
const ui_state = @import("ui_state.zig");

pub const Layout = struct {
    outer_cols: u16,
    outer_rows: u16,
    bar_visible: bool,
    bar_fullscreen: bool,
    main_rows: u16,
    bar_row: ?u16,
};

pub fn compute(cols: u16, rows: u16, mode: ui_state.Mode) Layout {
    const active = mode != .passive;

    if (!active and rows < 3) {
        return .{
            .outer_cols = cols,
            .outer_rows = rows,
            .bar_visible = false,
            .bar_fullscreen = false,
            .main_rows = rows,
            .bar_row = null,
        };
    }

    if (active and rows < 2) {
        return .{
            .outer_cols = cols,
            .outer_rows = rows,
            .bar_visible = true,
            .bar_fullscreen = true,
            .main_rows = 0,
            .bar_row = 0,
        };
    }

    return .{
        .outer_cols = cols,
        .outer_rows = rows,
        .bar_visible = true,
        .bar_fullscreen = false,
        .main_rows = rows - 1,
        .bar_row = rows - 1,
    };
}

test "passive hides bar below 3 rows" {
    const computed = compute(80, 2, .passive);
    try std.testing.expect(!computed.bar_visible);
    try std.testing.expectEqual(@as(u16, 2), computed.main_rows);
}

test "active takes fullscreen when only one row exists" {
    const computed = compute(80, 1, .active_menu);
    try std.testing.expect(computed.bar_visible);
    try std.testing.expect(computed.bar_fullscreen);
    try std.testing.expectEqual(@as(u16, 0), computed.main_rows);
}

test "normal layout reserves one row for bar" {
    const computed = compute(80, 5, .passive);
    try std.testing.expect(computed.bar_visible);
    try std.testing.expectEqual(@as(u16, 4), computed.main_rows);
    try std.testing.expectEqual(@as(u16, 4), computed.bar_row.?);
}
