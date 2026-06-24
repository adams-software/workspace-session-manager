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
