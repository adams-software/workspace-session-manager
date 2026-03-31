const std = @import("std");
const protocol = @import("protocol");

pub const ForwardedOwnerReq = struct {
    requester_fd: i32,
    request_id: u32,
    action: protocol.OwnerAction,
};

pub const OwnerSession = union(enum) {
    none,
    attached: struct {
        fd: i32,
        pending: ?ForwardedOwnerReq = null,
    },
};

pub const Model = struct {
    owner: OwnerSession = .none,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        switch (self.owner) {
            .none => {},
            .attached => |*owner| {
                if (owner.pending) |*pending| {
                    protocol.freeOwnerAction(allocator, @constCast(&pending.action));
                    owner.pending = null;
                }
            },
        }
    }
};

pub const Action = union(enum) {
    send_control_res: struct {
        fd: i32,
        res: protocol.ControlRes,
    },
    send_owner_control_req: struct {
        fd: i32,
        req: protocol.OwnerControlReq,
    },
    close_fd: i32,
    install_owner: i32,
    clear_owner,
};

pub const ActionList = std.array_list.Managed(Action);

pub fn deinitActionList(allocator: std.mem.Allocator, actions: *ActionList) void {
    for (actions.items) |*action| freeAction(allocator, action);
    actions.deinit();
}

pub fn freeAction(allocator: std.mem.Allocator, action: *Action) void {
    switch (action.*) {
        .send_control_res => |*payload| protocol.freeControlRes(allocator, &payload.res),
        .send_owner_control_req => |*payload| protocol.freeOwnerControlReq(allocator, &payload.req),
        else => {},
    }
}

pub fn appendSendControlRes(allocator: std.mem.Allocator, actions: *ActionList, fd: i32, res: protocol.ControlRes) !void {
    try actions.append(.{ .send_control_res = .{ .fd = fd, .res = try cloneControlRes(allocator, res) } });
}

pub fn appendSendOwnerControlReq(allocator: std.mem.Allocator, actions: *ActionList, fd: i32, req: protocol.OwnerControlReq) !void {
    try actions.append(.{ .send_owner_control_req = .{ .fd = fd, .req = try cloneOwnerControlReq(allocator, req) } });
}

pub fn appendClose(actions: *ActionList, fd: i32) !void {
    try actions.append(.{ .close_fd = fd });
}

pub fn appendInstallOwner(actions: *ActionList, fd: i32) !void {
    try actions.append(.{ .install_owner = fd });
}

pub fn appendClearOwner(actions: *ActionList) !void {
    try actions.append(.clear_owner);
}

pub fn handleAttach(model: *Model, allocator: std.mem.Allocator, client_fd: i32, mode: []const u8, actions: *ActionList) !void {
    switch (model.owner) {
        .none => {
            model.owner = .{ .attached = .{ .fd = client_fd, .pending = null } };
            try appendInstallOwner(actions, client_fd);
            try appendSendControlRes(allocator, actions, client_fd, .{ .ok = true, .value = .{} });
        },
        .attached => |owner| {
            if (std.mem.eql(u8, mode, "exclusive")) {
                try appendSendControlRes(allocator, actions, client_fd, .{ .ok = false, .err = .{ .code = "attach_conflict" } });
                try appendClose(actions, client_fd);
                return;
            }
            if (!std.mem.eql(u8, mode, "takeover")) {
                try appendSendControlRes(allocator, actions, client_fd, .{ .ok = false, .err = .{ .code = "invalid_args" } });
                try appendClose(actions, client_fd);
                return;
            }

            if (owner.pending) |pending| {
                try appendSendControlRes(allocator, actions, pending.requester_fd, .{ .ok = false, .err = .{ .code = "owner_replaced" } });
                try appendClose(actions, pending.requester_fd);
                protocol.freeOwnerAction(allocator, @constCast(&pending.action));
            }
            try appendClose(actions, owner.fd);
            model.owner = .{ .attached = .{ .fd = client_fd, .pending = null } };
            try appendClearOwner(actions);
            try appendInstallOwner(actions, client_fd);
            try appendSendControlRes(allocator, actions, client_fd, .{ .ok = true, .value = .{} });
        },
    }
}

