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

const MAX_RENDER_DEFERRALS = 8;

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
    deferred_iterations: usize = 0,
    force_render: bool = false,
    thread: ?std.Thread = null,
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_pipe: [2]c_int = .{ -1, -1 },

    pub fn init(allocator: std.mem.Allocator, shared_model: *SharedTerminalModel, stdout_thread: *StdoutThread) RenderThread {
        return .{
            .allocator = allocator,
            .actor = RenderActor.init(stdout_thread),
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

    fn syncCommittedVersion(self: *RenderThread) void {
        self.actor.noteCommitted(.{ .version = self.stdout_thread.committedRenderVersion() });
    }

    pub fn reset(self: *RenderThread) void {
        self.actor.reset();
        self.deferred_iterations = 0;
        self.force_render = false;
        self.wake();
    }

    pub fn forceNextRender(self: *RenderThread) void {
        self.force_render = true;
    }

    pub fn considerRender(self: *RenderThread, transport_has_heavy_backlog: bool, stdout_has_heavy_backlog: bool) void {
        const model_version = self.currentVersion();
        if (model_version <= self.stdout_thread.committedRenderVersion()) return;
        if (stdout_has_heavy_backlog) return;
        if (!self.force_render and transport_has_heavy_backlog and self.deferred_iterations < MAX_RENDER_DEFERRALS) {
            self.deferred_iterations += 1;
            return;
        }

        self.actor.renderDamaged();
        self.deferred_iterations = 0;
        self.force_render = false;
        self.wake();
    }

    pub fn shutdownActor(self: *RenderThread) void {
        self.actor.shutdown(self.currentVersion());
        self.wake();
    }

    pub fn currentVersion(self: *RenderThread) u64 {
        self.shared_model.lock();
        defer self.shared_model.unlock();
        return self.shared_model.model.currentVersion();
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
            self.syncCommittedVersion();

            if (self.actor.needsRender()) {
                self.shared_model.lock();
                const captured = self.actor.takeSnapshot(&self.shared_model.model);
                self.shared_model.unlock();
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
