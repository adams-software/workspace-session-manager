const std = @import("std");

pub const Fd = i32;

pub const Error = error{
    InvalidArgs,
    InvalidState,
};

pub const AttachMode = enum {
    exclusive,
    takeover,
};

pub const ErrorCode = enum {
    invalid_args,
    attach_conflict,
    no_owner,
    owner_not_ready,
    owner_busy,
    owner_disconnected,
    owner_replaced,
    pty_closed,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const ForwardAction = union(enum) {
    detach,
    attach: []u8,

    pub fn clone(self: ForwardAction, allocator: std.mem.Allocator) !ForwardAction {
        return switch (self) {
            .detach => .detach,
            .attach => |path| .{ .attach = try allocator.dupe(u8, path) },
        };
    }

    pub fn deinit(self: *ForwardAction, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .detach => {},
            .attach => |path| allocator.free(path),
        }
    }

    pub fn isDetach(self: ForwardAction) bool {
        return switch (self) {
            .detach => true,
            .attach => false,
        };
    }

    pub fn validate(self: ForwardAction) Error!void {
        switch (self) {
            .detach => {},
            .attach => |path| {
                if (path.len == 0) return error.InvalidArgs;
            },
        }
    }
};

pub const PendingForward = struct {
    requester_fd: Fd,
    request_id: u32,
    action: ForwardAction,

    pub fn deinit(self: *PendingForward, allocator: std.mem.Allocator) void {
        self.action.deinit(allocator);
    }
};

pub const OwnerState = union(enum) {
    none,
    attached_unready: struct {
        fd: Fd,
    },
    attached_ready: struct {
        fd: Fd,
        pending: ?PendingForward = null,
    },
};

pub const Reply = struct {
    fd: Fd,
    ok: bool,
    code: ?ErrorCode = null,
};

pub const OwnerRequest = struct {
    fd: Fd,
    request_id: u32,
    action: ForwardAction,

    pub fn deinit(self: *OwnerRequest, allocator: std.mem.Allocator) void {
        self.action.deinit(allocator);
    }
};

pub const Op = union(enum) {
    reply: Reply,
    send_owner_request: OwnerRequest,
    close_fd: Fd,
    install_owner: Fd,
    clear_owner,
    resize_pty: Size,

    pub fn deinit(self: *Op, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .send_owner_request => |*req| req.deinit(allocator),
            else => {},
        }
    }
};

pub const OpList = std.ArrayList(Op);

pub fn deinitOpList(allocator: std.mem.Allocator, ops: *OpList) void {
    for (ops.items) |*op| op.deinit(allocator);
    ops.deinit(allocator);
}

fn appendReply(
    ops: *OpList,
    allocator: std.mem.Allocator,
    fd: Fd,
    ok: bool,
    code: ?ErrorCode,
) !void {
    try ops.append(allocator, .{
        .reply = .{
            .fd = fd,
            .ok = ok,
            .code = code,
        },
    });
}

fn appendClose(ops: *OpList, allocator: std.mem.Allocator, fd: Fd) !void {
    try ops.append(allocator, .{ .close_fd = fd });
}

fn appendInstallOwner(ops: *OpList, allocator: std.mem.Allocator, fd: Fd) !void {
    try ops.append(allocator, .{ .install_owner = fd });
}

fn appendClearOwner(ops: *OpList, allocator: std.mem.Allocator) !void {
    try ops.append(allocator, .clear_owner);
}

fn appendResizePty(ops: *OpList, allocator: std.mem.Allocator, size: Size) !void {
    try ops.append(allocator, .{ .resize_pty = size });
}

fn appendSendOwnerRequest(
    ops: *OpList,
    allocator: std.mem.Allocator,
    fd: Fd,
    request_id: u32,
    action: ForwardAction,
) !void {
    try ops.append(allocator, .{
        .send_owner_request = .{
            .fd = fd,
            .request_id = request_id,
            .action = try action.clone(allocator),
        },
    });
}

