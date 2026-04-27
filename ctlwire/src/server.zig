const std = @import("std");

pub const max_line_len = 64 * 1024;

pub const Connection = struct {
    file: std.fs.File,
    line_buf: std.ArrayList(u8),

    pub fn init(fd: std.posix.fd_t) Connection {
        return .{ .file = .{ .handle = fd }, .line_buf = .{} };
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        self.line_buf.deinit(allocator);
    }

    pub fn nextLine(self: *Connection, allocator: std.mem.Allocator) !?[]const u8 {
        var byte_buf: [1]u8 = undefined;
        while (true) {
            const n = self.file.read(byte_buf[0..]) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return error.ConnectionClosed,
            };
            if (n == 0) return error.ConnectionClosed;

            const b = byte_buf[0];
            if (b != '\r' and b != '\n') {
                if (self.line_buf.items.len >= max_line_len) return error.LineTooLong;
                try self.line_buf.append(allocator, b);
                continue;
            }

            const trimmed = std.mem.trimRight(u8, self.line_buf.items, "\r\n");
            defer self.line_buf.clearRetainingCapacity();
            if (trimmed.len == 0) continue;
            return trimmed;
        }
    }
};