pub fn handleOwnerForward(model: *Model, allocator: std.mem.Allocator, requester_fd: i32, request_id: ?u32, action: ?protocol.OwnerAction, actions: *ActionList) !void {
    const req_id = request_id orelse {
        try appendSendControlRes(allocator, actions, requester_fd, .{ .ok = false, .err = .{ .code = "invalid_args" } });
        try appendClose(actions, requester_fd);
        return;
    };
    const owner_action = action orelse {
        try appendSendControlRes(allocator, actions, requester_fd, .{ .ok = false, .err = .{ .code = "invalid_args" } });
        try appendClose(actions, requester_fd);
        return;
    };

    switch (model.owner) {
        .none => {
            try appendSendControlRes(allocator, actions, requester_fd, .{ .ok = false, .err = .{ .code = "no_owner_client" } });
            try appendClose(actions, requester_fd);
        },
        .attached => |*owner| {
            if (owner.pending != null) {
                try appendSendControlRes(allocator, actions, requester_fd, .{ .ok = false, .err = .{ .code = "owner_busy" } });
                try appendClose(actions, requester_fd);
                return;
            }

            owner.pending = .{
                .requester_fd = requester_fd,
                .request_id = req_id,
                .action = try cloneOwnerAction(allocator, owner_action),
            };
            try appendSendOwnerControlReq(allocator, actions, owner.fd, .{
                .request_id = req_id,
                .action = owner_action,
            });
        },
    }
}

pub fn handleOwnerControlRes(model: *Model, allocator: std.mem.Allocator, res: protocol.OwnerControlRes, actions: *ActionList) !void {
    switch (model.owner) {
        .none => return error.InvalidState,
        .attached => |*owner| {
            const pending = owner.pending orelse return error.InvalidState;
            if (pending.request_id != res.request_id) return error.InvalidState;

            const control_res: protocol.ControlRes = if (res.ok)
                .{ .ok = true, .value = .{} }
            else
                .{ .ok = false, .err = res.err };

            try appendSendControlRes(allocator, actions, pending.requester_fd, control_res);
            try appendClose(actions, pending.requester_fd);
            protocol.freeOwnerAction(allocator, @constCast(&pending.action));
            owner.pending = null;
        },
    }
}

pub fn handleOwnerClosed(model: *Model, allocator: std.mem.Allocator, actions: *ActionList) !void {
    switch (model.owner) {
        .none => {},
        .attached => |*owner| {
            if (owner.pending) |pending| {
                try appendSendControlRes(allocator, actions, pending.requester_fd, .{ .ok = false, .err = .{ .code = "owner_disconnected" } });
                try appendClose(actions, pending.requester_fd);
                protocol.freeOwnerAction(allocator, @constCast(&pending.action));
                owner.pending = null;
            }
            try appendClose(actions, owner.fd);
            model.owner = .none;
            try appendClearOwner(actions);
        },
    }
}

pub fn handlePtyClosed(model: *Model, allocator: std.mem.Allocator, actions: *ActionList) !void {
    switch (model.owner) {
        .none => {},
        .attached => |*owner| {
            if (owner.pending) |pending| {
                try appendSendControlRes(allocator, actions, pending.requester_fd, .{ .ok = false, .err = .{ .code = "pty_closed" } });
                try appendClose(actions, pending.requester_fd);
                protocol.freeOwnerAction(allocator, @constCast(&pending.action));
                owner.pending = null;
            }
            try appendClose(actions, owner.fd);
            model.owner = .none;
            try appendClearOwner(actions);
        },
    }
}

fn cloneOwnerAction(allocator: std.mem.Allocator, action: protocol.OwnerAction) !protocol.OwnerAction {
    return .{
        .op = try allocator.dupe(u8, action.op),
        .path = if (action.path) |path| try allocator.dupe(u8, path) else null,
    };
}

fn cloneControlRes(allocator: std.mem.Allocator, res: protocol.ControlRes) !protocol.ControlRes {
    var out: protocol.ControlRes = .{ .ok = res.ok, .value = null, .err = null };
    if (res.value) |v| {
        out.value = .{
            .exists = v.exists,
            .status = if (v.status) |s| try allocator.dupe(u8, s) else null,
            .code = v.code,
            .signal = if (v.signal) |s| try allocator.dupe(u8, s) else null,
        };
    }
    if (res.err) |e| {
        out.err = .{
            .code = try allocator.dupe(u8, e.code),
            .message = if (e.message) |m| try allocator.dupe(u8, m) else null,
        };
    }
    return out;
}

fn cloneOwnerControlReq(allocator: std.mem.Allocator, req: protocol.OwnerControlReq) !protocol.OwnerControlReq {
    return .{
        .request_id = req.request_id,
        .action = try cloneOwnerAction(allocator, req.action),
    };
}

test "model attach exclusive when no owner installs owner and replies ok" {
    var model = Model{};
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handleAttach(&model, std.testing.allocator, 10, "exclusive", &actions);

    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    switch (model.owner) {
        .attached => |owner| try std.testing.expectEqual(@as(i32, 10), owner.fd),
        else => return error.TestUnexpectedResult,
    }
}

