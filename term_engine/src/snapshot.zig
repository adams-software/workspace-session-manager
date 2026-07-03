const std = @import("std");
const c = @import("c.zig").c;
const screen_types = @import("vterm_screen_types.zig");

pub fn convertColor(raw: c.msr_vterm_color, is_fg: bool) screen_types.HostColor {
    const ansi_class: screen_types.HostAnsiClass = switch (raw.ansi_class) {
        c.MSR_VTERM_ANSI_CLASSIC_LOW => .classic_low,
        c.MSR_VTERM_ANSI_CLASSIC_BRIGHT => .classic_bright,
        c.MSR_VTERM_ANSI_INDEXED_EXTENDED => .indexed_extended,
        else => .none,
    };

    if ((is_fg and raw.is_default_fg != 0) or (!is_fg and raw.is_default_bg != 0)) {
        return .{ .kind = .default, .ansi_class = .none, .promoted_by_bold = false };
    }

    return switch (raw.type) {
        1 => .{
            .kind = .indexed,
            .palette_index = raw.palette_index,
            .ansi_class = ansi_class,
            .promoted_by_bold = raw.promoted_by_bold != 0,
        },
        2 => .{
            .kind = .rgb,
            .red = raw.red,
            .green = raw.green,
            .blue = raw.blue,
            .ansi_class = .none,
            .promoted_by_bold = false,
        },
        else => .{ .kind = .default, .ansi_class = .none, .promoted_by_bold = false },
    };
}

pub fn snapshotFromHandle(handle: *c.msr_vterm_handle, allocator: std.mem.Allocator) !screen_types.HostScreenSnapshot {
    const rows = handle.rows;
    const cols = handle.cols;

    var lines = try allocator.alloc(screen_types.HostScreenLine, @intCast(rows));
    var hyperlink_map = std.AutoHashMap(u32, u32).init(allocator);
    defer hyperlink_map.deinit();
    var hyperlinks: std.ArrayList(screen_types.HostHyperlink) = .empty;
    var initialized_rows: usize = 0;
    errdefer {
        for (lines[0..initialized_rows]) |line| allocator.free(line.cells);
        allocator.free(lines);
        for (hyperlinks.items) |link| {
            allocator.free(link.params);
            allocator.free(link.uri);
        }
        hyperlinks.deinit(allocator);
    }

    for (0..@intCast(rows)) |r| {
        const row_cells = try allocator.alloc(screen_types.HostScreenCell, @intCast(cols));
        lines[r] = .{ .cells = row_cells, .eol = c.msr_vterm_row_is_eol(handle, @intCast(r)) != 0 };
        initialized_rows += 1;

        for (0..@intCast(cols)) |col_idx| {
            var raw: c.msr_vterm_cell = undefined;
            c.msr_vterm_get_cell(handle, @intCast(r), @intCast(col_idx), &raw);
            var chars: [6]u32 = [_]u32{0} ** 6;
            var i: usize = 0;
            while (i < raw.chars_len and i < chars.len) : (i += 1) chars[i] = raw.chars[i];
            row_cells[col_idx] = .{
                .chars = chars,
                .chars_len = raw.chars_len,
                .width = raw.width,
                .hyperlink = 0,
                .fg = convertColor(raw.fg, true),
                .bg = convertColor(raw.bg, false),
                .attrs = .{
                    .bold = raw.attrs.bold != 0,
                    .italic = raw.attrs.italic != 0,
                    .underline = raw.attrs.underline != 0,
                    .blink = raw.attrs.blink != 0,
                    .reverse = raw.attrs.reverse != 0,
                    .conceal = raw.attrs.conceal != 0,
                    .strike = raw.attrs.strike != 0,
                    .font = raw.attrs.font,
                },
            };

            if (raw.hyperlink_handle != 0) {
                const gop = try hyperlink_map.getOrPut(raw.hyperlink_handle);
                if (!gop.found_existing) {
                    var params_len: usize = 0;
                    const params_ptr = c.msr_vterm_get_hyperlink_params(handle, raw.hyperlink_handle, &params_len) orelse {
                        _ = hyperlink_map.remove(raw.hyperlink_handle);
                        continue;
                    };
                    var uri_len: usize = 0;
                    const uri_ptr = c.msr_vterm_get_hyperlink_uri(handle, raw.hyperlink_handle, &uri_len) orelse {
                        _ = hyperlink_map.remove(raw.hyperlink_handle);
                        continue;
                    };
                    const params = try allocator.dupe(u8, params_ptr[0..params_len]);
                    errdefer allocator.free(params);
                    const uri = try allocator.dupe(u8, uri_ptr[0..uri_len]);
                    errdefer allocator.free(uri);
                    try hyperlinks.append(allocator, .{ .params = params, .uri = uri });
                    gop.value_ptr.* = @intCast(hyperlinks.items.len);
                }
                row_cells[col_idx].hyperlink = gop.value_ptr.*;
            }
        }
    }

    var cursor_row: c_int = 0;
    var cursor_col: c_int = 0;
    var cursor_visible: c_int = 0;
    c.msr_vterm_get_cursor(handle, &cursor_row, &cursor_col, &cursor_visible);

    return .{
        .rows = @intCast(rows),
        .cols = @intCast(cols),
        .cursor_row = @intCast(cursor_row),
        .cursor_col = @intCast(cursor_col),
        .cursor_visible = cursor_visible != 0,
        .alt_screen = c.msr_vterm_get_alt_screen(handle) != 0,
        .title = null,
        .seq = 0,
        .hyperlinks = try hyperlinks.toOwnedSlice(allocator),
        .lines = lines,
    };
}
