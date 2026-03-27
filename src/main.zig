const std = @import("std");
const msr = @import("msr");

pub fn main() !void {
    std.debug.print("msr-demo: runtime scaffold ready\n", .{});
    const rt = msr.Runtime.init(std.heap.page_allocator);
    _ = rt;
}
