const std = @import("std");
const ui_state = @import("ui_state.zig");
const canonical = @import("canonical.zig");

pub const Error = error{
    AmbiguousTarget,
};

pub const ResolvedAction = union(enum) {
    quit,
    detach,
    logs,
    kill,
    nav: []u8,
    attach: []u8,
    create: []u8,
};

pub const Provider = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    current_session: []u8,
    passive_label_buf: std.ArrayList(u8),
    active_summary: std.ArrayList(u8),
    attach_candidates: []ui_state.Candidate,

    pub const NavOp = enum { prev, next, in, out };

    pub const BarModel = struct {
        workspace: []const u8,
        session: []const u8,
        passive_label: []const u8,
        active_summary: []const u8,
        attach_candidates: []const ui_state.Candidate,
        detached: bool,
    };

    pub fn init(allocator: std.mem.Allocator, root: []const u8, current_session: ?[]const u8) !Provider {
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
            .current_session = try allocator.dupe(u8, current_session orelse ""),
            .passive_label_buf = .{},
            .active_summary = .{},
            .attach_candidates = &.{},
        };
    }

    pub fn deinit(self: *Provider) void {
        self.allocator.free(self.root);
        self.allocator.free(self.current_session);
        self.passive_label_buf.deinit(self.allocator);
        self.active_summary.deinit(self.allocator);
        freeCandidates(self.allocator, self.attach_candidates);
    }

    pub fn setCurrentSession(self: *Provider, current_session: ?[]const u8) !void {
        self.allocator.free(self.current_session);
        self.current_session = try self.allocator.dupe(u8, current_session orelse "");
    }

    pub fn externalContext(self: *const Provider) ui_state.ExternalContext {
        return .{
            .detached = self.current_session.len == 0,
            .attach_candidates = self.attach_candidates,
        };
    }

    pub fn barModel(self: *const Provider) BarModel {
        return .{
            .workspace = self.root,
            .session = if (self.current_session.len == 0) "detached" else self.current_session,
            .passive_label = self.passiveLabel(),
            .active_summary = self.active_summary.items,
            .attach_candidates = self.attach_candidates,
            .detached = self.current_session.len == 0,
        };
    }

    pub fn refresh(self: *Provider) !void {
        self.passive_label_buf.clearRetainingCapacity();
        var next_active_summary = std.ArrayList(u8){};
        defer next_active_summary.deinit(self.allocator);

        if (self.current_session.len == 0) {
            self.active_summary.clearRetainingCapacity();
            try self.passive_label_buf.appendSlice(self.allocator, "detached");
            return;
        }

        try self.passive_label_buf.writer(self.allocator).print("{s}/{s}", .{ self.root, self.current_session });

        if (self.current_session.len == 0) {
            self.active_summary.clearRetainingCapacity();
            return;
        }

        const prev = try self.resolveNavTarget(.prev);
        defer if (prev) |s| self.allocator.free(s);
        const next = try self.resolveNavTarget(.next);
        defer if (next) |s| self.allocator.free(s);
        const child = try self.resolveNavTarget(.in);
        defer if (child) |s| self.allocator.free(s);
        const parent = try self.resolveNavTarget(.out);
        defer if (parent) |s| self.allocator.free(s);

        if (prev) |target| {
            const label = try relativeSiblingLabelAlloc(self.allocator, target);
            defer self.allocator.free(label);
            try appendTag(&next_active_summary, self.allocator, "←", label);
        } else try appendTag(&next_active_summary, self.allocator, "←", "_");

        if (child) |target| {
            const label = try relativeChildLabelAlloc(self.allocator, target);
            defer self.allocator.free(label);
            try appendTag(&next_active_summary, self.allocator, "↓", label);
        } else try appendTag(&next_active_summary, self.allocator, "↓", "_");

        if (parent) |target| {
            const label = try relativeParentLabelAlloc(self.allocator, target);
            defer self.allocator.free(label);
            try appendTag(&next_active_summary, self.allocator, "↑", label);
        } else try appendTag(&next_active_summary, self.allocator, "↑", "_");

        if (next) |target| {
            const label = try relativeSiblingLabelAlloc(self.allocator, target);
            defer self.allocator.free(label);
            try appendTag(&next_active_summary, self.allocator, "→", label);
        } else try appendTag(&next_active_summary, self.allocator, "→", "_");

        self.active_summary.deinit(self.allocator);
        self.active_summary = next_active_summary;
        next_active_summary = .{};
    }

    fn passiveLabel(self: *const Provider) []const u8 {
        return self.passive_label_buf.items;
    }

    pub fn refreshAttachCandidates(self: *Provider, query: []const u8) !void {
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
            .prev => .{ .nav = (try self.resolveNavTarget(.prev)) orelse try self.allocator.dupe(u8, "") },
            .next => .{ .nav = (try self.resolveNavTarget(.next)) orelse try self.allocator.dupe(u8, "") },
            .in => .{ .nav = (try self.resolveNavTarget(.in)) orelse try self.allocator.dupe(u8, "") },
            .out => .{ .nav = (try self.resolveNavTarget(.out)) orelse try self.allocator.dupe(u8, "") },
            .attach => |query| blk: {
                const resolved = try self.resolveQuery(query);
                break :blk .{ .attach = resolved orelse try self.allocator.dupe(u8, query) };
            },
            .create => |name| .{ .create = try self.allocator.dupe(u8, name) },
        };
    }

    pub fn validateCreateId(_: *Provider, id: []const u8) !void {
        try canonical.validateId(id);
    }

    pub fn socketPathForId(self: *Provider, id: []const u8) ![]u8 {
        return canonical.socketPath(self.allocator, self.root, id);
    }

    pub fn resolveNavTarget(self: *Provider, op: NavOp) !?[]u8 {
        if (self.current_session.len == 0) return null;
        const current_dir = currentNodeDir(self.current_session);
        switch (op) {
            .prev, .next => {
                const names = try self.dirSessionNames(current_dir);
                defer self.freeStringSlice(names);
                if (names.len <= 1) return null;
                const current_name = basename(self.current_session);
                for (names, 0..) |name, i| {
                    if (std.mem.eql(u8, name, current_name)) {
                        const idx = switch (op) {
                            .prev => if (i > 0) i - 1 else names.len - 1,
                            .next => if (i + 1 < names.len) i + 1 else 0,
                            else => unreachable,
                        };
                        if (std.mem.eql(u8, names[idx], current_name)) return null;
                        return try self.joinCanonical(current_dir, names[idx]);
                    }
                }
                return null;
            },
            .in => {
                const children = try self.directChildIds();
                defer self.freeStringSlice(children);
                if (children.len == 0) return null;
                return try self.allocator.dupe(u8, children[0]);
            },
            .out => {
                const parent = parentId(self.current_session) orelse return null;
                if (!try self.existsCanonical(parent)) return null;
                return try self.allocator.dupe(u8, parent);
            },
        }
    }

    pub fn resolveQuery(self: *Provider, query: []const u8) !?[]u8 {
        const ids = try self.listIds();
        defer self.freeStringSlice(ids);
        if (ids.len == 0) return null;

        for (ids) |id| {
            if (std.mem.eql(u8, id, query)) return try self.allocator.dupe(u8, id);
        }

        var matches = std.ArrayList([]u8){};
        defer matches.deinit(self.allocator);
        for (ids) |id| {
            if (std.mem.eql(u8, basename(id), query)) {
                try matches.append(self.allocator, id);
            }
        }
        if (matches.items.len == 1) return try self.allocator.dupe(u8, matches.items[0]);
        if (matches.items.len > 1) return Error.AmbiguousTarget;
        return null;
    }

    fn listIds(self: *Provider) ![][]u8 {
        var out = std.ArrayList([]u8){};
        errdefer self.freeOwnedStrings(out.items);
        var stack = std.ArrayList([]u8){};
        defer {
            for (stack.items) |item| self.allocator.free(item);
            stack.deinit(self.allocator);
        }
        try stack.append(self.allocator, try self.allocator.dupe(u8, self.root));

        while (stack.items.len > 0) {
            const dir_path = stack.pop().?;
            defer self.allocator.free(dir_path);
            var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
            defer dir.close();
            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                const joined = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                switch (entry.kind) {
                    .directory => try stack.append(self.allocator, joined),
                    .file, .unix_domain_socket => {
                        if (std.mem.endsWith(u8, entry.name, ".wsm")) {
                            if (try self.canonicalIdForSock(joined)) |id| try out.append(self.allocator, id);
                            self.allocator.free(joined);
                        } else self.allocator.free(joined);
                    },
                    else => self.allocator.free(joined),
                }
            }
        }

        std.mem.sort([]u8, out.items, {}, lessThanString);
        return try out.toOwnedSlice(self.allocator);
    }

    fn queryCandidates(self: *Provider, query: []const u8) ![]ui_state.Candidate {
        const ids = try self.listIds();
        defer self.freeStringSlice(ids);
        var out = std.ArrayList(ui_state.Candidate){};
        errdefer freeCandidates(self.allocator, out.items);
        for (ids) |id| {
            if (query.len != 0 and std.mem.indexOf(u8, id, query) == null and std.mem.indexOf(u8, basename(id), query) == null) continue;
            const owned = try self.allocator.dupe(u8, id);
            try out.append(self.allocator, .{
                .label = owned,
                .value = owned,
            });
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn existsCanonical(self: *Provider, id: []const u8) !bool {
        const sock = try self.sockForCanonical(id);
        defer self.allocator.free(sock);
        std.fs.accessAbsolute(sock, .{}) catch return false;
        return true;
    }

    fn directChildIds(self: *Provider) ![][]u8 {
        const ids = try self.listIds();
        errdefer self.freeStringSlice(ids);
        const prefix = try std.fmt.allocPrint(self.allocator, "{s}/", .{self.current_session});
        defer self.allocator.free(prefix);
        var out = std.ArrayList([]u8){};
        errdefer self.freeOwnedStrings(out.items);
        for (ids) |id| {
            if (!std.mem.startsWith(u8, id, prefix)) continue;
            const rest = id[prefix.len..];
            if (rest.len == 0) continue;
            if (std.mem.indexOfScalar(u8, rest, '/')) |_| continue;
            try out.append(self.allocator, try self.allocator.dupe(u8, id));
        }
        self.freeStringSlice(ids);
        std.mem.sort([]u8, out.items, {}, lessThanString);
        return try out.toOwnedSlice(self.allocator);
    }

    fn dirSessionNames(self: *Provider, dir_id: []const u8) ![][]u8 {
        const base_dir = if (dir_id.len == 0)
            try self.allocator.dupe(u8, self.root)
        else
            try std.fs.path.join(self.allocator, &.{ self.root, dir_id });
        defer self.allocator.free(base_dir);

        var dir = try std.fs.openDirAbsolute(base_dir, .{ .iterate = true });
        defer dir.close();
        var iter = dir.iterate();
        var out = std.ArrayList([]u8){};
        errdefer self.freeOwnedStrings(out.items);
        while (try iter.next()) |entry| {
            if (entry.kind != .file and entry.kind != .unix_domain_socket) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wsm")) continue;
            try out.append(self.allocator, try self.allocator.dupe(u8, entry.name[0 .. entry.name.len - 4]));
        }
        std.mem.sort([]u8, out.items, {}, lessThanString);
        return try out.toOwnedSlice(self.allocator);
    }

    fn canonicalIdForSock(self: *Provider, sock: []const u8) !?[]u8 {
        if (!std.mem.startsWith(u8, sock, self.root)) return null;
        var rel = sock[self.root.len..];
        if (rel.len > 0 and rel[0] == std.fs.path.sep) rel = rel[1..];
        if (!std.mem.endsWith(u8, rel, ".wsm")) return null;
        return try self.allocator.dupe(u8, rel[0 .. rel.len - 4]);
    }

    fn sockForCanonical(self: *Provider, id: []const u8) ![]u8 {
        return canonical.socketPath(self.allocator, self.root, id);
    }

    fn joinCanonical(self: *Provider, dir_id: []const u8, leaf: []const u8) ![]u8 {
        if (dir_id.len == 0) return try self.allocator.dupe(u8, leaf);
        return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_id, leaf });
    }

    fn freeStringSlice(self: *Provider, items: [][]u8) void {
        self.freeOwnedStrings(items);
        self.allocator.free(items);
    }

    fn freeOwnedStrings(self: *Provider, items: [][]u8) void {
        for (items) |item| self.allocator.free(item);
    }
};

fn appendTag(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, prefix: []const u8, value: []const u8) !void {
    if (buf.items.len > 0) try buf.appendSlice(allocator, " ");
    try buf.appendSlice(allocator, "[");
    try buf.appendSlice(allocator, prefix);
    try buf.appendSlice(allocator, "] ");
    try buf.appendSlice(allocator, value);
}

fn relativeSiblingLabelAlloc(allocator: std.mem.Allocator, sibling: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "./{s}", .{basename(sibling)});
}

fn relativeParentLabelAlloc(allocator: std.mem.Allocator, parent: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "../{s}", .{basename(parent)});
}

fn relativeChildLabelAlloc(allocator: std.mem.Allocator, child: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "./{s}", .{child});
}

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

fn currentNodeDir(session: []const u8) []const u8 {
    return std.fs.path.dirname(session) orelse "";
}

fn parentId(id: []const u8) ?[]const u8 {
    return std.fs.path.dirname(id);
}

fn lessThanString(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn freeCandidates(allocator: std.mem.Allocator, items: []ui_state.Candidate) void {
    if (items.len == 0) return;
    for (items) |item| {
        allocator.free(item.label);
        if (item.value.ptr != item.label.ptr) allocator.free(item.value);
    }
    allocator.free(items);
}
