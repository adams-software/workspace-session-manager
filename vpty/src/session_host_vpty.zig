const std = @import("std");
const pty_host = @import("host");
const term_engine = @import("term_engine");

pub const HostColor = term_engine.HostColor;
pub const HostCellAttrs = term_engine.HostCellAttrs;
pub const HostHyperlink = term_engine.HostHyperlink;
pub const HostScreenCell = term_engine.HostScreenCell;
pub const HostScreenLine = term_engine.HostScreenLine;
pub const HostScreenSnapshot = term_engine.HostScreenSnapshot;
pub const freeScreenSnapshot = term_engine.freeScreenSnapshot;

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
