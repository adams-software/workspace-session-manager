const std = @import("std");
const actor_mailboxes = @import("actor_mailboxes");
const host = @import("session_host_vpty");
const single_viewport_adapter = @import("single_viewport_adapter");
const TerminalModel = @import("terminal_model").TerminalModel;
const StdoutThread = @import("stdout_thread").StdoutThread;

pub const VirtualCursor = single_viewport_adapter.VirtualCursor;
pub const Viewport = single_viewport_adapter.Viewport;
pub const TextRun = single_viewport_adapter.TextRun;
pub const RowPatch = single_viewport_adapter.RowPatch;
pub const ViewportPatch = single_viewport_adapter.ViewportPatch;
pub const SingleViewportAdapter = single_viewport_adapter.SingleViewportAdapter;

pub const SurfaceState = struct {
    cursor: VirtualCursor = .{},
    has_drawn: bool = false,
};

const PendingSnapshot = struct {
    version: u64,
    snapshot: host.HostScreenSnapshot,
};

pub const RenderProduct = struct {
    version: u64,
    snapshot: host.HostScreenSnapshot,
    patch: ViewportPatch,
    next_surface_state: SurfaceState,

    pub fn deinit(self: *RenderProduct, allocator: std.mem.Allocator) void {
        self.patch.deinit(allocator);
        host.freeScreenSnapshot(allocator, &self.snapshot);
    }
};

