const std = @import("std");
const c = @cImport({
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("time.h");
});
const host = @import("session_host_vpty");
const vpty_terminal = @import("vpty_terminal");
const WakePipe = @import("wake_pipe").WakePipe;

const RESIZE_SETTLE_NS: u64 = 35 * std.time.ns_per_ms;

const PendingResize = struct {
    size: vpty_terminal.Size,
    observed_at_ns: u64,
};

var active_lifecycle = std.atomic.Value(?*RuntimeLifecycle).init(null);

fn monotonicTimeNs() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn handleTerminationSignal(sig: c_int) callconv(.c) void {
    const lifecycle = active_lifecycle.load(.seq_cst) orelse return;
    lifecycle.terminate_requested.store(true, .seq_cst);
    lifecycle.terminate_sent.store(false, .seq_cst);
    lifecycle.terminate_signal.store(sig, .seq_cst);
    lifecycle.wake_pipe.notify();
}

fn handleSigwinch(_: c_int) callconv(.c) void {
    const lifecycle = active_lifecycle.load(.seq_cst) orelse return;
    lifecycle.winch_changed.store(true, .seq_cst);
    lifecycle.wake_pipe.notify();
}

pub const SignalHandlers = struct {
    old_winch: ?*const fn (c_int) callconv(.c) void,
    old_int: ?*const fn (c_int) callconv(.c) void,
    old_term: ?*const fn (c_int) callconv(.c) void,
    lifecycle: *RuntimeLifecycle,

    pub fn restore(self: SignalHandlers) void {
        active_lifecycle.store(null, .seq_cst);
        self.lifecycle.wake_pipe.deinit();
        _ = c.signal(c.SIGWINCH, self.old_winch);
        _ = c.signal(c.SIGINT, self.old_int);
        _ = c.signal(c.SIGTERM, self.old_term);
    }
};

pub const RuntimeLifecycle = struct {
    winch_changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    terminate_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    terminate_sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    terminate_signal: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    wake_pipe: WakePipe = .{},
    pending_resize: ?PendingResize = null,

    pub fn install(self: *RuntimeLifecycle) !SignalHandlers {
        self.wake_pipe = try WakePipe.init();
        errdefer self.wake_pipe.deinit();

        self.resetForRun();
        active_lifecycle.store(self, .seq_cst);

        return .{
            .old_winch = c.signal(c.SIGWINCH, handleSigwinch),
            // Interactive Ctrl-C should reach the child PTY application, not tear
            // down the vpty wrapper itself. Ignore host-side SIGINT while running.
            .old_int = c.signal(c.SIGINT, c.SIG_IGN),
            .old_term = c.signal(c.SIGTERM, handleTerminationSignal),
            .lifecycle = self,
        };
    }

    pub fn resetForRun(self: *RuntimeLifecycle) void {
        self.winch_changed.store(true, .seq_cst);
        self.terminate_requested.store(false, .seq_cst);
        self.terminate_sent.store(false, .seq_cst);
        self.terminate_signal.store(0, .seq_cst);
        self.pending_resize = null;
    }

    pub fn readFd(self: *const RuntimeLifecycle) c_int {
        return self.wake_pipe.readFd();
    }

    pub fn drainWakePipe(self: *RuntimeLifecycle) void {
        self.wake_pipe.drain();
    }

    pub fn consumeWakeRevents(self: *RuntimeLifecycle, revents: c_short) void {
        if ((revents & c.POLLIN) != 0) {
            self.wake_pipe.drain();
        }
    }

    pub fn notePendingResizeIfNeeded(self: *RuntimeLifecycle, terminal: *vpty_terminal.TerminalMode) void {
        if (!self.winch_changed.load(.seq_cst)) return;

        var size = vpty_terminal.Size{ .rows = 24, .cols = 80 };
        while (self.winch_changed.swap(false, .seq_cst)) {
            size = terminal.currentSize() catch vpty_terminal.Size{ .rows = 24, .cols = 80 };
        }
        self.pending_resize = .{
            .size = size,
            .observed_at_ns = monotonicTimeNs(),
        };
    }

    pub fn takeSettledResize(self: *RuntimeLifecycle) ?vpty_terminal.Size {
        const pending = self.pending_resize orelse return null;
        const now_ns = monotonicTimeNs();
        if (now_ns - pending.observed_at_ns < RESIZE_SETTLE_NS) return null;
        self.pending_resize = null;
        return pending.size;
    }

    pub fn takeSettledResizeIfNeeded(self: *RuntimeLifecycle, terminal: *vpty_terminal.TerminalMode) ?vpty_terminal.Size {
        self.notePendingResizeIfNeeded(terminal);
        return self.takeSettledResize();
    }

    pub fn issueTerminationIfNeeded(self: *RuntimeLifecycle, session_host: *host.SessionHost) void {
        if (!self.terminate_requested.load(.seq_cst) or self.terminate_sent.load(.seq_cst)) return;

        self.terminate_sent.store(true, .seq_cst);
        _ = session_host.terminate(
            if (self.terminate_signal.load(.seq_cst) == c.SIGINT) "INT"
            else if (self.terminate_signal.load(.seq_cst) == c.SIGTERM) "TERM"
            else null,
        ) catch {};
    }

    pub fn clearPendingResize(self: *RuntimeLifecycle) void {
        self.pending_resize = null;
    }
};
