const std = @import("std");

pub const Mode = enum {
    passive,
    active_menu,
    prompt_attach,
    prompt_create,
    prompt_kill,
};

pub const InlineNoticeKind = enum {
    none,
    err,
    info,
};

pub const Candidate = struct {
    label: []const u8,
    value: []const u8,
};

pub const ExternalContext = struct {
    detached: bool = false,
    attach_candidates: []const Candidate = &.{},
};

pub const Key = union(enum) {
    ctrl_c,
    ctrl_g,
    esc,
    enter,
    backspace,
    tab,
    home,
    end,
    left,
    right,
    up,
    down,
    printable: u8,

    pub fn fromByte(b: u8) ?Key {
        return switch (b) {
            0x03 => .ctrl_c,
            0x07 => .ctrl_g,
            0x1b => .esc,
            0x7f => .backspace,
            '\r', '\n' => .enter,
            '\t' => .tab,
            0x20...0x7e => .{ .printable = b },
            else => null,
        };
    }
};

pub const Action = union(enum) {
    quit,
    detach,
    prev,
    next,
    in,
    out,
    logs,
    kill,
    attach: []const u8,
    create: []const u8,
};

pub const StepResult = struct {
    rerender: bool = false,
    action: ?Action = null,
    request_attach_candidates: ?[]const u8 = null,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    mode: Mode = .passive,
    input_buf: std.ArrayList(u8),
    cursor: usize = 0,
    notice_kind: InlineNoticeKind = .none,
    notice_text: std.ArrayList(u8),
    selected_candidate: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
            .input_buf = .empty,
            .notice_text = .empty,
        };
    }

    pub fn deinit(self: *State) void {
        self.input_buf.deinit(self.allocator);
        self.notice_text.deinit(self.allocator);
    }

    pub fn input(self: *const State) []const u8 {
        return self.input_buf.items;
    }

    pub fn notice(self: *const State) []const u8 {
        return self.notice_text.items;
    }

    pub fn handleKey(self: *State, ctx: ExternalContext, key: Key) StepResult {
        return switch (self.mode) {
            .passive => self.handlePassive(ctx, key),
            .active_menu => self.handleActiveMenu(ctx, key),
            .prompt_attach => self.handlePromptAttach(ctx, key),
            .prompt_create => self.handlePromptCreate(key),
            .prompt_kill => self.handlePromptKill(key),
        };
    }

    pub fn setExternalError(self: *State, message: []const u8) StepResult {
        self.setNotice(.err, message);
        return .{ .rerender = true };
    }

    pub fn setExternalInfo(self: *State, message: []const u8) StepResult {
        self.setNotice(.info, message);
        return .{ .rerender = true };
    }

    pub fn enterPassive(self: *State) void {
        self.mode = .passive;
        self.notice_kind = .none;
        self.notice_text.clearRetainingCapacity();
        self.selected_candidate = null;
    }

    pub fn clearNotice(self: *State) StepResult {
        if (self.notice_kind == .none and self.notice_text.items.len == 0) return .{};
        self.notice_kind = .none;
        self.notice_text.clearRetainingCapacity();
        return .{ .rerender = true };
    }

    pub fn updateExternalContext(self: *State, ctx: ExternalContext) StepResult {
        const before = self.selected_candidate;
        if (ctx.attach_candidates.len == 0) {
            self.selected_candidate = null;
        } else if (self.selected_candidate) |idx| {
            if (idx >= ctx.attach_candidates.len) self.selected_candidate = 0;
        }
        return .{ .rerender = before != self.selected_candidate };
    }

    fn handlePassive(self: *State, ctx: ExternalContext, key: Key) StepResult {
        return switch (key) {
            .ctrl_c => if (ctx.detached)
                .{ .rerender = true, .action = .quit }
            else
                .{},
            .ctrl_g => blk: {
                self.mode = .active_menu;
                self.notice_kind = .none;
                self.notice_text.clearRetainingCapacity();
                break :blk .{ .rerender = true };
            },
            else => .{},
        };
    }

    fn handleActiveMenu(self: *State, ctx: ExternalContext, key: Key) StepResult {
        _ = ctx;
        return switch (key) {
            .esc, .ctrl_g => blk: {
                self.mode = .passive;
                self.notice_kind = .none;
                self.notice_text.clearRetainingCapacity();
                break :blk .{ .rerender = true };
            },
            .ctrl_c => .{ .rerender = true, .action = .detach },
            .left => .{ .rerender = true, .action = .prev },
            .right => .{ .rerender = true, .action = .next },
            .down => .{ .rerender = true, .action = .in },
            .up => .{ .rerender = true, .action = .out },
            .printable => |ch| switch (ch) {
                'd' => .{ .rerender = true, .action = .detach },
                'a' => blk: {
                    self.enterPrompt(.prompt_attach);
                    break :blk .{ .rerender = true };
                },
                'c' => blk: {
                    self.enterPrompt(.prompt_create);
                    break :blk .{ .rerender = true };
                },
                'x' => blk: {
                    self.enterPrompt(.prompt_kill);
                    break :blk .{ .rerender = true };
                },
                'h' => .{ .rerender = true, .action = .prev },
                'j' => .{ .rerender = true, .action = .in },
                'k' => .{ .rerender = true, .action = .out },
                'n' => .{ .rerender = true, .action = .next },
                'l' => .{ .rerender = true, .action = .next },
                'g' => .{ .rerender = true, .action = .logs },
                else => .{},
            },
            else => .{},
        };
    }

    fn handlePromptAttach(self: *State, ctx: ExternalContext, key: Key) StepResult {
        return switch (key) {
            .ctrl_c => .{ .rerender = true, .action = .quit },
            .ctrl_g => blk: {
                self.mode = .passive;
                self.notice_kind = .none;
                self.notice_text.clearRetainingCapacity();
                break :blk .{ .rerender = true };
            },
            .esc => blk: {
                self.mode = .active_menu;
                self.notice_kind = .none;
                self.notice_text.clearRetainingCapacity();
                break :blk .{ .rerender = true };
            },
            .backspace => blk: {
                if (self.cursor == 0 or self.input_buf.items.len == 0) break :blk .{};
                _ = self.input_buf.orderedRemove(self.cursor - 1);
                self.cursor -= 1;
                self.selected_candidate = null;
                break :blk .{ .rerender = true, .request_attach_candidates = self.input_buf.items };
            },
            .home => blk: {
                self.cursor = 0;
                break :blk .{ .rerender = true };
            },
            .end => blk: {
                self.cursor = self.input_buf.items.len;
                break :blk .{ .rerender = true };
            },
            .left => blk: {
                if (self.cursor > 0) self.cursor -= 1;
                break :blk .{ .rerender = true };
            },
            .right => blk: {
                if (self.cursor < self.input_buf.items.len) self.cursor += 1;
                break :blk .{ .rerender = true };
            },
            .tab, .up => blk: {
                self.cycleSelection(ctx, false);
                break :blk .{ .rerender = true };
            },
            .down => blk: {
                self.cycleSelection(ctx, true);
                break :blk .{ .rerender = true };
            },
            .enter => blk: {
                if (self.selected_candidate) |idx| {
                    if (idx < ctx.attach_candidates.len) {
                        self.mode = .passive;
                        break :blk .{ .rerender = true, .action = .{ .attach = self.allocator.dupe(u8, ctx.attach_candidates[idx].value) catch return .{} } };
                    }
                }
                if (self.input_buf.items.len == 0) {
                    self.setNotice(.err, "target required");
                    break :blk .{ .rerender = true };
                }
                self.mode = .passive;
                break :blk .{ .rerender = true, .action = .{ .attach = self.allocator.dupe(u8, self.input_buf.items) catch return .{} } };
            },
            .printable => |ch| blk: {
                self.insertChar(ch);
                self.selected_candidate = null;
                break :blk .{ .rerender = true, .request_attach_candidates = self.input_buf.items };
            },
        };
    }

    fn handlePromptCreate(self: *State, key: Key) StepResult {
        return switch (key) {
            .ctrl_c => .{ .rerender = true, .action = .quit },
            .ctrl_g => blk: {
                self.mode = .passive;
                self.notice_kind = .none;
                self.notice_text.clearRetainingCapacity();
                break :blk .{ .rerender = true };
            },
            .esc => blk: {
                self.mode = .active_menu;
                self.notice_kind = .none;
                self.notice_text.clearRetainingCapacity();
                break :blk .{ .rerender = true };
            },
            .backspace => blk: {
                if (self.cursor == 0 or self.input_buf.items.len == 0) break :blk .{};
                _ = self.input_buf.orderedRemove(self.cursor - 1);
                self.cursor -= 1;
                break :blk .{ .rerender = true };
            },
            .home => blk: {
                self.cursor = 0;
                break :blk .{ .rerender = true };
            },
            .end => blk: {
                self.cursor = self.input_buf.items.len;
                break :blk .{ .rerender = true };
            },
            .left => blk: {
                if (self.cursor > 0) self.cursor -= 1;
                break :blk .{ .rerender = true };
            },
            .right => blk: {
                if (self.cursor < self.input_buf.items.len) self.cursor += 1;
                break :blk .{ .rerender = true };
            },
            .enter => blk: {
                if (self.input_buf.items.len == 0) {
                    self.setNotice(.err, "name required");
                    break :blk .{ .rerender = true };
                }
                self.mode = .passive;
                break :blk .{ .rerender = true, .action = .{ .create = self.allocator.dupe(u8, self.input_buf.items) catch return .{} } };
            },
            .printable => |ch| blk: {
                self.insertChar(ch);
                break :blk .{ .rerender = true };
            },
            else => .{},
        };
    }

    fn handlePromptKill(self: *State, key: Key) StepResult {
        return switch (key) {
            .ctrl_g, .esc => blk: {
                self.mode = .active_menu;
                self.notice_kind = .none;
                self.notice_text.clearRetainingCapacity();
                break :blk .{ .rerender = true };
            },
            .enter => blk: {
                self.mode = .passive;
                break :blk .{ .rerender = true, .action = .kill };
            },
            else => .{},
        };
    }

    fn enterPrompt(self: *State, mode: Mode) void {
        self.mode = mode;
        self.input_buf.clearRetainingCapacity();
        self.cursor = 0;
        self.selected_candidate = null;
        self.notice_kind = .none;
        self.notice_text.clearRetainingCapacity();
    }

    fn insertChar(self: *State, ch: u8) void {
        self.input_buf.insert(self.allocator, self.cursor, ch) catch return;
        self.cursor += 1;
    }

    fn setNotice(self: *State, kind: InlineNoticeKind, message: []const u8) void {
        self.notice_kind = kind;
        self.notice_text.clearRetainingCapacity();
        self.notice_text.appendSlice(self.allocator, message) catch {};
    }

    fn cycleSelection(self: *State, ctx: ExternalContext, forward: bool) void {
        if (ctx.attach_candidates.len == 0) {
            self.selected_candidate = null;
            return;
        }
        if (self.selected_candidate == null) {
            self.selected_candidate = 0;
            return;
        }
        const current = self.selected_candidate.?;
        self.selected_candidate = if (forward)
            (current + 1) % ctx.attach_candidates.len
        else
            if (current == 0) ctx.attach_candidates.len - 1 else current - 1;
    }
};

