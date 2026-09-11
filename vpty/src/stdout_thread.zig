const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");
const StdoutBuffer = @import("stdout_actor").StdoutBuffer;
const WakePipe = @import("wake_pipe").WakePipe;
const c = @cImport({
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
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
    const SHUTDOWN_DRAIN_MS = 250;

    allocator: std.mem.Allocator,
    buffer: StdoutBuffer,
    control_queue: actor_mailboxes.MutexQueue(OwnedControlChunk),
    render_mutex: SpinMutex = .{},
    pending_render_publish: ?OwnedRenderPublish = null,
    shared: SharedState = .{},
    thread: ?std.Thread = null,
    shutdown_deadline_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    output_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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
        errdefer self.wake_pipe.deinit();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *StdoutThread) void {
        self.shutdown_deadline_ms.store((monotonicMs() orelse 0) +| SHUTDOWN_DRAIN_MS, .seq_cst);
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

        const before = self.buffer.pendingRenderBytes();
        self.buffer.invalidatePendingRenders();
        const after = self.buffer.pendingRenderBytes();
        if (before > after) {
            _ = self.shared.pending_render_bytes.fetchSub(before - after, .seq_cst);
        }
        _ = self.shared.latest_commit_notice.swap(0, .seq_cst);
        self.render_mutex.unlock();

        self.stop();
    }

    fn monotonicMs() ?u64 {
        var now: c.timespec = undefined;
        if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) != 0) return null;
        return @as(u64, @intCast(now.tv_sec)) * 1000 + @as(u64, @intCast(now.tv_nsec)) / std.time.ns_per_ms;
    }

    fn shutdownTimedOut(self: *const StdoutThread) bool {
        if (!self.shutdown_requested.load(.seq_cst)) return false;
        const now = monotonicMs() orelse return true;
        return now >= self.shutdown_deadline_ms.load(.seq_cst);
    }

    pub fn enqueueControl(self: *StdoutThread, chunk: actor_mailboxes.ControlChunk) !void {
        const owned = try self.allocator.dupe(u8, chunk.bytes);
        errdefer self.allocator.free(owned);
        // Account before publication: the consumer may immediately drain the chunk.
        _ = self.shared.pending_control_bytes.fetchAdd(owned.len, .seq_cst);
        errdefer _ = self.shared.pending_control_bytes.fetchSub(owned.len, .seq_cst);
        try self.control_queue.push(.{ .bytes = owned });
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
            if (self.shutdownTimedOut()) return;
            self.drainInbound();
            var stdout_blocked = false;
            while (true) {
                if (self.shutdownTimedOut()) return;
                self.render_mutex.lock();
                const has_pending = self.buffer.hasPending();
                if (!has_pending) {
                    self.render_mutex.unlock();
                    break;
                }
                const before_control = self.buffer.pendingControlBytes();
                const before_render = self.buffer.pendingRenderBytes();
                const status = self.buffer.flushSome(64 * 1024) catch {
                    self.render_mutex.unlock();
                    self.output_failed.store(true, .seq_cst);
                    return;
                };
                const after_control = self.buffer.pendingControlBytes();
                const after_render = self.buffer.pendingRenderBytes();
                const committed = self.buffer.takeNewlyCommittedRenderVersion();
                self.render_mutex.unlock();

                if (before_control > after_control) {
                    _ = self.shared.pending_control_bytes.fetchSub(before_control - after_control, .seq_cst);
                }
                if (before_render > after_render) {
                    _ = self.shared.pending_render_bytes.fetchSub(before_render - after_render, .seq_cst);
                }
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
            _ = std.c.poll(@ptrCast(&pfds), pfds.len, 50);
            if ((pfds[0].revents & c.POLLIN) != 0) {
                self.drainWakePipe();
            }
        }
    }

    fn drainInbound(self: *StdoutThread) void {
        while (!self.shutdownTimedOut()) {
            const chunk = self.control_queue.pop() orelse break;
            self.render_mutex.lock();
            self.buffer.enqueueOwnedControl(chunk.bytes) catch {
                self.render_mutex.unlock();
                _ = self.shared.pending_control_bytes.fetchSub(chunk.bytes.len, .seq_cst);
                // enqueueOwnedControl consumes ownership even when allocation fails.
                break;
            };
            self.render_mutex.unlock();
        }

        self.render_mutex.lock();
        const publish = self.pending_render_publish;
        self.pending_render_publish = null;
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
        self.render_mutex.unlock();
    }
};

