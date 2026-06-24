const std = @import("std");
const policy = @import("policy.zig");
const service_mod = @import("service.zig");

pub const AttachOutcome = union(enum) {
    ready: []u8,
    no_sessions,
    no_match,
    ambiguous,
    not_attachable: struct {
        id: []u8,
        state: service_mod.AttachState,
    },

    pub fn deinit(self: *AttachOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |id| allocator.free(id),
            .not_attachable => |payload| allocator.free(payload.id),
            else => {},
        }
    }
};

pub const CreateInvalidIdReason = enum {
    empty,
    starts_with_slash,
    ends_with_slash,
    empty_segment,
    dot_segment,
    invalid_char,
};

pub const CreateAttachedOutcome = union(enum) {
    created: service_mod.CreateAttachResult,
    session_exists,
    invalid_id: CreateInvalidIdReason,

    pub fn deinit(self: *CreateAttachedOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .created => |payload| {
                payload.attached.deinit();
                payload.session.deinit(allocator);
            },
            else => {},
        }
    }
};

pub const CreateDetachedOutcome = union(enum) {
    created: service_mod.SessionRef,
    session_exists,
    invalid_id: CreateInvalidIdReason,

    pub fn deinit(self: *CreateDetachedOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .created => |payload| payload.deinit(allocator),
            else => {},
        }
    }
};

pub const KillOutcome = union(enum) {
    signaled: service_mod.KillSignal,
    no_current_session,
    no_control,
};

pub fn planAttach(
    allocator: std.mem.Allocator,
    provider: *policy.Provider,
    service: *service_mod.WorkspaceService,
    query: []const u8,
) !AttachOutcome {
    switch (try provider.resolveQueryOutcome(query)) {
        .exact => |id| {
            errdefer allocator.free(id);
            const state = try service.attachState(provider, id);
            if (state == .ready) return .{ .ready = id };
            return .{ .not_attachable = .{ .id = id, .state = state } };
        },
        .no_sessions => return .no_sessions,
        .no_match => return .no_match,
        .ambiguous => return .ambiguous,
    }
}

fn mapCreateInvalidId(err: anyerror) ?CreateInvalidIdReason {
    return switch (err) {
        error.Empty => .empty,
        error.StartsWithSlash => .starts_with_slash,
        error.EndsWithSlash => .ends_with_slash,
        error.EmptySegment => .empty_segment,
        error.DotSegment => .dot_segment,
        error.InvalidChar => .invalid_char,
        else => null,
    };
}

pub fn createAttached(
    provider: *policy.Provider,
    service: *service_mod.WorkspaceService,
    id: []const u8,
    shell: []const u8,
    cols: ?u16,
    rows: ?u16,
) !CreateAttachedOutcome {
    const result = service.createAndAttach(provider, id, shell, cols, rows) catch |err| {
        if (err == error.SessionAlreadyExists) return .session_exists;
        if (mapCreateInvalidId(err)) |reason| return .{ .invalid_id = reason };
        return err;
    };
    provider.rebuildWorkspaceIndex() catch {};
    return .{ .created = result };
}

pub fn createDetached(
    provider: *policy.Provider,
    service: *service_mod.WorkspaceService,
    id: []const u8,
    shell: []const u8,
    cols: ?u16,
    rows: ?u16,
) !CreateDetachedOutcome {
    const session = service.create(provider, id, shell, cols, rows) catch |err| {
        if (err == error.SessionAlreadyExists) return .session_exists;
        if (mapCreateInvalidId(err)) |reason| return .{ .invalid_id = reason };
        return err;
    };
    provider.rebuildWorkspaceIndex() catch {};
    return .{ .created = session };
}

pub fn killSessionById(
    provider: *policy.Provider,
    service: *service_mod.WorkspaceService,
    id: []const u8,
    sig: service_mod.KillSignal,
) !KillOutcome {
    service.killSession(provider, id, sig) catch |err| {
        if (err == error.NoControl) return .no_control;
        return err;
    };
    provider.rebuildWorkspaceIndex() catch {};
    return .{ .signaled = sig };
}

pub fn killCurrentSession(
    provider: *policy.Provider,
    service: *service_mod.WorkspaceService,
    current_id: ?[]const u8,
    sig: service_mod.KillSignal,
) !KillOutcome {
    const id = current_id orelse return .no_current_session;
    return try killSessionById(provider, service, id, sig);
}

test "planAttach reports no match without touching service state" {
    const allocator = std.testing.allocator;
    var provider = try policy.Provider.init(allocator, "/tmp/workspace", null);
    defer provider.deinit();
    provider.workspace_index = policy.WorkspaceIndex{
        .allocator = allocator,
        .ids = try allocator.dupe([]u8, &.{
            try allocator.dupe(u8, "cats"),
            try allocator.dupe(u8, "stocks"),
        }),
        .id_set = std.StringHashMap(void).init(allocator),
        .children_by_parent = std.StringHashMap(std.ArrayList([]u8)).init(allocator),
    };
    defer {
        var idx = provider.workspace_index.?;
        idx.deinit();
        provider.workspace_index = null;
    }
    for (provider.workspace_index.?.ids) |id| try provider.workspace_index.?.id_set.put(id, {});

    var service = service_mod.WorkspaceService.init(allocator, "host", "vpty", "ptylog");
    var outcome = try planAttach(allocator, &provider, &service, "dogs");
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.no_match, outcome);
}

test "createDetached surfaces invalid id as structured outcome" {
    const allocator = std.testing.allocator;
    var provider = try policy.Provider.init(allocator, "/tmp/workspace", null);
    defer provider.deinit();
    var service = service_mod.WorkspaceService.init(allocator, "host", "vpty", "ptylog");

    var outcome = try createDetached(&provider, &service, "", "/bin/sh", null, null);
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.invalid_id, outcome);
    try std.testing.expectEqual(CreateInvalidIdReason.empty, outcome.invalid_id);
}

test "killCurrentSession reports missing current session as structured outcome" {
    const allocator = std.testing.allocator;
    var provider = try policy.Provider.init(allocator, "/tmp/workspace", null);
    defer provider.deinit();
    var service = service_mod.WorkspaceService.init(allocator, "host", "vpty", "ptylog");

    const outcome = try killCurrentSession(&provider, &service, null, .kill);
    try std.testing.expectEqual(.no_current_session, outcome);
}
