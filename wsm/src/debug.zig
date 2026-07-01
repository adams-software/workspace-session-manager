const std = @import("std");

pub fn enabled() bool {
    return std.c.getenv("WSM_DEBUG") != null;
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!enabled()) return;
    std.debug.print(fmt, args);
}
