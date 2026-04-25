const std = @import("std");
const host_runtime = @import("host_runtime");

pub const Command = union(enum) {
    state,
    resize: host_runtime.Size,
    signal: host_runtime.Signal,
    exit,
};

pub const Result = union(enum) {
    ok,
    state: host_runtime.HostState,
    err: Error,
};

pub const Error = enum {
    invalid_command,
    invalid_args,
    invalid_state,
};

pub fn execute(runtime: *host_runtime.HostRuntime, command: Command) Result {
    return switch (command) {
        .state => .{ .state = runtime.state() },
        .resize => |size| blk: {
            runtime.resize(size.cols, size.rows) catch |e| {
                break :blk .{ .err = mapRuntimeError(e) };
            };
            break :blk .ok;
        },
        .signal => |sig| blk: {
            _ = runtime.sendSignal(sig) catch |e| {
                break :blk .{ .err = mapRuntimeError(e) };
            };
            break :blk .ok;
        },
        .exit => blk: {
            runtime.requestExit() catch |e| {
                break :blk .{ .err = mapRuntimeError(e) };
            };
            break :blk .ok;
        },
    };
}

pub fn parse(line: []const u8) ResultOrCommand {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const head = it.next() orelse return .{ .err = .invalid_command };

    if (std.mem.eql(u8, head, "state")) {
        if (it.next() != null) return .{ .err = .invalid_args };
        return .{ .command = .state };
    }

    if (std.mem.eql(u8, head, "resize")) {
        const cols_text = it.next() orelse return .{ .err = .invalid_args };
        const rows_text = it.next() orelse return .{ .err = .invalid_args };
        if (it.next() != null) return .{ .err = .invalid_args };

        const cols = std.fmt.parseInt(u16, cols_text, 10) catch return .{ .err = .invalid_args };
        const rows = std.fmt.parseInt(u16, rows_text, 10) catch return .{ .err = .invalid_args };
        if (cols == 0 or rows == 0) return .{ .err = .invalid_args };

        return .{ .command = .{ .resize = .{ .cols = cols, .rows = rows } } };
    }

    if (std.mem.eql(u8, head, "signal")) {
        const sig_text = it.next() orelse return .{ .err = .invalid_args };
        if (it.next() != null) return .{ .err = .invalid_args };
        const sig = parseSignal(sig_text) orelse return .{ .err = .invalid_args };
        return .{ .command = .{ .signal = sig } };
    }

    if (std.mem.eql(u8, head, "exit")) {
        if (it.next() != null) return .{ .err = .invalid_args };
        return .{ .command = .exit };
    }

    return .{ .err = .invalid_command };
}

pub const ResultOrCommand = union(enum) {
    command: Command,
    err: Error,
};

fn parseSignal(text: []const u8) ?host_runtime.Signal {
    if (std.mem.eql(u8, text, "term")) return .term;
    if (std.mem.eql(u8, text, "int")) return .int;
    if (std.mem.eql(u8, text, "kill")) return .kill;
    return null;
}

fn mapRuntimeError(err: anyerror) Error {
    return switch (err) {
        host_runtime.Error.InvalidArgs => .invalid_args,
        host_runtime.Error.InvalidState => .invalid_state,
        else => .invalid_state,
    };
}

test "host_control parses core commands" {
    {
        const parsed = parse("state");
        try std.testing.expect(parsed == .command);
        try std.testing.expect(parsed.command == .state);
    }
    {
        const parsed = parse("resize 120 40");
        try std.testing.expect(parsed == .command);
        switch (parsed.command) {
            .resize => |size| {
                try std.testing.expectEqual(@as(u16, 120), size.cols);
                try std.testing.expectEqual(@as(u16, 40), size.rows);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const parsed = parse("signal term");
        try std.testing.expect(parsed == .command);
        switch (parsed.command) {
            .signal => |sig| try std.testing.expect(sig == .term),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const parsed = parse("exit");
        try std.testing.expect(parsed == .command);
        try std.testing.expect(parsed.command == .exit);
    }
}

test "host_control rejects bad commands and args" {
    try std.testing.expectEqual(Error.invalid_command, parse("wat").err);
    try std.testing.expectEqual(Error.invalid_args, parse("resize 10").err);
    try std.testing.expectEqual(Error.invalid_args, parse("resize 0 40").err);
    try std.testing.expectEqual(Error.invalid_args, parse("signal no").err);
}

test "host_control execute updates runtime state" {
    var runtime = try host_runtime.HostRuntime.init(std.testing.allocator, "/tmp/test.sock", null);
    defer runtime.deinit();

    runtime.onSocketListening();
    runtime.onChildStarted(123);

    {
        const res = execute(&runtime, .state);
        try std.testing.expect(res == .state);
    }
    {
        const res = execute(&runtime, .{ .resize = .{ .cols = 90, .rows = 30 } });
        try std.testing.expect(res == .ok);
        try std.testing.expect(runtime.state().size != null);
        try std.testing.expectEqual(@as(u16, 90), runtime.state().size.?.cols);
    }
    {
        const res = execute(&runtime, .exit);
        try std.testing.expect(res == .ok);
        try std.testing.expectEqual(host_runtime.HostPhase.exiting, runtime.state().host_phase);
    }
}
