const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");
const RenderActor = @import("vpty_render").RenderActor;
const TerminalModel = @import("terminal_model").TerminalModel;
const StdoutThread = @import("stdout_thread").StdoutThread;
const Io = std.Io;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

pub const SharedTerminalModel = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    model: TerminalModel,

    pub fn init(io: Io, model: TerminalModel) SharedTerminalModel {
        return .{ .io = io, .model = model };
    }

    pub fn lock(self: *SharedTerminalModel) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn unlock(self: *SharedTerminalModel) void {
        self.mutex.unlock(self.io);
    }
};

pub const RenderThread = struct {
    allocator: std.mem.Allocator,
    actor: RenderActor,
    stdout_thread: *StdoutThread,
    shared_model: *SharedTerminalModel,
    thread: ?std.Thread = null,
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_pipe: [2]c_int = .{ -1, -1 },

    pub fn init(allocator: std.mem.Allocator, shared_model: *SharedTerminalModel, stdout_thread: *StdoutThread) RenderThread {
        var actor = RenderActor{};
        actor.setTerminalModel(&shared_model.model);
        actor.setStdoutActor(stdout_thread);
        return .{
            .allocator = allocator,
            .actor = actor,
            .stdout_thread = stdout_thread,
            .shared_model = shared_model,
        };
    }

    pub fn deinit(self: *RenderThread) void {
        self.actor.deinit();
    }

    pub fn start(self: *RenderThread) !void {
        if (c.pipe(&self.wake_pipe) != 0) return error.IoError;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *RenderThread) void {
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

    pub fn publishModelChanged(self: *RenderThread, changed: actor_mailboxes.ModelChanged) void {
        self.actor.publishModelChanged(changed);
        self.wake();
    }

    pub fn noteCommitted(self: *RenderThread, notice: actor_mailboxes.CommitNotice) void {
        self.actor.noteCommitted(notice);
        self.wake();
    }

    pub fn reset(self: *RenderThread) void {
        self.actor.reset();
    }

    pub fn shutdownActor(self: *RenderThread) void {
        self.actor.shutdown();
    }

    fn wake(self: *RenderThread) void {
        if (self.wake_pipe[1] >= 0) {
            const b: u8 = 1;
            _ = c.write(self.wake_pipe[1], &b, 1);
        }
    }

    fn drainWakePipe(self: *RenderThread) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = c.read(self.wake_pipe[0], &buf, buf.len);
            if (n <= 0 or n < buf.len) break;
        }
    }

    fn run(self: *RenderThread) void {
        while (true) {
            if (self.actor.needs_render) {
                self.shared_model.mutex.lock();
                const captured = self.actor.takeSnapshot();
                self.shared_model.mutex.unlock();
                if (captured) |work| {
                    self.actor.renderSnapshot(work.version, work.snapshot);
                    continue;
                }
            }

            if (self.shutdown_requested.load(.seq_cst)) break;

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
