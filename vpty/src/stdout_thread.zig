const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");
const StdoutActor = @import("stdout_actor").StdoutActor;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

pub const StdoutThread = struct {
    allocator: std.mem.Allocator,
    actor: StdoutActor,
    thread: ?std.Thread = null,
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_pipe: [2]c_int = .{ -1, -1 },

    pub fn init(allocator: std.mem.Allocator) StdoutThread {
        return .{
            .allocator = allocator,
            .actor = StdoutActor.init(allocator),
        };
    }

    pub fn deinit(self: *StdoutThread) void {
        self.actor.deinit();
    }

    pub fn start(self: *StdoutThread) !void {
        if (c.pipe(&self.wake_pipe) != 0) return error.IoError;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *StdoutThread) void {
        self.shutdown_requested.store(true, .seq_cst);
        self.wake();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.wake_pipe[0] >= 0) _ = c.close(self.wake_pipe[0]);
        if (self.wake_pipe[1] >= 0) _ = c.close(self.wake_pipe[1]);
        self.wake_pipe = .{ -1, -1 };
    }

    pub fn enqueueControl(self: *StdoutThread, chunk: actor_mailboxes.ControlChunk) !void {
        try self.actor.enqueueControl(chunk);
        self.wake();
    }

    pub fn publishRenderCandidate(self: *StdoutThread, publish: actor_mailboxes.RenderPublish) !void {
        try self.actor.publishRenderCandidate(publish);
        self.wake();
    }

    pub fn takeNewlyCommittedRenderVersion(self: *StdoutThread) ?actor_mailboxes.CommitNotice {
        return self.actor.takeNewlyCommittedRenderVersion();
    }

    pub fn committedRenderVersion(self: *const StdoutThread) u64 {
        return self.actor.committedRenderVersion();
    }

    pub fn pendingBytes(self: *const StdoutThread) usize {
        return self.actor.pendingBytes();
    }

    pub fn hasPending(self: *const StdoutThread) bool {
        return self.actor.hasPending();
    }

    fn wake(self: *StdoutThread) void {
        if (self.wake_pipe[1] >= 0) {
            const b: u8 = 1;
            _ = c.write(self.wake_pipe[1], &b, 1);
        }
    }

    fn drainWakePipe(self: *StdoutThread) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = c.read(self.wake_pipe[0], &buf, buf.len);
            if (n <= 0 or n < buf.len) break;
        }
    }

    fn run(self: *StdoutThread) void {
        while (true) {
            while (self.actor.hasPending()) {
                _ = self.actor.flushSome(64 * 1024) catch break;
            }

            if (self.shutdown_requested.load(.seq_cst) and !self.actor.hasPending()) break;

            var pfd = c.struct_pollfd{
                .fd = self.wake_pipe[0],
                .events = c.POLLIN,
                .revents = 0,
            };
            _ = c.poll(&pfd, 1, 50);
            if ((pfd.revents & c.POLLIN) != 0) {
                self.drainWakePipe();
            }
        }
    }
};
