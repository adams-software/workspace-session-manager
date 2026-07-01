const std = @import("std");
const commands = @import("commands.zig");
const service_mod = @import("service.zig");

pub fn attachStateMessage(state: service_mod.AttachState) []const u8 {
    return switch (state) {
        .ready => "ready",
        .missing_data => "session data socket missing",
        .stale_data_socket => "session data socket stale",
        .stale_control_socket => "session control socket stale",
        .stale_both => "session data and control sockets stale",
        .data_not_connectable => "session data socket not connectable",
        .control_not_connectable => "session control socket not connectable",
    };
}

pub fn createInvalidIdReasonLabel(reason: commands.CreateInvalidIdReason) []const u8 {
    return switch (reason) {
        .empty => "Empty",
        .starts_with_slash => "StartsWithSlash",
        .ends_with_slash => "EndsWithSlash",
        .empty_segment => "EmptySegment",
        .dot_segment => "DotSegment",
        .invalid_char => "InvalidChar",
    };
}

pub fn formatAttachOutcome(allocator: std.mem.Allocator, outcome: commands.AttachOutcome, query: []const u8, suffix: []const u8) ![]u8 {
    return switch (outcome) {
        .ready => unreachable,
        .no_sessions => try std.fmt.allocPrint(allocator, "no sessions found; press c to create one{s}", .{suffix}),
        .no_match => try std.fmt.allocPrint(allocator, "no session matching '{s}'{s}", .{ query, suffix }),
        .ambiguous => try std.fmt.allocPrint(allocator, "ambiguous session '{s}'{s}", .{ query, suffix }),
        .not_attachable => |payload| try std.fmt.allocPrint(allocator, "session '{s}' is not attachable: {s}{s}", .{ payload.id, attachStateMessage(payload.state), suffix }),
    };
}

pub fn formatBackOutcome(allocator: std.mem.Allocator, outcome: commands.BackOutcome, suffix: []const u8) ![]u8 {
    return switch (outcome) {
        .ready => unreachable,
        .no_previous_session => try std.fmt.allocPrint(allocator, "no previous session{s}", .{suffix}),
        .not_attachable => |payload| try std.fmt.allocPrint(allocator, "session '{s}' is not attachable: {s}{s}", .{ payload.id, attachStateMessage(payload.state), suffix }),
    };
}

pub fn formatNavOutcome(allocator: std.mem.Allocator, outcome: commands.NavOutcome, suffix: []const u8) ![]u8 {
    return switch (outcome) {
        .ready => unreachable,
        .no_target => try std.fmt.allocPrint(allocator, "no target{s}", .{suffix}),
        .not_attachable => |payload| try std.fmt.allocPrint(allocator, "session '{s}' is not attachable: {s}{s}", .{ payload.id, attachStateMessage(payload.state), suffix }),
    };
}

pub fn formatCreateInvalidId(allocator: std.mem.Allocator, reason: commands.CreateInvalidIdReason, suffix: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "invalid id: {s}{s}", .{ createInvalidIdReasonLabel(reason), suffix });
}

pub fn formatKillOutcome(allocator: std.mem.Allocator, outcome: commands.KillOutcome, suffix: []const u8) ![]u8 {
    return switch (outcome) {
        .signaled => |sig| try std.fmt.allocPrint(allocator, "sent {s}{s}", .{ if (sig == .kill) "KILL" else "TERM", suffix }),
        .no_current_session => try std.fmt.allocPrint(allocator, "no current session{s}", .{suffix}),
        .no_control => try std.fmt.allocPrint(allocator, "kill failed: session has no control socket{s}", .{suffix}),
    };
}

pub fn formatKillOutcomeForId(allocator: std.mem.Allocator, id: []const u8, outcome: commands.KillOutcome, suffix: []const u8) ![]u8 {
    return switch (outcome) {
        .signaled => |sig| try std.fmt.allocPrint(allocator, "signaled {s} ({s}){s}", .{ id, if (sig == .kill) "KILL" else "TERM", suffix }),
        .no_current_session => try std.fmt.allocPrint(allocator, "kill failed: no current session{s}", .{suffix}),
        .no_control => try std.fmt.allocPrint(allocator, "kill failed for {s}: session has no control socket{s}", .{ id, suffix }),
    };
}
