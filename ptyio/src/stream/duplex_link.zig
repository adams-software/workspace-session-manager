const std = @import("std");
const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");

pub const PumpResult = struct {
    left_eof: bool = false,
    right_eof: bool = false,
    did_work: bool = false,
};

pub const DuplexLink = struct {
    allocator: std.mem.Allocator,
    left_to_right: ByteQueue,
    right_to_left: ByteQueue,

    pub fn init(allocator: std.mem.Allocator) DuplexLink {
        return .{
            .allocator = allocator,
            .left_to_right = ByteQueue.init(),
            .right_to_left = ByteQueue.init(),
        };
    }

    pub fn deinit(self: *DuplexLink) void {
        self.left_to_right.deinit(self.allocator);
        self.right_to_left.deinit(self.allocator);
    }

    pub fn clear(self: *DuplexLink) void {
        self.left_to_right.clear();
        self.right_to_left.clear();
    }

    pub fn pushLeft(self: *DuplexLink, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.left_to_right.append(self.allocator, bytes);
    }

    pub fn flushLeftToRight(self: *DuplexLink, right_fd: std.posix.fd_t) !bool {
        var did_work = false;
        while (true) {
            const before = self.left_to_right.readableSlice().len;
            const status = try fd_stream.writeFromQueue(right_fd, &self.left_to_right, 64 * 1024);
            const after = self.left_to_right.readableSlice().len;
            if (after < before) did_work = true;
            switch (status) {
                .progress => {
                    if (self.left_to_right.isEmpty()) break;
                },
                .would_block => break,
            }
        }
        return did_work;
    }

    pub fn readRight(self: *DuplexLink, right_fd: std.posix.fd_t) !struct { eof: bool, did_work: bool } {
        var did_work = false;
        while (true) {
            const before = self.right_to_left.readableSlice().len;
            const status = try fd_stream.readIntoQueue(self.allocator, right_fd, &self.right_to_left, 64 * 1024);
            const after = self.right_to_left.readableSlice().len;
            if (after > before) did_work = true;
            switch (status) {
                .progress => {},
                .would_block => break,
                .eof => return .{ .eof = true, .did_work = did_work },
            }
        }
        return .{ .eof = false, .did_work = did_work };
    }

    pub fn flushRightToLeft(self: *DuplexLink, left_fd: std.posix.fd_t) !bool {
        var did_work = false;
        while (true) {
            const before = self.right_to_left.readableSlice().len;
            const status = try fd_stream.writeFromQueue(left_fd, &self.right_to_left, 64 * 1024);
            const after = self.right_to_left.readableSlice().len;
            if (after < before) did_work = true;
            switch (status) {
                .progress => {
                    if (self.right_to_left.isEmpty()) break;
                },
                .would_block => break,
            }
        }
        return did_work;
    }

    pub fn pump(self: *DuplexLink, left_fd: std.posix.fd_t, right_fd: std.posix.fd_t) !PumpResult {
        var result = PumpResult{};
        if (try self.flushLeftToRight(right_fd)) result.did_work = true;
        const read = try self.readRight(right_fd);
        if (read.did_work) result.did_work = true;
        result.right_eof = read.eof;
        if (try self.flushRightToLeft(left_fd)) result.did_work = true;
        return result;
    }
};
