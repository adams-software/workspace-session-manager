const router_control = @import("router_control");
const router_runtime = @import("router_runtime");
const router_session = @import("router_session");

pub const RouterCore = struct {
    runtime: *router_runtime.RouterRuntime,
    session: *router_session.Session,

    pub fn init(runtime: *router_runtime.RouterRuntime, session: *router_session.Session) RouterCore {
        return .{ .runtime = runtime, .session = session };
    }

    pub fn handleCommand(self: *RouterCore, cmd: router_control.Command) router_control.Result {
        return switch (cmd) {
            .attach => |spec| blk: {
                if (self.session.active != null) break :blk .{ .err_runtime = .already_attached };
                self.session.attach(spec) catch break :blk .{ .err_runtime = .connect_failed };
                const res = router_control.applyAttach(self.runtime, spec);
                if (res != .ok) self.session.detach();
                break :blk res;
            },
            .detach => blk: {
                const res = router_control.applyDetach(self.runtime);
                if (res == .ok) self.session.detach();
                break :blk res;
            },
            else => router_control.executeRuntimeOnly(self.runtime, cmd),
        };
    }

    pub fn onStreamLost(self: *RouterCore) void {
        self.session.onStreamLost();
        self.runtime.detach() catch {};
    }
};