test "control byte accounting precedes mailbox publication" {
    const ObservingAllocator = struct {
        owner: *StdoutThread,
        observed: ?usize = null,

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // Mailbox growth happens inside push, before the item becomes visible.
            self.observed = self.owner.pendingControlBytes();
            return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
        }

        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ret_addr);
        }
    };
    var worker = StdoutThread.init(std.testing.allocator, {});
    defer worker.deinit();
    var observer = ObservingAllocator{ .owner = &worker };
    worker.control_queue.allocator = .{ .ptr = &observer, .vtable = &.{
        .alloc = ObservingAllocator.alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = ObservingAllocator.free,
    } };
    var bytes = "control".*;
    try worker.enqueueControl(.{ .bytes = &bytes });
    try std.testing.expectEqual(@as(?usize, bytes.len), observer.observed);
    const chunk = worker.control_queue.pop().?;
    defer std.testing.allocator.free(chunk.bytes);
    const before = worker.shared.pending_control_bytes.fetchSub(chunk.bytes.len, .seq_cst);
    try std.testing.expectEqual(bytes.len, before);
    try std.testing.expectEqual(@as(usize, 0), worker.pendingControlBytes());
}

test "failed control publication restores pending byte accounting" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var worker = StdoutThread.init(allocator, {});
            defer worker.deinit();
            var bytes = "control".*;
            worker.enqueueControl(.{ .bytes = &bytes }) catch |err| {
                try std.testing.expectEqual(@as(usize, 0), worker.pendingControlBytes());
                try std.testing.expectEqual(@as(usize, 0), worker.control_queue.len());
                return err;
            };
            try std.testing.expectEqual(bytes.len, worker.pendingControlBytes());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});

    var worker = StdoutThread.init(std.testing.allocator, {});
    defer worker.deinit();
    var bytes = "queued".*;
    try worker.enqueueControl(.{ .bytes = &bytes });
    worker.control_queue.close();
    try std.testing.expectError(error.Closed, worker.enqueueControl(.{ .bytes = &bytes }));
    try std.testing.expectEqual(bytes.len, worker.pendingControlBytes());
    try std.testing.expectEqual(@as(usize, 1), worker.control_queue.len());
}

test "control buffer allocation failure frees the rejected chunk once and preserves queued work" {
    var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var worker = StdoutThread.init(allocations.allocator(), {});
    defer worker.deinit();
    var first = "first".*;
    var second = "second".*;
    try worker.enqueueControl(.{ .bytes = &first });
    try worker.enqueueControl(.{ .bytes = &second });

    // The next allocation grows the consumer's buffer after it pops the first chunk.
    allocations.fail_index = allocations.alloc_index;
    worker.drainInbound();
    try std.testing.expect(allocations.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), worker.control_queue.len());
    try std.testing.expectEqual(second.len, worker.pendingControlBytes());
    try std.testing.expectEqual(@as(usize, 0), worker.buffer.pendingControlBytes());

    allocations.fail_index = std.math.maxInt(usize);
    worker.drainInbound();
    try std.testing.expectEqual(@as(usize, 0), worker.control_queue.len());
    try std.testing.expectEqual(second.len, worker.pendingControlBytes());
    try std.testing.expectEqualStrings(&second, worker.buffer.control_queue.items);
}

