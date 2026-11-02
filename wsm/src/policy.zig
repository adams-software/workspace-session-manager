const std = @import("std");
const global_io = std.Io.Threaded.global_single_threaded.io();
const ui_state = @import("ui_state.zig");
const canonical = @import("canonical.zig");

pub const Error = error{
    AmbiguousTarget,
    NoSessions,
    NoMatchingTarget,
};

pub const QueryOutcome = union(enum) {
    exact: []u8,
    no_sessions,
    no_match,
    ambiguous,

    pub fn deinit(self: *QueryOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exact => |id| allocator.free(id),
            else => {},
        }
    }
};

fn freeOwnedStrings(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
}

pub const WorkspaceIndex = struct {
    allocator: std.mem.Allocator,
    ids: [][]u8,

    fn build(allocator: std.mem.Allocator, root: []const u8) !WorkspaceIndex {
        const ids = try scanSessionIds(allocator, root);
        errdefer {
            freeOwnedStrings(allocator, ids);
            allocator.free(ids);
        }

        return .{
            .allocator = allocator,
            .ids = ids,
        };
    }

    pub fn deinit(self: *WorkspaceIndex) void {
        freeOwnedStrings(self.allocator, self.ids);
        self.allocator.free(self.ids);
    }
};

pub const ResolvedAction = union(enum) {
    quit,
    detach,
    logs,
    kill,
    attach: []u8,
    create: []u8,
};

pub const Provider = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    current_session: []u8,
    workspace_index: ?WorkspaceIndex,
    attach_candidates: []ui_state.Candidate,

    pub const MenuModel = struct {
        workspace: []const u8,
        session: []const u8,
        current_session: ?[]const u8,
        sessions: []const []const u8,
        attach_candidates: []const ui_state.Candidate,
    };

    pub fn init(allocator: std.mem.Allocator, root: []const u8, current_session: ?[]const u8) !Provider {
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
            .current_session = try allocator.dupe(u8, current_session orelse ""),
            .workspace_index = null,
            .attach_candidates = &.{},
        };
    }

    pub fn deinit(self: *Provider) void {
        self.allocator.free(self.root);
        self.allocator.free(self.current_session);
        if (self.workspace_index) |*index| index.deinit();
        freeCandidates(self.allocator, self.attach_candidates);
    }

    pub fn setCurrentSession(self: *Provider, current_session: ?[]const u8) !void {
        self.allocator.free(self.current_session);
        self.current_session = try self.allocator.dupe(u8, current_session orelse "");
    }

    pub fn rebuildWorkspaceIndex(self: *Provider) !void {
        var new_index = try WorkspaceIndex.build(self.allocator, self.root);
        errdefer new_index.deinit();

        if (self.workspace_index) |*index| index.deinit();
        self.workspace_index = new_index;
    }

    fn ensureWorkspaceIndex(self: *Provider) !void {
        if (self.workspace_index == null) try self.rebuildWorkspaceIndex();
    }

    pub fn externalContext(self: *const Provider) ui_state.ExternalContext {
        const sessions: []const []const u8 = if (self.workspace_index) |index| index.ids else &.{};
        return .{
            .detached = self.current_session.len == 0,
            .browser_sessions = sessions,
            .current_session_index = currentSessionIndex(sessions, self.current_session),
            .attach_candidates = self.attach_candidates,
        };
    }

    pub fn menuModel(self: *const Provider) MenuModel {
        const sessions: []const []const u8 = if (self.workspace_index) |index| index.ids else &.{};
        return .{
            .workspace = self.root,
            .session = if (self.current_session.len == 0) "detached" else self.current_session,
            .current_session = if (self.current_session.len == 0) null else self.current_session,
            .sessions = sessions,
            .attach_candidates = self.attach_candidates,
        };
    }

    pub fn refresh(self: *Provider) !void {
        try self.rebuildWorkspaceIndex();
    }

    pub fn refreshAttachCandidates(self: *Provider, query: []const u8) !void {
        try self.ensureWorkspaceIndex();
        freeCandidates(self.allocator, self.attach_candidates);
        self.attach_candidates = &.{};
        self.attach_candidates = try self.queryCandidates(query);
    }

    pub fn resolveAction(self: *Provider, action: ui_state.Action) !ResolvedAction {
        return switch (action) {
            .quit => .quit,
            .detach => .detach,
            .logs => .logs,
            .kill => .kill,
            .attach => |query| .{ .attach = try self.allocator.dupe(u8, query) },
            .create => |name| .{ .create = try self.allocator.dupe(u8, name) },
        };
    }

    pub fn validateCreateId(_: *Provider, id: []const u8) !void {
        try canonical.validateId(id);
    }

    pub fn socketPathForId(self: *Provider, id: []const u8) ![]u8 {
        return canonical.socketPath(self.allocator, self.root, id);
    }

    pub fn resolveQueryOutcome(self: *Provider, query: []const u8) !QueryOutcome {
        try self.ensureWorkspaceIndex();
        const ids = self.workspace_index.?.ids;
        if (ids.len == 0) return .no_sessions;

        for (ids) |id| {
            if (std.mem.eql(u8, id, query)) return .{ .exact = try self.allocator.dupe(u8, id) };
        }

        var matches: std.ArrayList([]u8) = .empty;
        defer matches.deinit(self.allocator);
        for (ids) |id| {
            if (matchesQuery(id, query)) {
                try matches.append(self.allocator, id);
            }
        }
        if (matches.items.len == 1) return .{ .exact = try self.allocator.dupe(u8, matches.items[0]) };
        if (matches.items.len > 1) return .ambiguous;
        return .no_match;
    }

    fn queryCandidates(self: *Provider, query: []const u8) ![]ui_state.Candidate {
        try self.ensureWorkspaceIndex();
        const ids = self.workspace_index.?.ids;
        var out: std.ArrayList(ui_state.Candidate) = .empty;
        errdefer freeCandidates(self.allocator, out.items);
        for (ids) |id| {
            if (query.len != 0 and !matchesQuery(id, query)) continue;
            const owned = try self.allocator.dupe(u8, id);
            try out.append(self.allocator, .{
                .label = owned,
                .value = owned,
            });
        }
        return try out.toOwnedSlice(self.allocator);
    }
};

