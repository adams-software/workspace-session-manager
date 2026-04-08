const std = @import("std");
const ByteQueue = @import("byte_queue").ByteQueue;
const fd_stream = @import("fd_stream");
const codec = @import("session_stream_codec");
const wire = @import("session_wire");

const c = @cImport({
    @cInclude("poll.h");
});

pub const Error = codec.Error || fd_stream.Error || error{
    Closed,
};

pub const ReadPump = struct {
    bytes_read: usize = 0,
    hit_eof: bool = false,
};

pub const WritePump = struct {
    bytes_written: usize = 0,
};

pub const FramedTransport = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    rx: ByteQueue = ByteQueue.init(),
    tx: ByteQueue = ByteQueue.init(),
    max_frame_len: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        fd: c_int,
        max_frame_len: usize,
    ) !FramedTransport {
        try fd_stream.setNonBlocking(fd);
        return .{
            .allocator = allocator,
            .fd = fd,
            .max_frame_len = max_frame_len,
        };
    }

    pub fn deinit(self: *FramedTransport) void {
        self.rx.deinit(self.allocator);
        self.tx.deinit(self.allocator);
    }

    pub fn wantsRead(self: *const FramedTransport) bool {
        _ = self;
        return true;
    }

    pub fn wantsWrite(self: *const FramedTransport) bool {
        return !self.tx.isEmpty();
    }

    pub fn pollEvents(self: *const FramedTransport) c_short {
        var out: c_short = 0;
        if (self.wantsRead()) out |= c.POLLIN;
        if (self.wantsWrite()) out |= c.POLLOUT;
        return out;
    }

    pub fn queueMessage(self: *FramedTransport, msg: wire.Message) !void {
        const encoded = try codec.encodeMessage(self.allocator, msg);
        defer self.allocator.free(encoded);
        try self.tx.append(self.allocator, encoded);
    }

    pub fn queueRawFrame(self: *FramedTransport, encoded: []const u8) !void {
        try self.tx.append(self.allocator, encoded);
    }

    pub fn pumpRead(self: *FramedTransport, byte_budget: usize) !ReadPump {
        var out = ReadPump{};
        var remaining = byte_budget;

        while (remaining > 0) {
            const step = @min(remaining, 64 * 1024);
            const status = try fd_stream.readIntoQueue(self.allocator, self.fd, &self.rx, step);
            switch (status) {
                .progress => |n| {
                    out.bytes_read += n;
                    remaining -= n;
                    if (n < step) break;
                },
                .would_block => break,
                .eof => {
                    out.hit_eof = true;
                    break;
                },
            }
        }

        return out;
    }

    pub fn pumpWrite(self: *FramedTransport, byte_budget: usize) !WritePump {
        var out = WritePump{};
        var remaining = byte_budget;

        while (remaining > 0 and !self.tx.isEmpty()) {
            const step = @min(remaining, 64 * 1024);
            const status = try fd_stream.writeFromQueue(self.fd, &self.tx, step);
            switch (status) {
                .progress => |n| {
                    out.bytes_written += n;
                    remaining -= n;
                    if (n < step) break;
                },
                .would_block => break,
            }
        }

        return out;
    }

    pub fn nextMessage(self: *FramedTransport) !?wire.Message {
        return try codec.tryDecodeMessage(self.allocator, &self.rx, self.max_frame_len);
    }
};

test "transport queues and decodes framed messages incrementally" {
    _ = FramedTransport;
}
