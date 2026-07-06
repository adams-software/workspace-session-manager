const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");
const StdoutBuffer = @import("stdout_actor").StdoutBuffer;
const WakePipe = @import("wake_pipe").WakePipe;
const c = @cImport({
    @cInclude("poll.h");
});

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

const OwnedControlChunk = struct {
    bytes: []u8,
};

const OwnedRenderPublish = struct {
    version: u64,
    bytes: []u8,
    final_cursor: actor_mailboxes.FinalCursor,
};

const SharedState = struct {
    committed_render_version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pending_control_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    pending_render_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    latest_commit_notice: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub const StdoutThread = struct {
    allocator: std.mem.Allocator,
    buffer: StdoutBuffer,
    control_queue: actor_mailboxes.MutexQueue(OwnedControlChunk),
    render_mutex: SpinMutex = .{},
    pending_render_publish: ?OwnedRenderPublish = null,
    shared: SharedState = .{},
    thread: ?std.Thread = null,
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_pipe: WakePipe = .{},

    pub fn init(allocator: std.mem.Allocator, io: anytype) StdoutThread {
        return .{
            .allocator = allocator,
            .buffer = StdoutBuffer.init(allocator),
            .control_queue = actor_mailboxes.MutexQueue(OwnedControlChunk).init(allocator, io),
        };
    }

    pub fn deinit(self: *StdoutThread) void {
        while (self.control_queue.pop()) |chunk| self.allocator.free(chunk.bytes);
        self.control_queue.deinit();
        if (self.pending_render_publish) |publish| {
            self.allocator.free(publish.bytes);
            self.pending_render_publish = null;
        }
        self.buffer.deinit();
    }

    pub fn start(self: *StdoutThread) !void {
        self.wake_pipe = try WakePipe.init();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *StdoutThread) void {
        self.shutdown_requested.store(true, .seq_cst);
        self.wake();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.wake_pipe.deinit();
    }

    pub fn stopDiscardPending(self: *StdoutThread) void {
        self.render_mutex.lock();
        if (self.pending_render_publish) |publish| {
            _ = self.shared.pending_render_bytes.fetchSub(publish.bytes.len, .seq_cst);
            self.allocator.free(publish.bytes);
            self.pending_render_publish = null;
        }
        self.render_mutex.unlock();

        const before = self.buffer.pendingRenderBytes();
        self.buffer.invalidatePendingRenders();
        const after = self.buffer.pendingRenderBytes();
        if (before > after) {
            _ = self.shared.pending_render_bytes.fetchSub(before - after, .seq_cst);
        }
        _ = self.shared.latest_commit_notice.swap(0, .seq_cst);

        self.shutdown_requested.store(true, .seq_cst);
        self.wake();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.wake_pipe.deinit();
    }

    pub fn enqueueControl(self: *StdoutThread, chunk: actor_mailboxes.ControlChunk) !void {
        const owned = try self.allocator.dupe(u8, chunk.bytes);
        errdefer self.allocator.free(owned);
        try self.control_queue.push(.{ .bytes = owned });
        _ = self.shared.pending_control_bytes.fetchAdd(owned.len, .seq_cst);
        self.wake();
    }

    pub fn publishRenderCandidate(self: *StdoutThread, publish: actor_mailboxes.RenderPublish) !void {
        const owned = try self.allocator.dupe(u8, publish.bytes);
        self.render_mutex.lock();
        defer self.render_mutex.unlock();

        if (self.pending_render_publish) |previous| {
            _ = self.shared.pending_render_bytes.fetchSub(previous.bytes.len, .seq_cst);
            self.allocator.free(previous.bytes);
        }
        self.pending_render_publish = .{ .version = publish.version, .bytes = owned, .final_cursor = publish.final_cursor };
        _ = self.shared.pending_render_bytes.fetchAdd(owned.len, .seq_cst);
        self.wake();
    }

    pub fn invalidatePendingRenders(self: *StdoutThread) void {
        self.render_mutex.lock();
        defer self.render_mutex.unlock();

        if (self.pending_render_publish) |publish| {
            _ = self.shared.pending_render_bytes.fetchSub(publish.bytes.len, .seq_cst);
            self.allocator.free(publish.bytes);
            self.pending_render_publish = null;
        }

        const before = self.buffer.pendingRenderBytes();
        self.buffer.invalidatePendingRenders();
        const after = self.buffer.pendingRenderBytes();
        if (before > after) {
            _ = self.shared.pending_render_bytes.fetchSub(before - after, .seq_cst);
        }
        _ = self.shared.latest_commit_notice.swap(0, .seq_cst);
        self.wake();
    }

    pub fn takeNewlyCommittedRenderVersion(self: *StdoutThread) ?actor_mailboxes.CommitNotice {
        const version = self.shared.latest_commit_notice.swap(0, .seq_cst);
        return if (version == 0) null else .{ .version = version };
    }

    pub fn committedRenderVersion(self: *const StdoutThread) u64 {
        return self.shared.committed_render_version.load(.seq_cst);
    }

    pub fn pendingBytes(self: *const StdoutThread) usize {
        return self.pendingControlBytes() + self.pendingRenderBytes();
    }

    pub fn pendingControlBytes(self: *const StdoutThread) usize {
        return self.shared.pending_control_bytes.load(.seq_cst);
    }

    pub fn pendingRenderBytes(self: *const StdoutThread) usize {
        return self.shared.pending_render_bytes.load(.seq_cst);
    }

    pub fn hasPending(self: *const StdoutThread) bool {
        return self.pendingBytes() > 0;
    }

    fn wake(self: *StdoutThread) void {
        self.wake_pipe.notify();
    }

    fn drainWakePipe(self: *StdoutThread) void {
        self.wake_pipe.drain();
    }

    fn run(self: *StdoutThread) void {
        while (true) {
            self.drainInbound();
            var stdout_blocked = false;
            while (self.buffer.hasPending()) {
                const before_control = self.buffer.pendingControlBytes();
                const before_render = self.buffer.pendingRenderBytes();
                const status = self.buffer.flushSome(64 * 1024) catch break;
                const after_control = self.buffer.pendingControlBytes();
                const after_render = self.buffer.pendingRenderBytes();
                if (before_control > after_control) {
                    _ = self.shared.pending_control_bytes.fetchSub(before_control - after_control, .seq_cst);
                }
                if (before_render > after_render) {
                    _ = self.shared.pending_render_bytes.fetchSub(before_render - after_render, .seq_cst);
                }
                const committed = self.buffer.takeNewlyCommittedRenderVersion();
                if (committed) |notice| {
                    self.shared.committed_render_version.store(notice.version, .seq_cst);
                    _ = self.shared.latest_commit_notice.swap(notice.version, .seq_cst);
                }

                switch (status) {
                    .would_block => {
                        stdout_blocked = true;
                        break;
                    },
                    .done => break,
                    .progress => {},
                }
            }

            if (self.shutdown_requested.load(.seq_cst) and !self.hasPending()) break;

            var pfds = [2]c.struct_pollfd{
                .{
                    .fd = self.wake_pipe.readFd(),
                    .events = c.POLLIN,
                    .revents = 0,
                },
                .{
                    .fd = if (stdout_blocked and self.hasPending()) std.posix.STDOUT_FILENO else -1,
                    .events = if (stdout_blocked and self.hasPending()) c.POLLOUT else 0,
                    .revents = 0,
                },
            };
            _ = c.poll(&pfds, pfds.len, 50);
            if ((pfds[0].revents & c.POLLIN) != 0) {
                self.drainWakePipe();
            }
        }
    }

    fn drainInbound(self: *StdoutThread) void {
        while (self.control_queue.pop()) |chunk| {
            self.buffer.enqueueOwnedControl(chunk.bytes) catch {
                _ = self.shared.pending_control_bytes.fetchSub(chunk.bytes.len, .seq_cst);
                self.allocator.free(chunk.bytes);
                break;
            };
        }

        self.render_mutex.lock();
        const publish = self.pending_render_publish;
        self.pending_render_publish = null;
        self.render_mutex.unlock();

        if (publish) |owned| {
            _ = self.shared.pending_render_bytes.fetchSub(owned.bytes.len, .seq_cst);
            const before = self.buffer.pendingRenderBytes();
            self.buffer.publishOwnedRenderCandidate(owned.version, owned.bytes, owned.final_cursor);
            const after = self.buffer.pendingRenderBytes();
            if (after > before) {
                _ = self.shared.pending_render_bytes.fetchAdd(after - before, .seq_cst);
            } else if (before > after) {
                _ = self.shared.pending_render_bytes.fetchSub(before - after, .seq_cst);
            }
        }
    }
};
