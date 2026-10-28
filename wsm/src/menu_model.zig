const std = @import("std");

pub const NavTargets = struct {
    prev: ?[]const u8,
    next: ?[]const u8,
    child: ?[]const u8,
    parent: ?[]const u8,
};

pub fn buildActiveSummary(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, nav: NavTargets) !void {
    buf.clearRetainingCapacity();

    if (nav.prev) |target| {
        const label = try relativeSiblingLabelAlloc(allocator, target);
        defer allocator.free(label);
        try appendTag(buf, allocator, "←", label);
    } else try appendTag(buf, allocator, "←", "_");

    if (nav.child) |target| {
        const label = try relativeChildLabelAlloc(allocator, target);
        defer allocator.free(label);
        try appendTag(buf, allocator, "↓", label);
    } else try appendTag(buf, allocator, "↓", "_");

    if (nav.parent) |target| {
        const label = try relativeParentLabelAlloc(allocator, target);
        defer allocator.free(label);
        try appendTag(buf, allocator, "↑", label);
    } else try appendTag(buf, allocator, "↑", "_");

    if (nav.next) |target| {
        const label = try relativeSiblingLabelAlloc(allocator, target);
        defer allocator.free(label);
        try appendTag(buf, allocator, "→", label);
    } else try appendTag(buf, allocator, "→", "_");
}

fn appendTag(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, prefix: []const u8, value: []const u8) !void {
    if (buf.items.len > 0) try buf.appendSlice(allocator, " ");
    try buf.appendSlice(allocator, "[");
    try buf.appendSlice(allocator, prefix);
    try buf.appendSlice(allocator, "] ");
    try buf.appendSlice(allocator, value);
}

fn relativeSiblingLabelAlloc(allocator: std.mem.Allocator, sibling: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "./{s}", .{basename(sibling)});
}

fn relativeParentLabelAlloc(allocator: std.mem.Allocator, parent: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "../{s}", .{basename(parent)});
}

fn relativeChildLabelAlloc(allocator: std.mem.Allocator, child: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "./{s}", .{child});
}

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}
