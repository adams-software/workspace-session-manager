const std = @import("std");

pub const Fd = i32;

pub const Error = error{
    InvalidArgs,
    InvalidState,
};

pub const AttachMode = enum {
    takeover,
};

pub const ErrorCode = enum {
    invalid_args,
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

    pub fn validate(self: ForwardAction) error{InvalidArgs}!void {
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

    pub fn installInitialOwner(
        self: *Core,
        allocator: std.mem.Allocator,
        fd: Fd,
        ops: *OpList,
    ) !void {
        switch (self.owner) {
            .none => {
                self.owner = .{ .attached_unready = .{ .fd = fd } };
                try appendInstallOwner(ops, allocator, fd);
            },
            else => return error.InvalidState,
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
        _: AttachMode,
        ops: *OpList,
    ) !void {
        switch (self.owner) {
            .none => {},
            .attached_unready => |existing| {
                try appendClose(ops, allocator, existing.fd);
                try appendClearOwner(ops, allocator);
            },
            .attached_ready => |*existing| {
                if (existing.pending) |*pending| {
                    try appendReply(ops, allocator, pending.requester_fd, false, .owner_replaced);
                    try appendClose(ops, allocator, pending.requester_fd);
                    pending.deinit(allocator);
                    existing.pending = null;
                }
                try appendClose(ops, allocator, existing.fd);
                try appendClearOwner(ops, allocator);
            },
        }

        self.owner = .{ .attached_unready = .{ .fd = client_fd } };
        try appendInstallOwner(ops, allocator, client_fd);
        try appendReply(ops, allocator, client_fd, true, null);
    }

    pub fn handleOwnerReady(self: *Core, owner_fd: Fd) !void {
        switch (self.owner) {
            .none => return error.InvalidState,
            .attached_unready => |owner| {
                if (owner.fd != owner_fd) return error.InvalidState;
                self.owner = .{ .attached_ready = .{ .fd = owner.fd, .pending = null } };
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

                try appendSendOwnerRequest(ops, allocator, owner.fd, request_id, action);
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

                try appendReply(ops, allocator, pending.requester_fd, ok, if (ok) null else (code orelse .invalid_args));
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
