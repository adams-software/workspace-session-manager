const std = @import("std");
const protocol = @import("protocol");

pub const ForwardedOwnerReq = struct {
    requester_fd: i32,
    request_id: u32,
    action: protocol.OwnerAction,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const OwnerSession = union(enum) {
    none,
    attached_unready: struct {
        fd: i32,
    },
    attached_ready: struct {
        fd: i32,
        pending: ?ForwardedOwnerReq = null,
    },
};

pub const Model = struct {
    owner: OwnerSession = .none,
    session_size: Size = .{ .cols = 80, .rows = 24 },

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        switch (self.owner) {
            .none => {},
            .attached_unready => {},
            .attached_ready => |*owner| {
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
    owner_ready: i32,
    session_size_changed: Size,
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
    try actions.append(.{ .send_control_res = .{ .fd = fd, .res = try protocol.cloneControlResOwned(allocator, res) } });
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

pub fn appendOwnerReady(actions: *ActionList, fd: i32) !void {
    try actions.append(.{ .owner_ready = fd });
}

pub fn appendSessionSizeChanged(actions: *ActionList, size: Size) !void {
    try actions.append(.{ .session_size_changed = size });
}

pub fn handleAttach(model: *Model, allocator: std.mem.Allocator, client_fd: i32, mode: []const u8, actions: *ActionList) !void {
    switch (model.owner) {
        .none => {
            model.owner = .{ .attached_unready = .{ .fd = client_fd } };
            try appendInstallOwner(actions, client_fd);
            try appendSendControlRes(allocator, actions, client_fd, .{ .ok = true, .value = .{} });
        },
        .attached_unready => |owner| {
            _ = owner;
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
            switch (model.owner) {
                .attached_unready => |attaching_owner| try appendClose(actions, attaching_owner.fd),
                else => {},
            }
            model.owner = .{ .attached_unready = .{ .fd = client_fd } };
            try appendClearOwner(actions);
            try appendInstallOwner(actions, client_fd);
            try appendSendControlRes(allocator, actions, client_fd, .{ .ok = true, .value = .{} });
        },
        .attached_ready => |owner| {
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
            model.owner = .{ .attached_unready = .{ .fd = client_fd } };
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
        .attached_unready => {
            try appendSendControlRes(allocator, actions, requester_fd, .{ .ok = false, .err = .{ .code = "owner_not_ready" } });
            try appendClose(actions, requester_fd);
        },
        .attached_ready => |*owner| {
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

pub fn handleOwnerReady(model: *Model, actions: *ActionList) !void {
    switch (model.owner) {
        .none => return error.InvalidState,
        .attached_unready => |owner| {
            model.owner = .{ .attached_ready = .{ .fd = owner.fd, .pending = null } };
            try appendOwnerReady(actions, owner.fd);
        },
        .attached_ready => {},
    }
}

pub fn handleOwnerResize(model: *Model, cols: u16, rows: u16, actions: *ActionList) !void {
    if (cols == 0 or rows == 0) return error.InvalidArgs;
    switch (model.owner) {
        .none => return error.InvalidState,
        .attached_unready => return error.InvalidState,
        .attached_ready => {
            model.session_size = .{ .cols = cols, .rows = rows };
            try appendSessionSizeChanged(actions, model.session_size);
        },
    }
}

pub fn handleOwnerDetach(model: *Model, fd: i32, actions: *ActionList) !void {
    switch (model.owner) {
        .none => return error.InvalidState,
        .attached_unready => |owner| {
            if (owner.fd != fd) return error.InvalidState;
            model.owner = .none;
            try appendClearOwner(actions);
        },
        .attached_ready => |owner| {
            if (owner.fd != fd) return error.InvalidState;
            model.owner = .none;
            try appendClearOwner(actions);
        },
    }
}

pub fn handleOwnerControlRes(model: *Model, allocator: std.mem.Allocator, res: protocol.OwnerControlRes, actions: *ActionList) !void {
    switch (model.owner) {
        .none => return error.InvalidState,
        .attached_unready => return error.InvalidState,
        .attached_ready => |*owner| {
            const pending = owner.pending orelse return error.InvalidState;
            if (pending.request_id != res.request_id) return error.InvalidState;

            const was_detach = std.mem.eql(u8, pending.action.op, "detach");

            const control_res: protocol.ControlRes = if (res.ok)
                .{ .ok = true, .value = .{} }
            else
                .{ .ok = false, .err = res.err };

            try appendSendControlRes(allocator, actions, pending.requester_fd, control_res);
            try appendClose(actions, pending.requester_fd);
            protocol.freeOwnerAction(allocator, @constCast(&pending.action));
            owner.pending = null;

            if (res.ok and was_detach) {
                try appendClose(actions, owner.fd);
                model.owner = .none;
                try appendClearOwner(actions);
            }
        },
    }
}

pub fn handleOwnerClosed(model: *Model, allocator: std.mem.Allocator, actions: *ActionList) !void {
    switch (model.owner) {
        .none => {},
        .attached_unready => |owner| {
            try appendClose(actions, owner.fd);
            model.owner = .none;
            try appendClearOwner(actions);
        },
        .attached_ready => |*owner| {
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
        .attached_unready => |owner| {
            try appendClose(actions, owner.fd);
            model.owner = .none;
            try appendClearOwner(actions);
        },
        .attached_ready => |*owner| {
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
        .attached_unready => |owner| try std.testing.expectEqual(@as(i32, 10), owner.fd),
        .attached_ready => |owner| try std.testing.expectEqual(@as(i32, 10), owner.fd),
        else => return error.TestUnexpectedResult,
    }
}

test "model attach exclusive when owner exists returns conflict and closes requester" {
    var model = Model{ .owner = .{ .attached_ready = .{ .fd = 10, .pending = null } } };
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

test "model owner forward while owner unready returns owner_not_ready" {
    var model = Model{ .owner = .{ .attached_unready = .{ .fd = 10 } } };
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handleOwnerForward(&model, std.testing.allocator, 20, 1, .{ .op = "detach" }, &actions);

    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    switch (actions.items[0]) {
        .send_control_res => |payload| try std.testing.expectEqualStrings("owner_not_ready", payload.res.err.?.code),
        else => return error.TestUnexpectedResult,
    }
}

test "model owner ready transitions unready to ready" {
    var model = Model{ .owner = .{ .attached_unready = .{ .fd = 10 } } };
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handleOwnerReady(&model, &actions);

    switch (model.owner) {
        .attached_ready => |owner| {
            try std.testing.expectEqual(@as(i32, 10), owner.fd);
            try std.testing.expect(owner.pending == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "model owner forward when pending exists returns owner_busy" {
    var model = Model{
        .owner = .{ .attached_ready = .{ .fd = 10, .pending = .{ .requester_fd = 20, .request_id = 1, .action = .{ .op = try std.testing.allocator.dupe(u8, "detach") } } } },
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
    var model = Model{ .owner = .{ .attached_ready = .{ .fd = 10, .pending = null } } };
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
        .attached_ready => |owner| {
            try std.testing.expect(owner.pending != null);
            try std.testing.expectEqual(@as(i32, 20), owner.pending.?.requester_fd);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "model owner response resolves requester and clears pending" {
    var model = Model{
        .owner = .{ .attached_ready = .{ .fd = 10, .pending = .{ .requester_fd = 20, .request_id = 7, .action = .{ .op = try std.testing.allocator.dupe(u8, "detach") } } } },
    };
    defer model.deinit(std.testing.allocator);
    var actions = ActionList.init(std.testing.allocator);
    defer deinitActionList(std.testing.allocator, &actions);

    try handleOwnerControlRes(&model, std.testing.allocator, .{ .request_id = 7, .ok = true }, &actions);

    try std.testing.expectEqual(@as(usize, 4), actions.items.len);
    switch (actions.items[0]) {
        .send_control_res => |payload| {
            try std.testing.expectEqual(@as(i32, 20), payload.fd);
            try std.testing.expect(payload.res.ok);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (actions.items[1]) {
        .close_fd => |fd| try std.testing.expectEqual(@as(i32, 20), fd),
        else => return error.TestUnexpectedResult,
    }
    switch (actions.items[2]) {
        .close_fd => |fd| try std.testing.expectEqual(@as(i32, 10), fd),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(actions.items[3] == .clear_owner);
    try std.testing.expect(model.owner == .none);
}

test "model owner closed with pending fails requester and clears owner" {
    var model = Model{
        .owner = .{ .attached_ready = .{ .fd = 10, .pending = .{ .requester_fd = 20, .request_id = 7, .action = .{ .op = try std.testing.allocator.dupe(u8, "detach") } } } },
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
        .owner = .{ .attached_ready = .{ .fd = 10, .pending = .{ .requester_fd = 20, .request_id = 7, .action = .{ .op = try std.testing.allocator.dupe(u8, "detach") } } } },
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
