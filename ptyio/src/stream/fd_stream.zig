const std = @import("std");
const ByteQueue = @import("byte_queue").ByteQueue;

const c = @cImport({
    @cInclude("unistd.h");
});

pub const Error = std.mem.Allocator.Error || error{
    IoError,
};

pub const ReadStatus = union(enum) {
    progress: usize,
    would_block,
    eof,
};

pub const WriteStatus = union(enum) {
    progress: usize,
    would_block,
};

pub fn setNonBlocking(fd: c_int) Error!void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags < 0) return error.IoError;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if ((flags & nonblock) != 0) return;

    if (std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) != 0) {
        return error.IoError;
    }
}

pub fn readIntoQueue(
    allocator: std.mem.Allocator,
    fd: c_int,
    queue: *ByteQueue,
    max_bytes: usize,
) Error!ReadStatus {
    if (max_bytes == 0) return .{ .progress = 0 };

    try queue.ensureCapacity(allocator, max_bytes);

    const writable = queue.buf[queue.end .. queue.end + max_bytes];

    while (true) {
        const n = c.read(fd, writable.ptr, writable.len);
        if (n > 0) {
            queue.end += @intCast(n);
            return .{ .progress = @intCast(n) };
        }
        if (n == 0) return .eof;

        const e = std.posix.errno(-1);
        if (e == .INTR) continue;
        if (e == .AGAIN) return .would_block;
        return error.IoError;
    }
}

pub fn writeFromQueue(
    fd: c_int,
    queue: *ByteQueue,
    max_bytes: usize,
) Error!WriteStatus {
    if (queue.isEmpty() or max_bytes == 0) return .{ .progress = 0 };

    const readable = queue.readableSlice();
    const chunk = readable[0..@min(readable.len, max_bytes)];

    while (true) {
        const n = c.write(fd, chunk.ptr, chunk.len);
        if (n > 0) {
            queue.discard(@intCast(n));
            return .{ .progress = @intCast(n) };
        }
        if (n == 0) return .would_block;

        const e = std.posix.errno(-1);
        if (e == .INTR) continue;
        if (e == .AGAIN) return .would_block;
        return error.IoError;
    }
}