pub const Renderer = struct {
    surface_state: SurfaceState = .{},
    pending_surface_state: ?SurfaceState = null,
    pending_output_version: u64 = 0,

    committed_snapshot: ?host.HostScreenSnapshot = null,
    pending_snapshot: ?PendingSnapshot = null,

    stdout_thread: *StdoutThread,
    viewport: Viewport = .{},
    needs_render: bool = true,
    force_full_render: bool = true,
    allow_next_render_despite_backlog: bool = false,
    last_generated_version: u64 = 0,
    render_buf: std.ArrayList(u8) = .{},

    pub fn init(stdout_thread: *StdoutThread, viewport: Viewport) Renderer {
        var self = Renderer{ .stdout_thread = stdout_thread, .viewport = viewport };
        self.ensureBufferCapacity();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.freeStoredSnapshots();
        self.render_buf.deinit(std.heap.page_allocator);
    }

    fn ensureBufferCapacity(self: *Renderer) void {
        if (self.render_buf.capacity == 0) {
            self.render_buf.ensureTotalCapacity(std.heap.page_allocator, 4096) catch {};
        }
    }

    pub fn publishModelChanged(self: *Renderer, changed: actor_mailboxes.ModelChanged) void {
        self.needs_render = true;
        if (changed.force_full_render) {
            self.force_full_render = true;
        }
    }

    pub fn needsRender(self: *const Renderer) bool {
        return self.needs_render;
    }

    pub fn shouldBypassBacklogCoalescing(self: *const Renderer) bool {
        return self.allow_next_render_despite_backlog;
    }

    pub fn takeSnapshot(self: *Renderer, model: *const TerminalModel) ?struct { version: u64, snapshot: host.HostScreenSnapshot } {
        if (!self.needs_render) return null;

        const snapshot = model.snapshot(std.heap.page_allocator) catch return null;
        return .{ .version = model.currentVersion(), .snapshot = snapshot };
    }

    pub fn renderSnapshot(self: *Renderer, version: u64, snapshot: host.HostScreenSnapshot) void {
        if (self.buildRenderProduct(version, snapshot)) |product| {
            self.publishRenderProduct(product);
        }
    }

    pub fn buildRenderProduct(self: *Renderer, version: u64, snapshot: host.HostScreenSnapshot) ?RenderProduct {
        if (!self.needs_render) {
            var discarded = snapshot;
            host.freeScreenSnapshot(std.heap.page_allocator, &discarded);
            return null;
        }
        self.needs_render = false;

        var owned_snapshot = snapshot;
        errdefer host.freeScreenSnapshot(std.heap.page_allocator, &owned_snapshot);

        var next_surface_state = self.surface_state;

        const must_full_redraw =
            self.force_full_render or
            !self.surface_state.has_drawn or
            self.committed_snapshot == null or
            snapshotShapeChanged(self.committed_snapshot.?, &owned_snapshot);

        var patch = ViewportPatch.init(must_full_redraw, std.heap.page_allocator);
        errdefer patch.deinit(std.heap.page_allocator);

        if (must_full_redraw) {
            tryBuildFullFramePatch(self, &patch, &owned_snapshot);
        } else {
            tryBuildChangedRowsPatch(self, &patch, &self.committed_snapshot.?, &owned_snapshot);
        }
        self.force_full_render = false;
        self.allow_next_render_despite_backlog = false;

        patch.cursor = self.clipVirtualCursor(.{
            .visible = owned_snapshot.cursor_visible,
            .row = owned_snapshot.cursor_row,
            .col = owned_snapshot.cursor_col,
        });
        next_surface_state.cursor = patch.cursor;
        next_surface_state.has_drawn = true;

        return .{
            .version = version,
            .snapshot = owned_snapshot,
            .patch = patch,
            .next_surface_state = next_surface_state,
        };
    }

    pub fn publishRenderProduct(self: *Renderer, product: RenderProduct) void {
        var owned_product = product;
        errdefer owned_product.deinit(std.heap.page_allocator);

        self.render_buf.clearRetainingCapacity();
        var compositor = SingleViewportAdapter{
            .viewport = self.viewport,
            .render_buf = &self.render_buf,
        };
        compositor.emitPatch(&owned_product.patch, &owned_product.snapshot);

        self.last_generated_version = owned_product.version;

        self.stdout_thread.publishRenderCandidate(actor_mailboxes.RenderPublish{
            .version = self.last_generated_version,
            .bytes = self.render_buf.items,
            .final_cursor = .{
                .visible = owned_product.patch.cursor.visible,
                .row = owned_product.patch.cursor.row,
                .col = owned_product.patch.cursor.col,
            },
        }) catch return;

        owned_product.patch.deinit(std.heap.page_allocator);
        self.pending_surface_state = owned_product.next_surface_state;
        self.pending_output_version = self.last_generated_version;
        self.replacePendingSnapshot(.{ .version = owned_product.version, .snapshot = owned_product.snapshot });
    }

    pub fn setViewport(self: *Renderer, viewport: Viewport) void {
        self.viewport = viewport;
        self.allow_next_render_despite_backlog = true;
        self.reset();
    }

    pub fn reset(self: *Renderer) void {
        self.render_buf.clearRetainingCapacity();
        self.surface_state = .{};
        self.pending_surface_state = null;
        self.pending_output_version = 0;
        self.last_generated_version = 0;
        self.needs_render = true;
        self.force_full_render = true;
        self.allow_next_render_despite_backlog = true;
        if (self.pending_snapshot) |*pending| {
            host.freeScreenSnapshot(std.heap.page_allocator, &pending.snapshot);
            self.pending_snapshot = null;
        }
        self.ensureBufferCapacity();
    }

    pub fn noteCommitted(self: *Renderer, notice: actor_mailboxes.CommitNotice) void {
        if (self.pending_surface_state) |state| {
            if (notice.version >= self.pending_output_version) {
                self.surface_state = state;
                self.pending_surface_state = null;

                if (self.pending_snapshot) |pending| {
                    if (pending.version == notice.version) {
                        const committed = pending.snapshot;
                        if (self.committed_snapshot) |*old| {
                            host.freeScreenSnapshot(std.heap.page_allocator, old);
                        }
                        self.committed_snapshot = committed;
                    } else {
                        var discarded = pending.snapshot;
                        host.freeScreenSnapshot(std.heap.page_allocator, &discarded);
                        self.force_full_render = true;
                    }
                    self.pending_snapshot = null;
                }

                self.pending_output_version = 0;
            }
        }
    }
    pub fn shutdown(self: *Renderer, version: u64) void {
        _ = version;
        self.render_buf.clearRetainingCapacity();
        self.surface_state = .{};
        self.pending_surface_state = null;
        self.pending_output_version = 0;
        self.last_generated_version = 0;
        self.freeStoredSnapshots();
        self.needs_render = false;
    }

    fn freeStoredSnapshots(self: *Renderer) void {
        if (self.committed_snapshot) |*snapshot| {
            host.freeScreenSnapshot(std.heap.page_allocator, snapshot);
            self.committed_snapshot = null;
        }
        if (self.pending_snapshot) |*pending| {
            host.freeScreenSnapshot(std.heap.page_allocator, &pending.snapshot);
            self.pending_snapshot = null;
        }
    }

    fn replacePendingSnapshot(self: *Renderer, pending: PendingSnapshot) void {
        if (self.pending_snapshot) |*old| {
            host.freeScreenSnapshot(std.heap.page_allocator, &old.snapshot);
        }
        self.pending_snapshot = pending;
    }

    fn clipVirtualCursor(self: *Renderer, cursor: VirtualCursor) VirtualCursor {
        return .{
            .visible = cursor.visible,
            .row = if (self.viewport.rows == 0) 0 else @min(cursor.row, self.viewport.rows - 1),
            .col = if (self.viewport.cols == 0) 0 else @min(cursor.col, self.viewport.cols - 1),
        };
    }

    fn tryBuildFullFramePatch(self: *Renderer, patch: *ViewportPatch, snapshot: *const host.HostScreenSnapshot) void {
        const limit = @min(snapshot.lines.len, self.viewport.rows);
        for (snapshot.lines[0..limit], 0..) |line, row_idx| {
            var row_patch = RowPatch.init(@intCast(row_idx));
            row_patch.runs.append(std.heap.page_allocator, TextRun.init(0, self.viewport.cols, line.cells)) catch {
                row_patch.deinit(std.heap.page_allocator);
                return;
            };
            patch.rows.append(std.heap.page_allocator, row_patch) catch {
                row_patch.deinit(std.heap.page_allocator);
                return;
            };
        }
    }

    fn tryBuildChangedRowsPatch(self: *Renderer, patch: *ViewportPatch, prev: *const host.HostScreenSnapshot, next: *const host.HostScreenSnapshot) void {
        const limit = @min(@min(prev.lines.len, next.lines.len), self.viewport.rows);
        var row_idx: usize = 0;
        while (row_idx < limit) : (row_idx += 1) {
            const prev_line = prev.lines[row_idx];
            const next_line = next.lines[row_idx];

            if (!lineEq(prev_line, next_line)) {
                var row_patch = RowPatch.init(@intCast(row_idx));
                row_patch.runs.append(std.heap.page_allocator, TextRun.init(0, self.viewport.cols, next_line.cells)) catch {
                    row_patch.deinit(std.heap.page_allocator);
                    return;
                };
                patch.rows.append(std.heap.page_allocator, row_patch) catch {
                    row_patch.deinit(std.heap.page_allocator);
                    return;
                };
            }
        }
    }
};