pub const Core = struct {
    owner: OwnerState = .none,
    size: Size = .{ .cols = 80, .rows = 24 },

    pub fn deinit(self: *Core, allocator: std.mem.Allocator) void {
        switch (self.owner) {
            .none => {},
            .attached_unready => {},
            .attached_ready => |*ready| {
                if (ready.pending) |*pending| {
                    pending.deinit(allocator);
                    ready.pending = null;
                }
            },
        }
    }

    pub fn hasOwner(self: *const Core) bool {
        return switch (self.owner) {
            .none => false,
            else => true,
        };
    }

    pub fn ownerFd(self: *const Core) ?Fd {
        return switch (self.owner) {
            .none => null,
            .attached_unready => |s| s.fd,
            .attached_ready => |s| s.fd,
        };
    }

    pub fn handleAttach(
        self: *Core,
        allocator: std.mem.Allocator,
        client_fd: Fd,
        mode: AttachMode,
        ops: *OpList,
    ) !void {
        switch (self.owner) {
            .none => {
                self.owner = .{ .attached_unready = .{ .fd = client_fd } };
                try appendInstallOwner(ops, allocator, client_fd);
                try appendReply(ops, allocator, client_fd, true, null);
            },
            .attached_unready => |existing| {
                switch (mode) {
                    .exclusive => {
                        try appendReply(ops, allocator, client_fd, false, .attach_conflict);
                        try appendClose(ops, allocator, client_fd);
                    },
                    .takeover => {
                        try appendClose(ops, allocator, existing.fd);
                        self.owner = .{ .attached_unready = .{ .fd = client_fd } };
                        try appendClearOwner(ops, allocator);
                        try appendInstallOwner(ops, allocator, client_fd);
                        try appendReply(ops, allocator, client_fd, true, null);
                    },
                }
            },
            .attached_ready => |*existing| {
                switch (mode) {
                    .exclusive => {
                        try appendReply(ops, allocator, client_fd, false, .attach_conflict);
                        try appendClose(ops, allocator, client_fd);
                    },
                    .takeover => {
                        if (existing.pending) |*pending| {
                            try appendReply(ops, allocator, pending.requester_fd, false, .owner_replaced);
                            try appendClose(ops, allocator, pending.requester_fd);
                            pending.deinit(allocator);
                            existing.pending = null;
                        }

                        try appendClose(ops, allocator, existing.fd);
                        self.owner = .{ .attached_unready = .{ .fd = client_fd } };
                        try appendClearOwner(ops, allocator);
                        try appendInstallOwner(ops, allocator, client_fd);
                        try appendReply(ops, allocator, client_fd, true, null);
                    },
                }
            },
        }
    }

    pub fn handleOwnerReady(
        self: *Core,
        owner_fd: Fd,
    ) !void {
        switch (self.owner) {
            .none => return error.InvalidState,
            .attached_unready => |owner| {
                if (owner.fd != owner_fd) return error.InvalidState;
                self.owner = .{
                    .attached_ready = .{
                        .fd = owner.fd,
                        .pending = null,
                    },
                };
            },
            .attached_ready => |owner| {
                if (owner.fd != owner_fd) return error.InvalidState;
            },
        }
    }

    pub fn handleForward(
        self: *Core,
        allocator: std.mem.Allocator,
        requester_fd: Fd,
        request_id: u32,
        action: ForwardAction,
        ops: *OpList,
    ) !void {
        try action.validate();

        switch (self.owner) {
            .none => {
                try appendReply(ops, allocator, requester_fd, false, .no_owner);
                try appendClose(ops, allocator, requester_fd);
            },
            .attached_unready => {
                try appendReply(ops, allocator, requester_fd, false, .owner_not_ready);
                try appendClose(ops, allocator, requester_fd);
            },
            .attached_ready => |*owner| {
                if (owner.pending != null) {
                    try appendReply(ops, allocator, requester_fd, false, .owner_busy);
                    try appendClose(ops, allocator, requester_fd);
                    return;
                }

                owner.pending = .{
                    .requester_fd = requester_fd,
                    .request_id = request_id,
                    .action = try action.clone(allocator),
                };

                try appendSendOwnerRequest(
                    ops,
                    allocator,
                    owner.fd,
                    request_id,
                    action,
                );
            },
        }
    }

    pub fn handleForwardResponse(
        self: *Core,
        allocator: std.mem.Allocator,
        owner_fd: Fd,
        request_id: u32,
        ok: bool,
        code: ?ErrorCode,
        ops: *OpList,
    ) !void {
        switch (self.owner) {
            .none => return error.InvalidState,
            .attached_unready => return error.InvalidState,
            .attached_ready => |*owner| {
                if (owner.fd != owner_fd) return error.InvalidState;

                const pending = owner.pending orelse return error.InvalidState;
                if (pending.request_id != request_id) return error.InvalidState;

                const was_detach = pending.action.isDetach();

                try appendReply(
                    ops,
                    allocator,
                    pending.requester_fd,
                    ok,
                    if (ok) null else (code orelse .invalid_args),
                );
                try appendClose(ops, allocator, pending.requester_fd);

                var owned_pending = owner.pending.?;
                owned_pending.deinit(allocator);
                owner.pending = null;

                if (ok and was_detach) {
                    try appendClose(ops, allocator, owner.fd);
                    self.owner = .none;
                    try appendClearOwner(ops, allocator);
                }
            },
        }
    }

    pub fn handleOwnerResize(
        self: *Core,
        allocator: std.mem.Allocator,
        owner_fd: Fd,
        cols: u16,
        rows: u16,
        ops: *OpList,
    ) !void {
        if (cols == 0 or rows == 0) return error.InvalidArgs;

        switch (self.owner) {
            .none => return error.InvalidState,
            .attached_unready => return error.InvalidState,
            .attached_ready => |owner| {
                if (owner.fd != owner_fd) return error.InvalidState;
                self.size = .{ .cols = cols, .rows = rows };
                try appendResizePty(ops, allocator, self.size);
            },
        }
    }

    pub fn handleOwnerDetach(
        self: *Core,
        allocator: std.mem.Allocator,
        owner_fd: Fd,
        ops: *OpList,
    ) !void {
        switch (self.owner) {
            .none => return error.InvalidState,
            .attached_unready => |owner| {
                if (owner.fd != owner_fd) return error.InvalidState;
                self.owner = .none;
                try appendClearOwner(ops, allocator);
            },
            .attached_ready => |*owner| {
                if (owner.fd != owner_fd) return error.InvalidState;

                if (owner.pending) |*pending| {
                    try appendReply(ops, allocator, pending.requester_fd, false, .owner_disconnected);
                    try appendClose(ops, allocator, pending.requester_fd);
                    pending.deinit(allocator);
                    owner.pending = null;
                }

                self.owner = .none;
                try appendClearOwner(ops, allocator);
            },
        }
    }

    pub fn handleOwnerClosed(
        self: *Core,
        allocator: std.mem.Allocator,
        owner_fd: Fd,
        ops: *OpList,
    ) !void {
        switch (self.owner) {
            .none => return,
            .attached_unready => |owner| {
                if (owner.fd != owner_fd) return;
                try appendClose(ops, allocator, owner.fd);
                self.owner = .none;
                try appendClearOwner(ops, allocator);
            },
            .attached_ready => |*owner| {
                if (owner.fd != owner_fd) return;

                if (owner.pending) |*pending| {
                    try appendReply(ops, allocator, pending.requester_fd, false, .owner_disconnected);
                    try appendClose(ops, allocator, pending.requester_fd);
                    pending.deinit(allocator);
                    owner.pending = null;
                }

                try appendClose(ops, allocator, owner.fd);
                self.owner = .none;
                try appendClearOwner(ops, allocator);
            },
        }
    }

    pub fn handlePtyClosed(
        self: *Core,
        allocator: std.mem.Allocator,
        ops: *OpList,
    ) !void {
        switch (self.owner) {
            .none => {},
            .attached_unready => |owner| {
                try appendClose(ops, allocator, owner.fd);
                self.owner = .none;
                try appendClearOwner(ops, allocator);
            },
            .attached_ready => |*owner| {
                if (owner.pending) |*pending| {
                    try appendReply(ops, allocator, pending.requester_fd, false, .pty_closed);
                    try appendClose(ops, allocator, pending.requester_fd);
                    pending.deinit(allocator);
                    owner.pending = null;
                }

                try appendClose(ops, allocator, owner.fd);
                self.owner = .none;
                try appendClearOwner(ops, allocator);
            },
        }
    }
};

