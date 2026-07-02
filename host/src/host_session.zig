const std = @import("std");
const host = @import("host");
const host_runtime = @import("host_runtime");
const host_repl = @import("host_repl");
const session_server = @import("server");

pub const InitOptions = struct {
    socket_path: []const u8,
    initial_size: ?host.Size,
    headless: bool,
    child_argv: []const []const u8,
    event_sink: ?host_runtime.EventSink,
};

pub const HostSession = struct {
    headless: bool,
    child: host.PtyChildHost,
    server: session_server.SessionServer,
    repl: ?host_repl.Repl,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: InitOptions,
    ) !HostSession {
        var child = try host.PtyChildHost.init(allocator, .{
            .argv = options.child_argv,
            .cols = if (options.initial_size) |s| s.cols else null,
            .rows = if (options.initial_size) |s| s.rows else null,
        });
        errdefer child.deinit();
        try child.start();

        var server = session_server.SessionServer.init(allocator, &child);
        errdefer server.deinit();
        try server.listenWithEventSink(options.socket_path, options.event_sink);
        if (child.pid == null or child.masterFd() == null) return error.InvalidState;
        try server.markReady();
        if (server.runtime) |*runtime| {
            if (options.initial_size) |s| try runtime.resize(s.cols, s.rows);
            if (child.pid) |pid| runtime.onChildStarted(pid);
        }

        var repl: ?host_repl.Repl = null;
        errdefer if (repl) |*r| r.deinit();
        if (!options.headless) {
            repl = host_repl.Repl.init(allocator, io);
            try repl.?.setup();
        }

        return .{
            .headless = options.headless,
            .child = child,
            .server = server,
            .repl = repl,
        };
    }

    pub fn deinit(self: *HostSession) void {
        if (self.repl) |*r| r.deinit();
        self.server.deinit();
        self.child.deinit();
    }

    pub fn step(self: *HostSession) !?u8 {
        _ = try self.server.step();
        try self.child.refresh();
        try self.stepRepl();

        if (self.childExitCode()) |code| return code;
        if (self.server.runtime) |runtime| {
            if (runtime.state().host_phase == .exiting) return 0;
        }
        return null;
    }

    pub fn listenerFd(self: *const HostSession) c_int {
        return self.server.listener_fd orelse -1;
    }

    pub fn ownerFd(self: *const HostSession) c_int {
        return self.server.owner_fd orelse -1;
    }

    pub fn masterFd(self: *const HostSession) c_int {
        return self.child.masterFd() orelse -1;
    }

    pub fn stdinPollEnabled(self: *const HostSession) bool {
        return !self.headless;
    }

    fn stepRepl(self: *HostSession) !void {
        if (self.repl) |*r| {
            if (self.server.runtime) |*runtime| {
                const ResizeBridge = struct {
                    var child_ptr: *host.PtyChildHost = undefined;

                    fn call(size: host_runtime.Size) anyerror!void {
                        try child_ptr.applySize(.{ .cols = size.cols, .rows = size.rows });
                    }
                };
                ResizeBridge.child_ptr = &self.child;
                try r.step(runtime, ResizeBridge.call);
            }
        }
    }

    fn childExitCode(self: *HostSession) ?u8 {
        switch (self.child.currentState()) {
            .running, .starting, .idle => return null,
            .closed => return 0,
            .exited => {
                if (self.server.runtime) |*runtime| {
                    if (self.child.exitStatus()) |st| {
                        if (st.code) |code| runtime.onChildExitedCode(code) else runtime.onChildExitedSignal(mapExitSignal(st.signal));
                    } else {
                        runtime.onChildExitedCode(0);
                    }
                }
                return 0;
            },
        }
    }
};

fn mapExitSignal(text: ?[]const u8) host_runtime.Signal {
    if (text) |t| {
        if (std.mem.eql(u8, t, "INT")) return .int;
        if (std.mem.eql(u8, t, "KILL")) return .kill;
    }
    return .term;
}
