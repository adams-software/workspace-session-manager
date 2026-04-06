const std = @import("std");
const c = @cImport({
    @cInclude("vterm_shim.h");
    @cInclude("stdlib.h");
});
const screen_types = @import("vterm_screen_types.zig");

fn convertColor(raw: c.msr_vterm_color) screen_types.HostColor {
    return switch (raw.type) {
        1 => .{ .kind = .indexed, .palette_index = raw.palette_index },
        2 => .{ .kind = .rgb, .red = raw.red, .green = raw.green, .blue = raw.blue },
        else => .{ .kind = .default },
    };
}

pub const VTermAdapter = struct {
    handle: ?*c.msr_vterm_handle,
    render_callback: ?*const fn () void = null,

    pub fn init(rows: u16, cols: u16) !VTermAdapter {
        const handle = c.msr_vterm_new(@intCast(rows), @intCast(cols)) orelse return error.OutOfMemory;
        return .{
            .handle = handle,
            .render_callback = null,
        };
    }

    pub fn deinit(self: *VTermAdapter) void {
        if (self.handle) |handle| {
            c.msr_vterm_free(handle);
            self.handle = null;
        }
    }

    pub fn setRenderCallback(self: *VTermAdapter, callback: *const fn () void) void {
        self.render_callback = callback;
    }

    pub fn feed(self: *VTermAdapter, bytes: []const u8) void {
        if (self.handle) |handle| {
            c.msr_vterm_feed(handle, bytes.ptr, bytes.len);
            c.msr_vterm_flush_damage(handle);
            if (self.render_callback) |cb| cb();
        }
    }

    pub fn flushDamage(self: *VTermAdapter) void {
        if (self.handle) |h| c.msr_vterm_flush_damage(h);
    }

    pub fn forceFullDamage(self: *VTermAdapter) void {
        if (self.handle) |h| c.msr_vterm_force_full_damage(h);
    }

    pub fn resize(self: *VTermAdapter, rows: u16, cols: u16) void {
        if (self.handle) |handle| c.msr_vterm_set_size(handle, @intCast(rows), @intCast(cols));
    }

    pub fn snapshot(self: *const VTermAdapter, allocator: std.mem.Allocator) !screen_types.HostScreenSnapshot {
        if (self.handle == null) return error.InvalidState;
        const handle = self.handle.?;

        const rows = handle.rows;
        const cols = handle.cols;

        var lines = try allocator.alloc(screen_types.HostScreenLine, @intCast(rows));
        var initialized_rows: usize = 0;
        errdefer {
            for (lines[0..initialized_rows]) |line| {
                allocator.free(line.cells);
            }
            allocator.free(lines);
        }


        for (0..@intCast(rows)) |r| {
            const row_cells = try allocator.alloc(screen_types.HostScreenCell, @intCast(cols));
            lines[r] = .{
                .cells = row_cells,
                .eol = c.msr_vterm_row_is_eol(handle, @intCast(r)) != 0,
            };
            initialized_rows += 1;

            for (0..@intCast(cols)) |col_idx| {
                var raw: c.msr_vterm_cell = undefined;
                c.msr_vterm_get_cell(handle, @intCast(r), @intCast(col_idx), &raw);

                var chars: [6]u32 = [_]u32{0} ** 6;
                var i: usize = 0;
                while (i < raw.chars_len and i < chars.len) : (i += 1) {
                    chars[i] = raw.chars[i];
                }

                row_cells[col_idx] = .{
                    .chars = chars,
                    .chars_len = raw.chars_len,
                    .width = raw.width,
                    .fg = convertColor(raw.fg),
                    .bg = convertColor(raw.bg),
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
            .full_damage = true,
            .lines = lines,
        };
    }
};