test "ctrl-g enters active menu from passive" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    const result = state.handleKey(.{}, .ctrl_g);
    try std.testing.expectEqual(Mode.active_menu, state.mode);
    try std.testing.expect(result.rerender);
}

test "ctrl-c quits from detached passive state" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    const result = state.handleKey(.{ .detached = true }, .ctrl_c);
    try std.testing.expect(result.action != null);
    try std.testing.expectEqual(Action.quit, result.action.?);
}

test "prompt attach cycles external candidates" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .prompt_attach;

    const candidates = [_]Candidate{
        .{ .label = "one", .value = "one" },
        .{ .label = "two", .value = "two" },
    };
    const ctx = ExternalContext{ .attach_candidates = candidates[0..] };

    _ = state.handleKey(ctx, .tab);
    try std.testing.expectEqual(@as(?usize, 0), state.selected_candidate);
    _ = state.handleKey(ctx, .down);
    try std.testing.expectEqual(@as(?usize, 1), state.selected_candidate);
}

test "external error becomes presentational notice" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .active_menu;

    const result = state.setExternalError("bad attach");
    try std.testing.expect(result.rerender);
    try std.testing.expectEqual(InlineNoticeKind.err, state.notice_kind);
    try std.testing.expectEqualStrings("bad attach", state.notice());
    try std.testing.expectEqual(Mode.active_menu, state.mode);
}

