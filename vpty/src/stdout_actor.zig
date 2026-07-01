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

pub const StdoutBuffer = struct {
    allocator: std.mem.Allocator,
    control_queue: std.ArrayList(u8),
    control_offset: usize = 0,
    pending_render: ?RenderCandidate = null,
    deferred_render: ?RenderCandidate = null,
    committed_render_version: u64 = 0,
    newly_committed_render_version: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) StdoutBuffer {
        return .{
            .allocator = allocator,
            .control_queue = .empty,
        };
    }

    pub fn deinit(self: *StdoutBuffer) void {
        self.control_queue.deinit(self.allocator);
        if (self.pending_render) |*candidate| {
            candidate.storage.deinit(self.allocator);
        }
        if (self.deferred_render) |*candidate| {
            candidate.storage.deinit(self.allocator);
        }
    }

    pub fn enqueueControl(self: *StdoutBuffer, chunk: actor_mailboxes.ControlChunk) !void {
        try self.control_queue.appendSlice(self.allocator, chunk.bytes);
    }

    pub fn enqueueOwnedControl(self: *StdoutBuffer, bytes: []u8) !void {
        errdefer self.allocator.free(bytes);
        try self.control_queue.appendSlice(self.allocator, bytes);
        self.allocator.free(bytes);
    }

    pub fn publishRenderCandidate(self: *StdoutBuffer, publish: actor_mailboxes.RenderPublish) !void {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, publish.bytes);
        self.installRenderCandidate(.{
            .publish = .{ .version = publish.version, .bytes = buf.items, .final_cursor = publish.final_cursor },
            .storage = buf,
            .offset = 0,
        });
    }

    pub fn publishOwnedRenderCandidate(self: *StdoutBuffer, version: u64, bytes: []u8, final_cursor: actor_mailboxes.FinalCursor) void {
        self.installRenderCandidate(.{
            .publish = .{ .version = version, .bytes = bytes, .final_cursor = final_cursor },
            .storage = std.ArrayList(u8).fromOwnedSlice(bytes),
            .offset = 0,
        });
    }

    pub fn committedRenderVersion(self: *const StdoutBuffer) u64 {
        return self.committed_render_version;
    }

    pub fn takeNewlyCommittedRenderVersion(self: *StdoutBuffer) ?CommitNotice {
        const version = self.newly_committed_render_version;
        self.newly_committed_render_version = null;
        return if (version) |v| CommitNotice{ .version = v } else null;
    }

    pub fn hasPending(self: *const StdoutBuffer) bool {
        return self.control_offset < self.control_queue.items.len or self.pending_render != null;
    }

    pub fn pendingControlBytes(self: *const StdoutBuffer) usize {
        return if (self.control_offset < self.control_queue.items.len)
            self.control_queue.items.len - self.control_offset
        else
            0;
    }

    pub fn pendingRenderBytes(self: *const StdoutBuffer) usize {
        const render_pending = if (self.pending_render) |candidate|
            candidate.storage.items.len - candidate.offset
        else
            0;
        const deferred_pending = if (self.deferred_render) |candidate|
            candidate.storage.items.len - candidate.offset
        else
            0;
        return render_pending + deferred_pending;
    }

    pub fn pendingBytes(self: *const StdoutBuffer) usize {
        return self.pendingControlBytes() + self.pendingRenderBytes();
    }

    pub fn invalidatePendingRenders(self: *StdoutBuffer) void {
        if (self.pending_render) |*candidate| {
            candidate.storage.deinit(self.allocator);
            self.pending_render = null;
        }
        if (self.deferred_render) |*candidate| {
            candidate.storage.deinit(self.allocator);
            self.deferred_render = null;
        }
    }

    pub fn flushSome(self: *StdoutBuffer, max_bytes: usize) Error!FlushStatus {
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
                            const committed_version = candidate.publish.version;
                            candidate.storage.deinit(self.allocator);
                            self.pending_render = null;
                            self.committed_render_version = committed_version;
                            self.newly_committed_render_version = committed_version;
                            if (self.deferred_render) |deferred| {
                                self.pending_render = deferred;
                                self.deferred_render = null;
                            }
                        }
                    },
                }
                continue;
            }

            return if (total_written > 0) .{ .progress = total_written } else .done;
        }

        return if (total_written > 0) .{ .progress = total_written } else .would_block;
    }

    fn installRenderCandidate(self: *StdoutBuffer, candidate: RenderCandidate) void {
        if (self.pending_render) |*pending| {
            if (pending.offset > 0) {
                if (self.deferred_render) |*deferred| {
                    deferred.storage.deinit(self.allocator);
                }
                self.deferred_render = candidate;
                return;
            }

            pending.storage.deinit(self.allocator);
        }

        self.pending_render = candidate;
    }

    const WriteSomeStatus = union(enum) {
        written: usize,
        would_block,
    };

    fn writeSome(bytes: []const u8) Error!WriteSomeStatus {
        const n = c.write(c.STDOUT_FILENO, bytes.ptr, bytes.len);
        if (n > 0) return .{ .written = @intCast(n) };
        if (n == 0) return error.UnexpectedEof;

        const e = std.posix.errno(-1);
        if (e == .INTR) return writeSome(bytes);
        if (e == .AGAIN) return .would_block;
        return error.IoError;
    }
};

test "replaces unstarted render candidate atomically with newer render" {
    var buffer = StdoutBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    buffer.publishOwnedRenderCandidate(1, try std.testing.allocator.dupe(u8, "old"), .{ .visible = true, .row = 0, .col = 0 });
    buffer.publishOwnedRenderCandidate(2, try std.testing.allocator.dupe(u8, "new"), .{ .visible = true, .row = 0, .col = 0 });

    try std.testing.expect(buffer.pending_render != null);
    try std.testing.expectEqual(@as(u64, 2), buffer.pending_render.?.publish.version);
    try std.testing.expectEqualStrings("new", buffer.pending_render.?.storage.items);
    try std.testing.expect(buffer.deferred_render == null);
}

test "started render candidate defers newer render until current batch completes" {
    var buffer = StdoutBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    buffer.publishOwnedRenderCandidate(1, try std.testing.allocator.dupe(u8, "first"), .{ .visible = true, .row = 0, .col = 0 });
    buffer.pending_render.?.offset = 2;
    buffer.publishOwnedRenderCandidate(2, try std.testing.allocator.dupe(u8, "second"), .{ .visible = true, .row = 0, .col = 0 });

    try std.testing.expect(buffer.pending_render != null);
    try std.testing.expectEqual(@as(u64, 1), buffer.pending_render.?.publish.version);
    try std.testing.expectEqual(@as(usize, 2), buffer.pending_render.?.offset);
    try std.testing.expect(buffer.deferred_render != null);
    try std.testing.expectEqual(@as(u64, 2), buffer.deferred_render.?.publish.version);
    try std.testing.expectEqualStrings("second", buffer.deferred_render.?.storage.items);
}

test "pending byte categories keep control separate from render backlog" {
    var buffer = StdoutBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.enqueueControl(.{ .bytes = "osc52" });
    buffer.publishOwnedRenderCandidate(1, try std.testing.allocator.dupe(u8, "frame"), .{
        .visible = true,
        .row = 0,
        .col = 0,
    });

    try std.testing.expectEqual(@as(usize, 5), buffer.pendingControlBytes());
    try std.testing.expectEqual(@as(usize, 5), buffer.pendingRenderBytes());
    try std.testing.expectEqual(@as(usize, 10), buffer.pendingBytes());
}