fn colorEq(a: host.HostColor, b: host.HostColor) bool {
    return a.kind == b.kind and
        a.palette_index == b.palette_index and
        a.red == b.red and
        a.green == b.green and
        a.blue == b.blue and
        a.ansi_class == b.ansi_class and
        a.promoted_by_bold == b.promoted_by_bold;
}

fn snapshotShapeChanged(a: host.HostScreenSnapshot, b: *const host.HostScreenSnapshot) bool {
    return a.rows != b.rows or a.cols != b.cols or a.lines.len != b.lines.len;
}

fn lineEq(a: host.HostScreenLine, b: host.HostScreenLine) bool {
    if (a.eol != b.eol) return false;
    if (a.cells.len != b.cells.len) return false;

    var i: usize = 0;
    while (i < a.cells.len) : (i += 1) {
        if (!cellEq(a.cells[i], b.cells[i])) return false;
    }
    return true;
}

fn cellEq(a: host.HostScreenCell, b: host.HostScreenCell) bool {
    return a.width == b.width and
        a.hyperlink == b.hyperlink and
        colorEq(a.fg, b.fg) and
        colorEq(a.bg, b.bg) and
        attrsEq(a.attrs, b.attrs) and
        a.chars_len == b.chars_len and
        std.mem.eql(u32, a.chars[0..a.chars_len], b.chars[0..b.chars_len]);
}

