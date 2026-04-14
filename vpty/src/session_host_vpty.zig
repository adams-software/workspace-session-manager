const std = @import("std");
const pty_host = @import("host");
const screen_types = @import("vterm_screen_types");

pub const HostColor = screen_types.HostColor;
pub const HostCellAttrs = screen_types.HostCellAttrs;
pub const HostHyperlink = screen_types.HostHyperlink;
pub const HostScreenCell = screen_types.HostScreenCell;
pub const HostScreenLine = screen_types.HostScreenLine;
pub const HostScreenSnapshot = screen_types.HostScreenSnapshot;
pub const freeScreenSnapshot = screen_types.freeScreenSnapshot;

pub const ExitStatus = pty_host.ExitStatus;
pub const HostState = pty_host.HostState;
pub const Size = pty_host.Size;
pub const Error = pty_host.Error || error{Unsupported};

pub const SpawnOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
};

pub const SessionHost = struct {
    inner: pty_host.PtyChildHost,

    pub fn init(allocator: std.mem.Allocator, opts: SpawnOptions) Error!SessionHost {
        const self = SessionHost{
            .inner = try pty_host.PtyChildHost.init(allocator, .{
                .argv = opts.argv,
                .cwd = opts.cwd,
                .env = opts.env,
                .cols = opts.cols,
                .rows = opts.rows,
            }),
        };

        return self;
    }

    pub fn deinit(self: *SessionHost) void {
        self.inner.deinit();
    }

    pub fn start(self: *SessionHost) Error!void {
        return self.inner.start();
    }

    pub fn refresh(self: *SessionHost) Error!void {
        return self.inner.refresh();
    }

    pub fn wait(self: *SessionHost) Error!ExitStatus {
        return self.inner.wait();
    }

    pub fn close(self: *SessionHost) Error!void {
        return self.inner.close();
    }

    pub fn terminate(self: *SessionHost, signal: ?[]const u8) Error!void {
        return self.inner.terminate(signal);
    }

    pub fn writePty(self: *SessionHost, data: []const u8) Error!void {
        return self.inner.writeInput(data);
    }

    pub fn readPty(self: *SessionHost, allocator: std.mem.Allocator, max_bytes: usize, timeout_ms: i32) Error![]u8 {
        return self.inner.readOutput(allocator, max_bytes, timeout_ms);
    }

    pub fn applySessionSize(self: *SessionHost, size: Size) Error!void {
        try self.inner.applySize(size);
    }

    pub fn getState(self: *const SessionHost) HostState {
        return self.inner.currentState();
    }

    pub fn getExitStatus(self: *const SessionHost) ?ExitStatus {
        return self.inner.exitStatus();
    }

    pub fn getMasterFd(self: *const SessionHost) ?std.posix.fd_t {
        return self.inner.masterFd();
    }
};
