const std = @import("std");

pub const HostColor = struct {
    pub const Kind = enum {
        default,
        indexed,
        rgb,
    };

    kind: Kind = .default,
    palette_index: u8 = 0,
    red: u8 = 0,
    green: u8 = 0,
    blue: u8 = 0,
};

pub const HostCellAttrs = struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    conceal: bool = false,
    strike: bool = false,
    font: u8 = 0,
};

pub const HostScreenCell = struct {
    chars: [6]u32 = [_]u32{0} ** 6,
    chars_len: u8 = 0,
    width: u8 = 1,
    fg: HostColor = .{},
    bg: HostColor = .{},
    attrs: HostCellAttrs = .{},
};

pub const HostScreenLine = struct {
    cells: []HostScreenCell,
    eol: bool = false,
};

pub const HostScreenSnapshot = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    alt_screen: bool,
    title: ?[]const u8 = null,
    seq: u64,
    lines: []HostScreenLine,
};

pub fn freeScreenSnapshot(allocator: std.mem.Allocator, snapshot: *HostScreenSnapshot) void {
    for (snapshot.lines) |line| {
        allocator.free(line.cells);
    }
    allocator.free(snapshot.lines);
    if (snapshot.title) |title| allocator.free(title);
}