test "attach exclusive with no owner installs unready owner" {
    var core = Core{};
    defer core.deinit(std.testing.allocator);

    var ops = OpList{};
    defer deinitOpList(std.testing.allocator, &ops);

    try core.handleAttach(std.testing.allocator, 10, .exclusive, &ops);

    try std.testing.expect(core.hasOwner());
    try std.testing.expectEqual(@as(?Fd, 10), core.ownerFd());
    try std.testing.expectEqual(@as(usize, 2), ops.items.len);
    try std.testing.expect(ops.items[0] == .install_owner);
    try std.testing.expect(ops.items[1] == .reply);
    try std.testing.expect(ops.items[1].reply.ok);
}

test "forward with no owner fails requester" {
    var core = Core{};
    defer core.deinit(std.testing.allocator);

    var ops = OpList{};
    defer deinitOpList(std.testing.allocator, &ops);

    try core.handleForward(
        std.testing.allocator,
        20,
        1,
        .detach,
        &ops,
    );

    try std.testing.expectEqual(@as(usize, 2), ops.items.len);
    try std.testing.expect(ops.items[0] == .reply);
    try std.testing.expect(!ops.items[0].reply.ok);
    try std.testing.expectEqual(ErrorCode.no_owner, ops.items[0].reply.code.?);
    try std.testing.expectEqual(@as(Fd, 20), ops.items[1].close_fd);
}