fn currentSessionIndex(sessions: []const []const u8, current: []const u8) ?usize {
    if (current.len == 0) return null;
    for (sessions, 0..) |session, index| {
        if (std.mem.eql(u8, session, current)) return index;
    }
    return null;
}

pub fn scanSessionIds(allocator: std.mem.Allocator, root: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        freeOwnedStrings(allocator, out.items);
        out.deinit(allocator);
    }
    var stack: std.ArrayList([]u8) = .empty;
    defer {
        for (stack.items) |item| allocator.free(item);
        stack.deinit(allocator);
    }
    try stack.append(allocator, try allocator.dupe(u8, root));

    while (stack.items.len > 0) {
        const dir_path = stack.pop().?;
        defer allocator.free(dir_path);
        var dir = try std.Io.Dir.openDirAbsolute(global_io, dir_path, .{ .iterate = true });
        defer dir.close(global_io);
        var iter = dir.iterate();
        while (try iter.next(global_io)) |entry| {
            const joined = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            switch (entry.kind) {
                .directory => try stack.append(allocator, joined),
                .file, .unix_domain_socket => {
                    if (std.mem.endsWith(u8, entry.name, ".wsm")) {
                        if (try canonicalIdForSock(allocator, root, joined)) |id| try out.append(allocator, id);
                        allocator.free(joined);
                    } else allocator.free(joined);
                },
                else => allocator.free(joined),
            }
        }
    }

    std.mem.sort([]u8, out.items, {}, lessThanString);
    return try out.toOwnedSlice(allocator);
}

fn canonicalIdForSock(allocator: std.mem.Allocator, root: []const u8, sock: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, sock, root)) return null;
    var rel = sock[root.len..];
    if (rel.len > 0 and rel[0] == std.fs.path.sep) rel = rel[1..];
    if (!std.mem.endsWith(u8, rel, ".wsm")) return null;
    return try allocator.dupe(u8, rel[0 .. rel.len - 4]);
}

