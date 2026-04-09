const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
});

pub const Error = error{
    IoError,
    UnexpectedEof,
};

pub const FlushStatus = union(enum) {
    progress: usize,
    would_block,
    done,
};

pub const OutputSink = struct {
    allocator: std.mem.Allocator,

    control_buf: std.ArrayList(u8),
    control_offset: usize = 0,

    render_buf: std.ArrayList(u8),
    render_offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator) OutputSink {
        return .{
            .allocator = allocator,
            .control_buf = .{},
            .render_buf = .{},
        };
    }

    pub fn deinit(self: *OutputSink) void {
        self.control_buf.deinit(self.allocator);
        self.render_buf.deinit(self.allocator);
    }

    pub fn appendControl(self: *OutputSink, bytes: []const u8) !void {
        try self.control_buf.appendSlice(self.allocator, bytes);
    }

    pub fn replaceRender(self: *OutputSink, bytes: []const u8) !void {
        self.render_buf.clearRetainingCapacity();
        self.render_offset = 0;
        try self.render_buf.appendSlice(self.allocator, bytes);
    }

    pub fn hasPending(self: *const OutputSink) bool {
        return self.pendingBytes() > 0;
    }

    pub fn pendingBytes(self: *const OutputSink) usize {
        const control_pending = if (self.control_offset < self.control_buf.items.len)
            self.control_buf.items.len - self.control_offset
        else
            0;
        const render_pending = if (self.render_offset < self.render_buf.items.len)
            self.render_buf.items.len - self.render_offset
        else
            0;
        return control_pending + render_pending;
    }

    pub fn flushSome(self: *OutputSink, max_bytes: usize) Error!FlushStatus {
        var total_written: usize = 0;

        while (total_written < max_bytes) {
            if (self.control_offset < self.control_buf.items.len) {
                const remaining = self.control_buf.items[self.control_offset..];
                const chunk = remaining[0..@min(remaining.len, max_bytes - total_written)];
                const n = try writeSome(chunk);
                switch (n) {
                    .would_block => return if (total_written > 0) .{ .progress = total_written } else .would_block,
                    .written => |written| {
                        total_written += written;
                        self.control_offset += written;
                        if (self.control_offset == self.control_buf.items.len) {
                            self.control_buf.clearRetainingCapacity();
                            self.control_offset = 0;
                        }
                    },
                }
                continue;
            }

            if (self.render_offset < self.render_buf.items.len) {
                const remaining = self.render_buf.items[self.render_offset..];
                const chunk = remaining[0..@min(remaining.len, max_bytes - total_written)];
                const n = try writeSome(chunk);
                switch (n) {
                    .would_block => return if (total_written > 0) .{ .progress = total_written } else .would_block,
                    .written => |written| {
                        total_written += written;
                        self.render_offset += written;
                        if (self.render_offset == self.render_buf.items.len) {
                            self.render_buf.clearRetainingCapacity();
                            self.render_offset = 0;
                        }
                    },
                }
                continue;
            }

            return if (total_written > 0) .{ .progress = total_written } else .done;
        }

        return if (total_written > 0) .{ .progress = total_written } else .would_block;
    }

    const WriteSomeStatus = union(enum) {
        written: usize,
        would_block,
    };

    fn writeSome(bytes: []const u8) Error!WriteSomeStatus {
        const n = c.write(c.STDOUT_FILENO, bytes.ptr, bytes.len);
        if (n > 0) return .{ .written = @intCast(n) };
        if (n == 0) return error.UnexpectedEof;

        const e = std.c.errno(-1);
        if (e == .INTR) return writeSome(bytes);
        if (e == .AGAIN) return .would_block;
        return error.IoError;
    }
};
