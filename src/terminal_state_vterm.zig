const std = @import("std");
const c = @cImport({
    @cInclude("vterm_shim.h");
});
const host = @import("host.zig");

pub const VTermAdapter = struct {
    handle: ?*c.msr_vterm_handle,

    pub fn init(_: std.mem.Allocator, rows: u16, cols: u16) !VTermAdapter {
        const handle = c.msr_vterm_new(@intCast(rows), @intCast(cols)) orelse return error.OutOfMemory;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *VTermAdapter) void {
        if (self.handle) |handle| {
            c.msr_vterm_free(handle);
            self.handle = null;
        }
    }

    pub fn resize(self: *VTermAdapter, rows: u16, cols: u16) void {
        if (self.handle) |handle| c.msr_vterm_set_size(handle, @intCast(rows), @intCast(cols));
    }

    pub fn feed(self: *VTermAdapter, bytes: []const u8) void {
        if (self.handle) |handle| c.msr_vterm_feed(handle, bytes.ptr, bytes.len);
    }

    pub fn snapshot(self: *const VTermAdapter, allocator: std.mem.Allocator) !host.HostScreenSnapshot {
        const handle = self.handle orelse return error.InvalidState;
        var rows_i: c_int = 0;
        var cols_i: c_int = 0;
        c.msr_vterm_get_size(handle, &rows_i, &cols_i);
        const rows: usize = @intCast(rows_i);
        const cols: usize = @intCast(cols_i);

        var out_rows = try allocator.alloc([]host.HostScreenCell, rows);
        errdefer allocator.free(out_rows);

        var r: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < r) : (i += 1) {
                for (out_rows[i]) |cell| allocator.free(cell.text);
                allocator.free(out_rows[i]);
            }
        }

        while (r < rows) : (r += 1) {
            out_rows[r] = try allocator.alloc(host.HostScreenCell, cols);
            for (0..cols) |cidx| {
                const raw_cp = c.msr_vterm_get_cell_codepoint(handle, @intCast(r), @intCast(cidx));
                const cp: u21 = @intCast(if (raw_cp == 0) ' ' else raw_cp);
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidState;
                out_rows[r][cidx] = .{ .text = try allocator.dupe(u8, buf[0..n]) };
            }
        }

        var cursor_row: c_int = 0;
        var cursor_col: c_int = 0;
        var cursor_visible: c_int = 1;
        c.msr_vterm_get_cursor(handle, &cursor_row, &cursor_col, &cursor_visible);
        const alt_screen = c.msr_vterm_get_alt_screen(handle) != 0;

        return .{
            .rows = @intCast(rows),
            .cols = @intCast(cols),
            .cursor_row = @intCast(cursor_row),
            .cursor_col = @intCast(cursor_col),
            .cursor_visible = cursor_visible != 0,
            .alt_screen = alt_screen,
            .title = null,
            .seq = 0,
            .cells = out_rows,
        };
    }
};

test "libvterm adapter create/free" {
    var adapter = try VTermAdapter.init(std.testing.allocator, 24, 80);
    defer adapter.deinit();
    try std.testing.expect(adapter.handle != null);
}
