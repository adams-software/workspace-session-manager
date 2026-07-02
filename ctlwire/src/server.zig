const std = @import("std");

pub const max_line_len = 64 * 1024;
pub const Error = error{
    ConnectionClosed,
    LineTooLong,
    UnexpectedEof,
};

pub const Connection = struct {
    file: std.fs.File,
    line_buf: std.ArrayList(u8),
    line_ready: bool = false,

    pub fn init(fd: std.posix.fd_t) Connection {
        return .{ .file = .{ .handle = fd }, .line_buf = .empty };
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        self.line_buf.deinit(allocator);
    }

    pub fn nextLine(self: *Connection, allocator: std.mem.Allocator) !?[]const u8 {
        self.prepareForNextLine();
        var byte_buf: [1]u8 = undefined;
        while (true) {
            const n = self.file.read(byte_buf[0..]) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return Error.ConnectionClosed,
            };
            if (n == 0) return self.handleEof();

            const b = byte_buf[0];
            if (b != '\r' and b != '\n') {
                if (self.line_buf.items.len >= max_line_len) return Error.LineTooLong;
                try self.line_buf.append(allocator, b);
                continue;
            }

            if (self.finishBufferedLine()) |line_text| return line_text;
        }
    }

    fn prepareForNextLine(self: *Connection) void {
        if (!self.line_ready) return;
        self.line_buf.clearRetainingCapacity();
        self.line_ready = false;
    }

    fn handleEof(self: *Connection) Error!?[]const u8 {
        if (self.line_buf.items.len == 0) return Error.ConnectionClosed;
        return Error.UnexpectedEof;
    }

    fn finishBufferedLine(self: *Connection) ?[]const u8 {
        const trimmed = std.mem.trimEnd(u8, self.line_buf.items, "\r\n");
        if (trimmed.len == 0) {
            self.line_buf.clearRetainingCapacity();
            return null;
        }
        self.line_ready = true;
        return trimmed;
    }
};

test "connection finishBufferedLine keeps returned slice stable until next call" {
    var conn = Connection{
        .file = undefined,
        .line_buf = .empty,
    };
    defer conn.deinit(std.testing.allocator);
    try conn.line_buf.appendSlice(std.testing.allocator, "state");

    const line_text = conn.finishBufferedLine();
    try std.testing.expect(line_text != null);
    try std.testing.expectEqualStrings("state", line_text.?);
    try std.testing.expect(conn.line_ready);
    try std.testing.expectEqualStrings("state", conn.line_buf.items);
}

test "connection prepareForNextLine clears consumed line but not partial state" {
    var conn = Connection{
        .file = undefined,
        .line_buf = .empty,
    };
    defer conn.deinit(std.testing.allocator);
    try conn.line_buf.appendSlice(std.testing.allocator, "state");
    _ = conn.finishBufferedLine();
    conn.prepareForNextLine();
    try std.testing.expect(!conn.line_ready);
    try std.testing.expectEqual(@as(usize, 0), conn.line_buf.items.len);

    try conn.line_buf.appendSlice(std.testing.allocator, "par");
    conn.prepareForNextLine();
    try std.testing.expectEqualStrings("par", conn.line_buf.items);
}

test "connection handleEof distinguishes empty from partial buffered state" {
    var conn = Connection{
        .file = undefined,
        .line_buf = .empty,
    };
    defer conn.deinit(std.testing.allocator);

    try std.testing.expectError(Error.ConnectionClosed, conn.handleEof());
    try conn.line_buf.appendSlice(std.testing.allocator, "partial");
    try std.testing.expectError(Error.UnexpectedEof, conn.handleEof());
}
