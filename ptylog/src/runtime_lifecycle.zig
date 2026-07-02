const std = @import("std");
const c = @cImport({
    @cInclude("poll.h");
    @cInclude("signal.h");
});
const getTtySize = @import("ptyio_tty_size").getTtySize;
const WakePipe = @import("wake_pipe").WakePipe;

pub const Size = struct {
    rows: u16,
    cols: u16,
};

var active_lifecycle: ?*RuntimeLifecycle = null;

fn detectCurrentSize() Size {
    const fds = [_]c_int{ std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO };
    for (fds) |fd| {
        const size = getTtySize(fd) catch continue;
        if (size.rows != 0 and size.cols != 0) return .{ .rows = size.rows, .cols = size.cols };
    }
    return .{ .rows = 24, .cols = 80 };
}

fn handleSigwinch(_: c_int) callconv(.c) void {
    const lifecycle = active_lifecycle orelse return;
    lifecycle.winch_changed = true;
    lifecycle.wake_pipe.notify();
}

fn handleTerminate(sig: c_int) callconv(.c) void {
    const lifecycle = active_lifecycle orelse return;
    lifecycle.terminate_requested = true;
    lifecycle.terminate_sent = false;
    lifecycle.terminate_signal = sig;
    lifecycle.wake_pipe.notify();
}

pub const SignalHandlers = struct {
    old_winch: ?*const fn (c_int) callconv(.c) void,
    old_int: ?*const fn (c_int) callconv(.c) void,
    old_term: ?*const fn (c_int) callconv(.c) void,
    lifecycle: *RuntimeLifecycle,

    pub fn restore(self: SignalHandlers) void {
        active_lifecycle = null;
        self.lifecycle.wake_pipe.deinit();
        _ = c.signal(c.SIGWINCH, self.old_winch);
        _ = c.signal(c.SIGINT, self.old_int);
        _ = c.signal(c.SIGTERM, self.old_term);
    }
};

pub const RuntimeLifecycle = struct {
    winch_changed: bool = false,
    terminate_requested: bool = false,
    terminate_sent: bool = false,
    terminate_signal: c_int = 0,
    wake_pipe: WakePipe = .{},

    pub fn install(self: *RuntimeLifecycle) !SignalHandlers {
        self.wake_pipe = try WakePipe.init();
        errdefer self.wake_pipe.deinit();

        self.resetForRun();
        active_lifecycle = self;

        return .{
            .old_winch = c.signal(c.SIGWINCH, handleSigwinch),
            .old_int = c.signal(c.SIGINT, handleTerminate),
            .old_term = c.signal(c.SIGTERM, handleTerminate),
            .lifecycle = self,
        };
    }

    pub fn resetForRun(self: *RuntimeLifecycle) void {
        self.winch_changed = true;
        self.terminate_requested = false;
        self.terminate_sent = false;
        self.terminate_signal = 0;
    }

    pub fn currentSize(_: *const RuntimeLifecycle) Size {
        return detectCurrentSize();
    }

    pub fn readFd(self: *const RuntimeLifecycle) c_int {
        return self.wake_pipe.readFd();
    }

    pub fn consumeWakeRevents(self: *RuntimeLifecycle, revents: c_short) void {
        if ((revents & c.POLLIN) != 0) self.wake_pipe.drain();
    }

    pub fn takePendingResize(self: *RuntimeLifecycle) ?Size {
        if (!self.winch_changed) return null;

        var size = detectCurrentSize();
        while (self.winch_changed) {
            self.winch_changed = false;
            size = detectCurrentSize();
        }
        return size;
    }

    pub fn applyPendingResizeIfNeeded(self: *RuntimeLifecycle, child: anytype, log_state: anytype) void {
        if (self.takePendingResize()) |size| {
            child.applySize(.{ .cols = size.cols, .rows = size.rows }) catch {};
            log_state.resize(size.rows, size.cols);
        }
    }

    pub fn takeTerminateSignalOnce(self: *RuntimeLifecycle) ?c_int {
        if (!self.terminate_requested or self.terminate_sent) return null;
        self.terminate_sent = true;
        return self.terminate_signal;
    }

    pub fn issueTerminationIfNeeded(self: *RuntimeLifecycle, child: anytype) void {
        if (self.takeTerminateSignalOnce()) |sig| {
            child.sendSignal(sig) catch {};
        }
    }
};
