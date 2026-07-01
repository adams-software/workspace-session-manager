const std = @import("std");
const host = @import("session_host_vpty");

pub const VirtualCursor = struct {
    visible: bool = true,
    row: u16 = 0,
    col: u16 = 0,
};

pub const Viewport = struct {
    origin_row: u16 = 0,
    origin_col: u16 = 0,
    rows: u16 = 0,
    cols: u16 = 0,

    pub fn init(origin_row: u16, origin_col: u16, rows: u16, cols: u16) Viewport {
        return .{
            .origin_row = origin_row,
            .origin_col = origin_col,
            .rows = rows,
            .cols = cols,
        };
    }
};

pub const TextRun = struct {
    start_col: u16,
    end_col: u16,
    cells: []const host.HostScreenCell,

    pub fn init(start_col: u16, end_col: u16, cells: []const host.HostScreenCell) TextRun {
        return .{
            .start_col = start_col,
            .end_col = end_col,
            .cells = cells,
        };
    }
};

pub const RowPatch = struct {
    row: u16,
    runs: std.ArrayList(TextRun),
    clear_remaining: bool = true,

    pub fn init(row: u16) RowPatch {
        return .{
            .row = row,
            .runs = .empty,
            .clear_remaining = true,
        };
    }

    pub fn deinit(self: *RowPatch, allocator: std.mem.Allocator) void {
        self.runs.deinit(allocator);
    }
};

pub const ViewportPatch = struct {
    full_redraw: bool,
    rows: std.ArrayList(RowPatch),
    cursor: VirtualCursor,

    pub fn init(full_redraw: bool, allocator: std.mem.Allocator) ViewportPatch {
        _ = allocator;
        return .{
            .full_redraw = full_redraw,
            .rows = .empty,
            .cursor = .{},
        };
    }

    pub fn deinit(self: *ViewportPatch, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.deinit(allocator);
        self.rows.deinit(allocator);
    }
};
