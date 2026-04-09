const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");
const c = @cImport({
    @cInclude("unistd.h");
});

pub const Error = error{
    IoError,
    UnexpectedEof,
};

pub const CommitNotice = actor_mailboxes.CommitNotice;

pub const FlushStatus = union(enum) {
    progress: usize,
    would_block,
    done,
};

pub const RenderCandidate = struct {
    publish: actor_mailboxes.RenderPublish,
    storage: std.ArrayList(u8),
    offset: usize = 0,
};

pub const StdoutActor = struct {
    allocator: std.mem.Allocator,
    control_queue: std.ArrayList(u8),
    control_offset: usize = 0,
    pending_render: ?RenderCandidate = null,
    committed_render_version: u64 = 0,
    newly_committed_render_version: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) StdoutActor {
        return .{
            .allocator = allocator,
            .control_queue = .{},
        };
    }

    pub fn deinit(self: *StdoutActor) void {
        self.control_queue.deinit(self.allocator);
        if (self.pending_render) |*candidate| {
            candidate.storage.deinit(self.allocator);
        }
    }

    pub fn enqueueControl(self: *StdoutActor, chunk: actor_mailboxes.ControlChunk) !void {
        try self.control_queue.appendSlice(self.allocator, chunk.bytes);
    }

    pub fn publishRenderCandidate(self: *StdoutActor, publish: actor_mailboxes.RenderPublish) !void {
        if (self.pending_render) |*candidate| {
            candidate.storage.deinit(self.allocator);
        }

        var buf = std.ArrayList(u8){};
        try buf.appendSlice(self.allocator, publish.bytes);
        self.pending_render = .{
            .publish = .{ .version = publish.version, .bytes = buf.items },
            .storage = buf,
            .offset = 0,
        };
    }

    pub fn committedRenderVersion(self: *const StdoutActor) u64 {
        return self.committed_render_version;
    }

    pub fn takeNewlyCommittedRenderVersion(self: *StdoutActor) ?CommitNotice {
        const version = self.newly_committed_render_version;
        self.newly_committed_render_version = null;
        return if (version) |v| CommitNotice{ .version = v } else null;
    }

    pub fn hasPending(self: *const StdoutActor) bool {
        return self.control_offset < self.control_queue.items.len or self.pending_render != null;
    }

    pub fn pendingBytes(self: *const StdoutActor) usize {
        const control_pending = if (self.control_offset < self.control_queue.items.len)
            self.control_queue.items.len - self.control_offset
        else
            0;
        const render_pending = if (self.pending_render) |candidate|
            candidate.storage.items.len - candidate.offset
        else
            0;
        return control_pending + render_pending;
    }

    pub fn flushSome(self: *StdoutActor, max_bytes: usize) Error!FlushStatus {
        var total_written: usize = 0;

        while (total_written < max_bytes) {
            if (self.control_offset < self.control_queue.items.len) {
                const remaining = self.control_queue.items[self.control_offset..];
                const chunk = remaining[0..@min(remaining.len, max_bytes - total_written)];
                const n = try writeSome(chunk);
                switch (n) {
                    .would_block => return if (total_written > 0) .{ .progress = total_written } else .would_block,
                    .written => |written| {
                        total_written += written;
                        self.control_offset += written;
                        if (self.control_offset == self.control_queue.items.len) {
                            self.control_queue.clearRetainingCapacity();
                            self.control_offset = 0;
                        }
                    },
                }
                continue;
            }

            if (self.pending_render) |*candidate| {
                const remaining = candidate.storage.items[candidate.offset..];
                const chunk = remaining[0..@min(remaining.len, max_bytes - total_written)];
                const n = try writeSome(chunk);
                switch (n) {
                    .would_block => return if (total_written > 0) .{ .progress = total_written } else .would_block,
                    .written => |written| {
                        total_written += written;
                        candidate.offset += written;
                        if (candidate.offset == candidate.storage.items.len) {
                            self.committed_render_version = candidate.publish.version;
                            self.newly_committed_render_version = candidate.publish.version;
                            candidate.storage.deinit(self.allocator);
                            self.pending_render = null;
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