test "prompt attach enter prefers selected candidate" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .prompt_attach;

    const candidates = [_]Candidate{
        .{ .label = "one", .value = "session/one" },
        .{ .label = "two", .value = "session/two" },
    };
    const ctx = ExternalContext{ .attach_candidates = candidates[0..] };

    _ = state.handleKey(ctx, .tab);
    _ = state.handleKey(ctx, .down);
    const result = state.handleKey(ctx, .enter);

    try std.testing.expect(result.action != null);
    try std.testing.expectEqualStrings("session/two", result.action.?.attach);
    try std.testing.expect(result.action.?.attach.ptr != candidates[1].value.ptr);
    std.testing.allocator.free(result.action.?.attach);
}

test "updateExternalContext clears invalid candidate selection" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .prompt_attach;
    state.selected_candidate = 2;

    const candidates = [_]Candidate{
        .{ .label = "one", .value = "session/one" },
    };
    const result = state.updateExternalContext(.{ .attach_candidates = candidates[0..] });

    try std.testing.expect(result.rerender);
    try std.testing.expectEqual(@as(?usize, 0), state.selected_candidate);
}

test "escaping attach prompt clears prompt-local notice" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .prompt_attach;
    _ = state.setExternalError("oops");

    const result = state.handleKey(.{}, .esc);
    try std.testing.expect(result.rerender);
    try std.testing.expectEqual(Mode.active_menu, state.mode);
    try std.testing.expectEqual(InlineNoticeKind.none, state.notice_kind);
    try std.testing.expectEqualStrings("", state.notice());
}