test "model attach exclusive when owner exists returns conflict and closes requester" {
    var model = Model{ .owner = .{ .attached = .{ .fd = 10, .pending = null } } };
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handleAttach(&model, std.testing.allocator, 11, "exclusive", &actions);

    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    switch (actions.items[0]) {
        .send_control_res => |payload| {
            try std.testing.expectEqual(@as(i32, 11), payload.fd);
            try std.testing.expect(!payload.res.ok);
            try std.testing.expectEqualStrings("attach_conflict", payload.res.err.?.code);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (actions.items[1]) {
        .close_fd => |fd| try std.testing.expectEqual(@as(i32, 11), fd),
        else => return error.TestUnexpectedResult,
    }
}

test "model owner forward when no owner returns no_owner_client" {
    var model = Model{};
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handleOwnerForward(&model, std.testing.allocator, 20, 1, .{ .op = "detach" }, &actions);

    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    switch (actions.items[0]) {
        .send_control_res => |payload| try std.testing.expectEqualStrings("no_owner_client", payload.res.err.?.code),
        else => return error.TestUnexpectedResult,
    }
}

test "model owner forward when pending exists returns owner_busy" {
    var model = Model{
        .owner = .{ .attached = .{ .fd = 10, .pending = .{ .requester_fd = 20, .request_id = 1, .action = .{ .op = try std.testing.allocator.dupe(u8, "detach") } } } },
    };
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handleOwnerForward(&model, std.testing.allocator, 21, 2, .{ .op = "detach" }, &actions);

    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    switch (actions.items[0]) {
        .send_control_res => |payload| try std.testing.expectEqualStrings("owner_busy", payload.res.err.?.code),
        else => return error.TestUnexpectedResult,
    }
}

test "model owner forward with owner stores pending and emits owner_control_req" {
    var model = Model{ .owner = .{ .attached = .{ .fd = 10, .pending = null } } };
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handleOwnerForward(&model, std.testing.allocator, 20, 7, .{ .op = "detach" }, &actions);

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    switch (actions.items[0]) {
        .send_owner_control_req => |payload| {
            try std.testing.expectEqual(@as(i32, 10), payload.fd);
            try std.testing.expectEqual(@as(u32, 7), payload.req.request_id);
            try std.testing.expectEqualStrings("detach", payload.req.action.op);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (model.owner) {
        .attached => |owner| {
            try std.testing.expect(owner.pending != null);
            try std.testing.expectEqual(@as(i32, 20), owner.pending.?.requester_fd);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "model owner response resolves requester and clears pending" {
    var model = Model{
        .owner = .{ .attached = .{ .fd = 10, .pending = .{ .requester_fd = 20, .request_id = 7, .action = .{ .op = try std.testing.allocator.dupe(u8, "detach") } } } },
    };
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handleOwnerControlRes(&model, std.testing.allocator, .{ .request_id = 7, .ok = true }, &actions);

    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    switch (actions.items[0]) {
        .send_control_res => |payload| {
            try std.testing.expectEqual(@as(i32, 20), payload.fd);
            try std.testing.expect(payload.res.ok);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (model.owner) {
        .attached => |owner| try std.testing.expect(owner.pending == null),
        else => return error.TestUnexpectedResult,
    }
}

test "model owner closed with pending fails requester and clears owner" {
    var model = Model{
        .owner = .{ .attached = .{ .fd = 10, .pending = .{ .requester_fd = 20, .request_id = 7, .action = .{ .op = try std.testing.allocator.dupe(u8, "detach") } } } },
    };
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handleOwnerClosed(&model, std.testing.allocator, &actions);

    try std.testing.expectEqual(@as(usize, 4), actions.items.len);
    switch (actions.items[0]) {
        .send_control_res => |payload| try std.testing.expectEqualStrings("owner_disconnected", payload.res.err.?.code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(OwnerSession.none, model.owner);
}

test "model pty closed with pending fails requester and clears owner" {
    var model = Model{
        .owner = .{ .attached = .{ .fd = 10, .pending = .{ .requester_fd = 20, .request_id = 7, .action = .{ .op = try std.testing.allocator.dupe(u8, "detach") } } } },
    };
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handlePtyClosed(&model, std.testing.allocator, &actions);

    try std.testing.expectEqual(@as(usize, 4), actions.items.len);
    switch (actions.items[0]) {
        .send_control_res => |payload| try std.testing.expectEqualStrings("pty_closed", payload.res.err.?.code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(OwnerSession.none, model.owner);
}
