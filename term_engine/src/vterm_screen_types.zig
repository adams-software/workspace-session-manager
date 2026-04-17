const std = @import("std");

pub const HostAnsiClass = enum(u8) {
    none = 0,
    classic_low = 1,      // 30..37 / 40..47
    classic_bright = 2,   // 90..97 / 100..107
    indexed_extended = 3, // 38;5;n / 48;5;n where n >= 16
};

pub const HostColor = struct {
    kind: enum {
        default,
        indexed,
        rgb,
    } = .default,

    palette_index: u8 = 0,
    red: u8 = 0,
    green: u8 = 0,
    blue: u8 = 0,

    ansi_class: HostAnsiClass = .none,

    // True only when a low classic fg was promoted to bright because of
    // libvterm bold-highbright policy. Probably stays false in your current stack,
    // but it is worth preserving.
    promoted_by_bold: bool = false,
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

pub const HostHyperlink = struct {
    params: []const u8,
    uri: []const u8,
};

pub const HostScreenCell = struct {
    chars: [6]u32 = [_]u32{0} ** 6,
    chars_len: u8 = 0,
    width: u8 = 1,
    hyperlink: u32 = 0,
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
    hyperlinks: []HostHyperlink = &.{},
    lines: []HostScreenLine,
};

pub fn freeScreenSnapshot(allocator: std.mem.Allocator, snapshot: *HostScreenSnapshot) void {
    for (snapshot.lines) |line| {
        allocator.free(line.cells);
    }
    allocator.free(snapshot.lines);
    if (snapshot.title) |title| allocator.free(title);
    for (snapshot.hyperlinks) |link| {
        allocator.free(link.params);
        allocator.free(link.uri);
    }
    if (snapshot.hyperlinks.len > 0) allocator.free(snapshot.hyperlinks);
}
