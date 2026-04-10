const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");
const Renderer = @import("vpty_render").Renderer;
const TerminalModel = @import("terminal_model").TerminalModel;
const StdoutThread = @import("stdout_thread").StdoutThread;
const WakePipe = @import("wake_pipe").WakePipe;
const Io = std.Io;
const c = @cImport({
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
    const PendingBatch = struct {
        latest_model_changed: ?actor_mailboxes.ModelChanged = null,
        reset_requested: bool = false,
        shutdown_requested: bool = false,
    };

    const PendingRequests = struct {
        mutex: Io.Mutex = .init,
        batch: PendingBatch = .{},
    };

    allocator: std.mem.Allocator,
    renderer: Renderer,
    stdout_thread: *StdoutThread,
    shared_model: *SharedTerminalModel,
    pending: PendingRequests = .{},
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_pipe: WakePipe = .{},

    pub fn init(allocator: std.mem.Allocator, shared_model: *SharedTerminalModel, stdout_thread: *StdoutThread) RenderThread {
        return .{
            .allocator = allocator,
            .renderer = Renderer.init(stdout_thread),
            .stdout_thread = stdout_thread,
            .shared_model = shared_model,
        };
    }

    pub fn deinit(self: *RenderThread) void {
        self.renderer.deinit();
        _ = self.allocator;
    }

    pub fn start(self: *RenderThread) !void {
        self.wake_pipe = try WakePipe.init();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *RenderThread) void {
        self.stop_requested.store(true, .seq_cst);
        self.wake();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.wake_pipe.deinit();
    }

    pub fn publishModelChanged(self: *RenderThread, changed: actor_mailboxes.ModelChanged) void {
        self.pending.mutex.lockUncancelable(self.shared_model.io);
        self.pending.batch.latest_model_changed = changed;
        self.pending.mutex.unlock(self.shared_model.io);
        self.wake();
    }

    pub fn reset(self: *RenderThread) void {
        self.pending.mutex.lockUncancelable(self.shared_model.io);
        self.pending.batch.reset_requested = true;
        self.pending.mutex.unlock(self.shared_model.io);
        self.wake();
    }

    pub fn shutdownActor(self: *RenderThread) void {
        self.pending.mutex.lockUncancelable(self.shared_model.io);
        self.pending.batch.shutdown_requested = true;
        self.pending.mutex.unlock(self.shared_model.io);
        self.wake();
    }

    fn currentVersion(self: *RenderThread) u64 {
        self.shared_model.lock();
        defer self.shared_model.unlock();
        return self.shared_model.model.currentVersion();
    }

    fn syncCommittedVersion(self: *RenderThread) void {
        self.renderer.noteCommitted(.{ .version = self.stdout_thread.committedRenderVersion() });
    }

    fn wake(self: *RenderThread) void {
        self.wake_pipe.notify();
    }

    fn takePendingRequests(self: *RenderThread) PendingBatch {
        self.pending.mutex.lockUncancelable(self.shared_model.io);
        defer self.pending.mutex.unlock(self.shared_model.io);

        const pending = self.pending.batch;
        self.pending.batch = .{};
        return pending;
    }

    fn applyPendingRequests(self: *RenderThread) void {
        const pending = self.takePendingRequests();

        if (pending.reset_requested) {
            self.renderer.reset();
        }
        if (pending.latest_model_changed) |changed| {
            self.renderer.publishModelChanged(changed);
        }
        if (pending.shutdown_requested) {
            self.renderer.shutdown(self.currentVersion());
        }
    }

    fn drainWakePipe(self: *RenderThread) void {
        self.wake_pipe.drain();
    }

    fn run(self: *RenderThread) void {
        while (true) {
            self.syncCommittedVersion();
            self.applyPendingRequests();

            if (self.renderer.needsRender()) {
                self.shared_model.lock();
                const captured = self.renderer.takeSnapshot(&self.shared_model.model);
                self.shared_model.unlock();
                if (captured) |work| {
                    self.renderer.renderSnapshot(work.version, work.snapshot);
                    continue;
                }
            }

            if (self.stop_requested.load(.seq_cst)) break;

            var pfd = c.struct_pollfd{
                .fd = self.wake_pipe.readFd(),
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