test "permanent stdout failure stops the worker with pending controls" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    const saved_stdout = c.dup(c.STDOUT_FILENO);
    try std.testing.expect(saved_stdout >= 0);
    defer _ = c.close(saved_stdout);
    // A read-only pipe end reliably produces EBADF without delivering SIGPIPE.
    try std.testing.expectEqual(@as(c_int, 1), c.dup2(fds[0], c.STDOUT_FILENO));
    defer _ = c.dup2(saved_stdout, c.STDOUT_FILENO);
    var worker = StdoutThread.init(std.testing.allocator, {});
    defer worker.deinit();
    var control = "queued control".*;
    try worker.enqueueControl(.{ .bytes = &control });
    try worker.start();
    defer {
        // Restore a writable sink before joining even if the assertion fails.
        _ = c.dup2(fds[1], c.STDOUT_FILENO);
        worker.stop();
    }
    var attempts: usize = 0;
    const delay = c.timespec{ .tv_sec = 0, .tv_nsec = 1_000_000 };
    while (!worker.output_failed.load(.seq_cst) and attempts < 2000) : (attempts += 1) {
        _ = c.nanosleep(&delay, null);
    }
    try std.testing.expect(worker.output_failed.load(.seq_cst));
    worker.stop(); // Must join despite the undeliverable bytes still being owned.
    try std.testing.expect(worker.thread == null);
    try std.testing.expectEqual(control.len, worker.pendingControlBytes());
}

fn testShutdownDrain(discard_renders: bool, resume_reader: bool) !void {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    const saved_stdout = c.dup(c.STDOUT_FILENO);
    try std.testing.expect(saved_stdout >= 0);
    defer _ = c.close(saved_stdout);
    try std.testing.expectEqual(@as(c_int, 1), c.dup2(fds[1], c.STDOUT_FILENO));
    defer _ = c.dup2(saved_stdout, c.STDOUT_FILENO);

    // Keep the reader connected but fill its pipe until writes would block.
    const padding: [4096]u8 = @splat('x');
    while (c.write(fds[1], &padding, padding.len) > 0) {}
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(-1));
    var worker = StdoutThread.init(std.testing.allocator, {});
    defer worker.deinit();
    var control = "final control".*;
    try worker.enqueueControl(.{ .bytes = &control });
    try worker.start();
    defer worker.stop();

    const Reader = struct {
        fd: c_int,
        delay_ms: u64,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            const start = StdoutThread.monotonicMs().?;
            const pause = c.timespec{ .tv_sec = 0, .tv_nsec = 1_000_000 };
            while (!self.done.load(.seq_cst)) {
                if (StdoutThread.monotonicMs().? - start >= self.delay_ms) {
                    // One read frees enough room for the queued control. In the
                    // stalled case this is a watchdog so regressions don't hang.
                    var bytes: [4096]u8 = undefined;
                    _ = c.read(self.fd, &bytes, bytes.len);
                    return;
                }
                _ = c.nanosleep(&pause, null);
            }
        }
    };
    var reader = Reader{ .fd = fds[0], .delay_ms = if (resume_reader) 50 else 2000 };
    const reader_thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    defer {
        reader.done.store(true, .seq_cst);
        reader_thread.join();
    }
    const start = StdoutThread.monotonicMs().?;
    if (discard_renders) worker.stopDiscardPending() else worker.stop();
    const elapsed = StdoutThread.monotonicMs().? - start;
    try std.testing.expect(elapsed < 1000);
    try std.testing.expect(worker.thread == null);
    try std.testing.expect(!worker.output_failed.load(.seq_cst));
    if (resume_reader) {
        try std.testing.expectEqual(@as(usize, 0), worker.pendingControlBytes());
        var tail: [13]u8 = @splat(0);
        var byte: u8 = undefined;
        while (c.read(fds[0], &byte, 1) == 1) {
            std.mem.copyForwards(u8, tail[0 .. tail.len - 1], tail[1..]);
            tail[tail.len - 1] = byte;
        }
        try std.testing.expectEqualStrings(&control, &tail);
    } else {
        try std.testing.expect(elapsed >= 200);
        try std.testing.expectEqual(control.len, worker.pendingControlBytes());
    }
}

test "shutdown abandons undeliverable output after a bounded drain window" {
    for ([_]bool{ false, true }) |discard_renders| try testShutdownDrain(discard_renders, false);
}

test "shutdown delivers pending controls when stdout resumes during the drain window" {
    for ([_]bool{ false, true }) |discard_renders| try testShutdownDrain(discard_renders, true);
}