fn attrsEq(a: host.HostCellAttrs, b: host.HostCellAttrs) bool {
    return a.bold == b.bold and
        a.italic == b.italic and
        a.underline == b.underline and
        a.blink == b.blink and
        a.reverse == b.reverse and
        a.conceal == b.conceal and
        a.strike == b.strike and
        a.font == b.font;
}

test "full frame patch builder clips rows to viewport height" {
    var renderer = Renderer{ .stdout_thread = undefined, .viewport = Viewport.init(0, 0, 2, 80) };
    var patch = ViewportPatch.init(true, std.testing.allocator);
    defer patch.deinit(std.testing.allocator);

    const line = host.HostScreenLine{ .cells = &.{}, .eol = true };
    const lines = [_]host.HostScreenLine{ line, line, line };
    const snapshot = host.HostScreenSnapshot{
        .rows = 3,
        .cols = 80,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = true,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = &.{},
        .lines = lines[0..],
    };

    renderer.tryBuildFullFramePatch(&patch, &snapshot);

    try std.testing.expectEqual(@as(usize, 2), patch.rows.items.len);
    try std.testing.expectEqual(@as(u16, 0), patch.rows.items[0].row);
    try std.testing.expectEqual(@as(u16, 1), patch.rows.items[1].row);
}

test "changed row patch builder clips rows to viewport height" {
    var renderer = Renderer{ .stdout_thread = undefined, .viewport = Viewport.init(0, 0, 2, 80) };
    var patch = ViewportPatch.init(false, std.testing.allocator);
    defer patch.deinit(std.testing.allocator);

    const unchanged = host.HostScreenCell{
        .chars = [_]u32{ 'a', 0, 0, 0, 0, 0 },
        .chars_len = 1,
        .width = 1,
        .attrs = .{},
        .fg = .{ .kind = .default },
        .bg = .{ .kind = .default },
        .hyperlink = 0,
    };
    const changed = host.HostScreenCell{
        .chars = [_]u32{ 'b', 0, 0, 0, 0, 0 },
        .chars_len = 1,
        .width = 1,
        .attrs = .{},
        .fg = .{ .kind = .default },
        .bg = .{ .kind = .default },
        .hyperlink = 0,
    };
    const prev_lines = [_]host.HostScreenLine{
        .{ .cells = &.{ unchanged }, .eol = true },
        .{ .cells = &.{ unchanged }, .eol = true },
        .{ .cells = &.{ unchanged }, .eol = true },
    };
    const next_lines = [_]host.HostScreenLine{
        .{ .cells = &.{ unchanged }, .eol = true },
        .{ .cells = &.{ changed }, .eol = true },
        .{ .cells = &.{ changed }, .eol = true },
    };
    const prev = host.HostScreenSnapshot{
        .rows = 3,
        .cols = 80,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = true,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = &.{},
        .lines = prev_lines[0..],
    };
    const next = host.HostScreenSnapshot{
        .rows = 3,
        .cols = 80,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = true,
        .alt_screen = false,
        .seq = 0,
        .hyperlinks = &.{},
        .lines = next_lines[0..],
    };

    renderer.tryBuildChangedRowsPatch(&patch, &prev, &next);

    try std.testing.expectEqual(@as(usize, 1), patch.rows.items.len);
    try std.testing.expectEqual(@as(u16, 1), patch.rows.items[0].row);
}

test "renderer clips virtual cursor to viewport before emitting patch" {
    var renderer = Renderer{ .stdout_thread = undefined, .viewport = Viewport.init(0, 0, 2, 3) };

    const clipped = renderer.clipVirtualCursor(.{
        .visible = true,
        .row = 9,
        .col = 7,
    });

    try std.testing.expectEqual(@as(u16, 1), clipped.row);
    try std.testing.expectEqual(@as(u16, 2), clipped.col);
    try std.testing.expect(clipped.visible);
}
