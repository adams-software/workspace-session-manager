const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");
const VTermAdapter = @import("terminal_state_vterm").VTermAdapter;
const screen_types = @import("vterm_screen_types");

pub const HostScreenSnapshot = screen_types.HostScreenSnapshot;

pub const ModelUpdate = struct {
    version: u64,
    dirty: bool,
    full_redraw_needed: bool,

    pub fn asModelChanged(self: ModelUpdate) actor_mailboxes.ModelChanged {
        return .{ .version = self.version };
    }
};

pub const TerminalModel = struct {
    adapter: VTermAdapter,
    version: u64 = 0,
    dirty: bool = true,
    full_redraw_needed: bool = true,

    pub fn init(rows: u16, cols: u16) !TerminalModel {
        return .{
            .adapter = try VTermAdapter.init(rows, cols),
        };
    }

    pub fn deinit(self: *TerminalModel) void {
        self.adapter.deinit();
    }

    pub fn feedScreenBytes(self: *TerminalModel, bytes: []const u8) ModelUpdate {
        if (bytes.len > 0) {
            self.adapter.feed(bytes);
            self.version += 1;
            self.dirty = true;
        }
        return .{
            .version = self.version,
            .dirty = self.dirty,
            .full_redraw_needed = self.full_redraw_needed,
        };
    }

    pub fn resize(self: *TerminalModel, rows: u16, cols: u16) ModelUpdate {
        self.adapter.resize(rows, cols);
        self.adapter.forceFullDamage();
        self.version += 1;
        self.dirty = true;
        self.full_redraw_needed = true;
        return .{
            .version = self.version,
            .dirty = self.dirty,
            .full_redraw_needed = self.full_redraw_needed,
        };
    }

    pub fn snapshot(self: *const TerminalModel, allocator: std.mem.Allocator) !HostScreenSnapshot {
        return self.adapter.snapshot(allocator);
    }

    pub fn currentVersion(self: *const TerminalModel) u64 {
        return self.version;
    }

    pub fn currentSnapshotVersion(self: *const TerminalModel) u64 {
        return self.version;
    }

    pub fn isDirty(self: *const TerminalModel) bool {
        return self.dirty;
    }

    pub fn fullRedrawNeeded(self: *const TerminalModel) bool {
        return self.full_redraw_needed;
    }

    pub fn markCommitted(self: *TerminalModel) void {
        self.dirty = false;
        self.full_redraw_needed = false;
    }

    pub fn markCommittedThrough(self: *TerminalModel, version: u64) void {
        if (self.version <= version) {
            self.dirty = false;
            self.full_redraw_needed = false;
        }
    }

    pub fn forceFullDamage(self: *TerminalModel) void {
        self.adapter.forceFullDamage();
        self.dirty = true;
        self.full_redraw_needed = true;
    }
};
