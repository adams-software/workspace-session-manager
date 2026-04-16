const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");
const VTermAdapter = @import("terminal_state_vterm").VTermAdapter;
const screen_types = @import("vterm_screen_types");

pub const HostScreenSnapshot = screen_types.HostScreenSnapshot;
pub const GraphemeMode = VTermAdapter.GraphemeMode;

pub const ModelUpdate = struct {
    version: u64,
    force_full_render: bool = false,

    pub fn asModelChanged(self: ModelUpdate) actor_mailboxes.ModelChanged {
        return .{
            .version = self.version,
            .force_full_render = self.force_full_render,
        };
    }
};
pub const ModelSize = VTermAdapter.Size;

pub const TerminalModel = struct {
    adapter: VTermAdapter,
    version: u64 = 0,

    pub fn init(rows: u16, cols: u16) !TerminalModel {
        return initWithMode(rows, cols, .legacy);
    }

    pub fn initWithMode(rows: u16, cols: u16, mode: VTermAdapter.GraphemeMode) !TerminalModel {
        return .{
            .adapter = try VTermAdapter.initWithMode(rows, cols, mode),
        };
    }

    pub fn deinit(self: *TerminalModel) void {
        self.adapter.deinit();
    }

    pub fn feedScreenBytes(self: *TerminalModel, bytes: []const u8) ModelUpdate {
        if (bytes.len > 0) {
            self.adapter.feed(bytes);
            self.version += 1;
        }
        return .{ .version = self.version };
    }

    pub fn resize(self: *TerminalModel, rows: u16, cols: u16) ModelUpdate {
        self.adapter.resize(rows, cols);
        self.version += 1;
        return .{ .version = self.version };
    }

    pub fn snapshot(self: *const TerminalModel, allocator: std.mem.Allocator) !HostScreenSnapshot {
        return self.adapter.snapshot(allocator);
    }

    pub fn currentVersion(self: *const TerminalModel) u64 {
        return self.version;
    }

    pub fn currentSize(self: *const TerminalModel) ?ModelSize {
        return self.adapter.currentSize();
    }

    pub fn markCommittedThrough(self: *TerminalModel, version: u64) void {
        _ = self;
        _ = version;
    }

    pub fn forceFullDamage(self: *TerminalModel) ModelUpdate {
        return .{
            .version = self.version,
            .force_full_render = true,
        };
    }
};
