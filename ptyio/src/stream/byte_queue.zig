const std = @import("std");

pub const ByteQueue = struct {
    buf: []u8 = &.{},
    start: usize = 0,
    end: usize = 0,

    pub fn init() ByteQueue {
        return .{};
    }

    pub fn deinit(self: *ByteQueue, allocator: std.mem.Allocator) void {
        if (self.buf.len != 0) allocator.free(self.buf);
        self.* = .{};
    }

    pub fn len(self: *const ByteQueue) usize {
        return self.end - self.start;
    }

    pub fn isEmpty(self: *const ByteQueue) bool {
        return self.len() == 0;
    }

    pub fn capacity(self: *const ByteQueue) usize {
        return self.buf.len;
    }

    pub fn readableSlice(self: *const ByteQueue) []const u8 {
        return self.buf[self.start..self.end];
    }

    pub fn mutableReadableSlice(self: *ByteQueue) []u8 {
        return self.buf[self.start..self.end];
    }

    pub fn clear(self: *ByteQueue) void {
        self.start = 0;
        self.end = 0;
    }

    pub fn discard(self: *ByteQueue, n: usize) void {
        const amt = @min(n, self.len());
        self.start += amt;
        if (self.start == self.end) self.clear();
    }

    pub fn compact(self: *ByteQueue) void {
        if (self.start == 0) return;
        if (self.start == self.end) {
            self.clear();
            return;
        }

        const readable = self.len();
        std.mem.copyForwards(u8, self.buf[0..readable], self.buf[self.start..self.end]);
        self.start = 0;
        self.end = readable;
    }

    pub fn ensureCapacity(self: *ByteQueue, allocator: std.mem.Allocator, needed_free: usize) !void {
        if (self.buf.len - self.end >= needed_free) return;

        self.compact();
        if (self.buf.len - self.end >= needed_free) return;

        const required = self.end + needed_free;
        var new_cap: usize = if (self.buf.len == 0) 1024 else self.buf.len;
        while (new_cap < required) : (new_cap *= 2) {}

        const new_buf = try allocator.alloc(u8, new_cap);
        errdefer allocator.free(new_buf);

        const readable = self.len();
        if (readable > 0) {
            std.mem.copyForwards(u8, new_buf[0..readable], self.buf[self.start..self.end]);
        }

        if (self.buf.len != 0) allocator.free(self.buf);
        self.buf = new_buf;
        self.start = 0;
        self.end = readable;
    }

    pub fn append(self: *ByteQueue, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.ensureCapacity(allocator, bytes.len);
        std.mem.copyForwards(u8, self.buf[self.end .. self.end + bytes.len], bytes);
        self.end += bytes.len;
    }

    pub fn appendByte(self: *ByteQueue, allocator: std.mem.Allocator, byte: u8) !void {
        try self.ensureCapacity(allocator, 1);
        self.buf[self.end] = byte;
        self.end += 1;
    }

    pub fn peekPrefix(self: *const ByteQueue, n: usize) ?[]const u8 {
        if (self.len() < n) return null;
        return self.readableSlice()[0..n];
    }

    pub fn takeOwned(self: *ByteQueue, allocator: std.mem.Allocator, n: usize) ![]u8 {
        if (self.len() < n) return error.NotEnoughData;
        const out = try allocator.dupe(u8, self.readableSlice()[0..n]);
        self.discard(n);
        return out;
    }
};

test "byte queue append discard compact" {
    var q = ByteQueue.init();
    defer q.deinit(std.testing.allocator);

    try q.append(std.testing.allocator, "hello");
    try std.testing.expectEqual(@as(usize, 5), q.len());
    try std.testing.expectEqualStrings("hello", q.readableSlice());

    q.discard(2);
    try std.testing.expectEqualStrings("llo", q.readableSlice());

    try q.append(std.testing.allocator, " world");
    try std.testing.expectEqualStrings("llo world", q.readableSlice());

    q.compact();
    try std.testing.expectEqualStrings("llo world", q.readableSlice());
}