test "owner_ready moves unready owner to ready" {
    var core = Core{
        .owner = .{ .attached_unready = .{ .fd = 10 } },
    };
    defer core.deinit(std.testing.allocator);

    try core.handleOwnerReady(10);

    switch (core.owner) {
        .attached_ready => |owner| {
            try std.testing.expectEqual(@as(Fd, 10), owner.fd);
            try std.testing.expect(owner.pending == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "forward when ready stores pending and emits owner request" {
    var core = Core{
        .owner = .{ .attached_ready = .{ .fd = 10, .pending = null } },
    };
    defer core.deinit(std.testing.allocator);

    var ops = OpList{};
    defer deinitOpList(std.testing.allocator, &ops);

    try core.handleForward(
        std.testing.allocator,
        20,
        7,
        .detach,
        &ops,
    );

    try std.testing.expectEqual(@as(usize, 1), ops.items.len);
    try std.testing.expect(ops.items[0] == .send_owner_request);
    try std.testing.expectEqual(@as(Fd, 10), ops.items[0].send_owner_request.fd);
    try std.testing.expectEqual(@as(u32, 7), ops.items[0].send_owner_request.request_id);

    switch (core.owner) {
        .attached_ready => |owner| {
            try std.testing.expect(owner.pending != null);
            try std.testing.expectEqual(@as(Fd, 20), owner.pending.?.requester_fd);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "forward response for detach resolves requester and clears owner" {
    var core = Core{
        .owner = .{
            .attached_ready = .{
                .fd = 10,
                .pending = .{
                    .requester_fd = 20,
                    .request_id = 7,
                    .action = .detach,
                },
            },
        },
    };
    defer core.deinit(std.testing.allocator);

    var ops = OpList{};
    defer deinitOpList(std.testing.allocator, &ops);

    try core.handleForwardResponse(
        std.testing.allocator,
        10,
        7,
        true,
        null,
        &ops,
    );

    try std.testing.expectEqual(@as(usize, 4), ops.items.len);
    try std.testing.expect(ops.items[0] == .reply);
    try std.testing.expect(ops.items[0].reply.ok);
    try std.testing.expectEqual(@as(Fd, 20), ops.items[1].close_fd);
    try std.testing.expectEqual(@as(Fd, 10), ops.items[2].close_fd);
    try std.testing.expect(ops.items[3] == .clear_owner);
    try std.testing.expect(!core.hasOwner());
}

test "takeover fails pending requester and replaces owner" {
    var core = Core{
        .owner = .{
            .attached_ready = .{
                .fd = 10,
                .pending = .{
                    .requester_fd = 20,
                    .request_id = 7,
                    .action = .detach,
                },
            },
        },
    };
    defer core.deinit(std.testing.allocator);

    var ops = OpList{};
    defer deinitOpList(std.testing.allocator, &ops);

    try core.handleAttach(std.testing.allocator, 11, .takeover, &ops);

    try std.testing.expectEqual(@as(usize, 6), ops.items.len);
    try std.testing.expect(ops.items[0] == .reply);
    try std.testing.expectEqual(ErrorCode.owner_replaced, ops.items[0].reply.code.?);
    try std.testing.expectEqual(@as(Fd, 20), ops.items[1].close_fd);
    try std.testing.expectEqual(@as(Fd, 10), ops.items[2].close_fd);
    try std.testing.expect(ops.items[3] == .clear_owner);
    try std.testing.expect(ops.items[4] == .install_owner);
    try std.testing.expect(ops.items[5] == .reply);
    try std.testing.expect(ops.items[5].reply.ok);

    switch (core.owner) {
        .attached_unready => |owner| try std.testing.expectEqual(@as(Fd, 11), owner.fd),
        else => return error.TestUnexpectedResult,
    }
}
