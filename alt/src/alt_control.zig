const std = @import("std");

pub const Command = union(enum) {
    help,
    state,
    switch_to: usize,
    cycle,
    exit,
};

pub const Result = union(enum) {
    ok,
    payload: []const u8,
    err: Error,
};

pub const Error = enum {
    invalid_command,
    invalid_args,
};

pub const ResultOrCommand = union(enum) {
    command: Command,
    err: Error,
};

pub fn parse(line: []const u8) ResultOrCommand {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const head = it.next() orelse return .{ .err = .invalid_command };

    if (std.mem.eql(u8, head, "help")) {
        if (it.next() != null) return .{ .err = .invalid_args };
        return .{ .command = .help };
    }
    if (std.mem.eql(u8, head, "state")) {
        if (it.next() != null) return .{ .err = .invalid_args };
        return .{ .command = .state };
    }
    if (std.mem.eql(u8, head, "cycle")) {
        if (it.next() != null) return .{ .err = .invalid_args };
        return .{ .command = .cycle };
    }
    if (std.mem.eql(u8, head, "exit")) {
        if (it.next() != null) return .{ .err = .invalid_args };
        return .{ .command = .exit };
    }
    if (std.mem.eql(u8, head, "switch")) {
        const idx_text = it.next() orelse return .{ .err = .invalid_args };
        if (it.next() != null) return .{ .err = .invalid_args };
        const idx = std.fmt.parseInt(usize, idx_text, 10) catch return .{ .err = .invalid_args };
        return .{ .command = .{ .switch_to = idx } };
    }
    return .{ .err = .invalid_command };
}

test "alt_control parses core commands" {
    try std.testing.expect(parse("help") == .command);
    try std.testing.expect(parse("state") == .command);
    try std.testing.expect(parse("cycle") == .command);
    try std.testing.expect(parse("exit") == .command);

    const parsed = parse("switch 1");
    try std.testing.expect(parsed == .command);
    switch (parsed.command) {
        .switch_to => |idx| try std.testing.expectEqual(@as(usize, 1), idx),
        else => return error.TestUnexpectedResult,
    }
}

test "alt_control rejects bad commands and args" {
    try std.testing.expectEqual(Error.invalid_command, parse("wat").err);
    try std.testing.expectEqual(Error.invalid_args, parse("switch").err);
    try std.testing.expectEqual(Error.invalid_args, parse("switch x").err);
    try std.testing.expectEqual(Error.invalid_args, parse("state extra").err);
}