fn lessThanString(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn matchesQuery(id: []const u8, query: []const u8) bool {
    return std.mem.startsWith(u8, id, query) or std.mem.startsWith(u8, std.fs.path.basename(id), query);
}

pub fn freeCandidates(allocator: std.mem.Allocator, items: []ui_state.Candidate) void {
    if (items.len == 0) return;
    for (items) |item| {
        allocator.free(item.label);
        if (item.value.ptr != item.label.ptr) allocator.free(item.value);
    }
    allocator.free(items);
}

test "prefix query matches candidates from the front only" {
    const allocator = std.testing.allocator;
    var provider = try Provider.init(allocator, "/tmp/workspace", null);
    defer provider.deinit();
    provider.workspace_index = WorkspaceIndex{
        .allocator = allocator,
        .ids = try allocator.dupe([]u8, &.{
            try allocator.dupe(u8, "cats"),
            try allocator.dupe(u8, "stocks"),
            try allocator.dupe(u8, "science"),
        }),
    };
    defer {
        const idx = provider.workspace_index.?;
        for (idx.ids) |id| allocator.free(id);
        allocator.free(idx.ids);
        provider.workspace_index = null;
    }

    const candidates = try provider.queryCandidates("s");
    defer freeCandidates(allocator, candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    for (candidates) |candidate| {
        try std.testing.expect(std.mem.startsWith(u8, candidate.value, "s"));
    }
}

test "prefix resolve uses unique front match" {
    const allocator = std.testing.allocator;
    var provider = try Provider.init(allocator, "/tmp/workspace", null);
    defer provider.deinit();
    provider.workspace_index = WorkspaceIndex{
        .allocator = allocator,
        .ids = try allocator.dupe([]u8, &.{
            try allocator.dupe(u8, "cats"),
            try allocator.dupe(u8, "stocks"),
        }),
    };
    defer {
        const idx = provider.workspace_index.?;
        for (idx.ids) |id| allocator.free(id);
        allocator.free(idx.ids);
        provider.workspace_index = null;
    }

    var outcome = try provider.resolveQueryOutcome("st");
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome == .exact);
    try std.testing.expectEqualStrings("stocks", outcome.exact);
}

test "refresh rebuilds the workspace index after new sessions appear" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(global_io, "workspace");

    var rel_buf: [128]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path[0..]});

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try std.Io.Dir.realPathFile(.cwd(), global_io, rel, &root_buf);
    const root = root_buf[0..root_len];

    var provider = try Provider.init(allocator, root, null);
    defer provider.deinit();

    try provider.refresh();
    const missing = try provider.resolveQueryOutcome("proj");
    try std.testing.expect(missing == .no_sessions);

    try tmp.dir.createDirPath(global_io, "workspace/proj");
    var session_file = try tmp.dir.createFile(global_io, "workspace/proj/session.wsm", .{ .truncate = true });
    session_file.close(global_io);

    try provider.refresh();

    var resolved = try provider.resolveQueryOutcome("proj");
    defer resolved.deinit(allocator);
    try std.testing.expect(resolved == .exact);
    try std.testing.expectEqualStrings("proj/session", resolved.exact);
}

test "resolveQueryOutcome reports missing target when sessions exist" {
    const allocator = std.testing.allocator;
    var provider = try Provider.init(allocator, "/tmp/workspace", null);
    defer provider.deinit();
    provider.workspace_index = WorkspaceIndex{
        .allocator = allocator,
        .ids = try allocator.dupe([]u8, &.{
            try allocator.dupe(u8, "cats"),
            try allocator.dupe(u8, "stocks"),
        }),
    };
    defer {
        const idx = provider.workspace_index.?;
        for (idx.ids) |id| allocator.free(id);
        allocator.free(idx.ids);
        provider.workspace_index = null;
    }

    const outcome = try provider.resolveQueryOutcome("dogs");
    try std.testing.expect(outcome == .no_match);
}
