const std = @import("std");
const ctlwire = @import("ctlwire");
const router_runtime = @import("router_runtime");

pub const Command = union(enum) {
    help,
    attach: router_runtime.AttachSpec,
    detach,
    state,
    exit,
};

pub const ParseError = enum {
    invalid_command,
    invalid_args,
    missing_data,
    missing_control,
};

pub const RuntimeError = enum {
    already_attached,
    not_attached,
    out_of_memory,
    connect_failed,
};

pub const Parsed = union(enum) {
    command: Command,
    err: ParseError,
};

pub const Result = union(enum) {
    ok,
    help: []const u8,
    err_parse: ParseError,
    err_runtime: RuntimeError,
    state: router_runtime.RouterState,
};

pub fn parse(line: []const u8) Parsed {
    var iter = std.mem.tokenizeScalar(u8, line, ' ');
    const head = iter.next() orelse return .{ .err = .invalid_command };

    if (std.mem.eql(u8, head, "help")) return .{ .command = .help };
    if (std.mem.eql(u8, head, "detach")) return .{ .command = .detach };
    if (std.mem.eql(u8, head, "state")) return .{ .command = .state };
    if (std.mem.eql(u8, head, "exit")) return .{ .command = .exit };
    if (std.mem.eql(u8, head, "attach")) {
        var data_path: ?[]const u8 = null;
        var control_path: ?[]const u8 = null;
        while (iter.next()) |token| {
            const eq = std.mem.indexOfScalar(u8, token, '=') orelse return .{ .err = .invalid_args };
            const key = token[0..eq];
            const value = token[(eq + 1)..];
            if (std.mem.eql(u8, key, "data")) {
                data_path = value;
            } else if (std.mem.eql(u8, key, "control")) {
                control_path = value;
            } else {
                return .{ .err = .invalid_args };
            }
        }
        return .{ .command = .{ .attach = .{
            .data_path = data_path orelse return .{ .err = .missing_data },
            .control_path = control_path,
        } } };
    }
    return .{ .err = .invalid_command };
}

pub const help_text =
    "commands: help, state, attach data=<path> [control=<path>], detach, exit";

pub fn executeRuntimeOnly(runtime: *router_runtime.RouterRuntime, command: Command) Result {
    switch (command) {
        .help => return .{ .help = help_text },
        .state => return .{ .state = runtime.state() },
        .exit => {
            runtime.should_exit = true;
            return .ok;
        },
        .attach, .detach => @panic("attach/detach require session coordination and must not use executeRuntimeOnly"),
    }
}

pub fn applyAttach(runtime: *router_runtime.RouterRuntime, spec: router_runtime.AttachSpec) Result {
    runtime.attach(spec) catch |err| return .{ .err_runtime = mapRuntimeError(err) };
    return .ok;
}

pub fn applyDetach(runtime: *router_runtime.RouterRuntime) Result {
    runtime.detach() catch |err| return .{ .err_runtime = mapRuntimeError(err) };
    return .ok;
}

pub fn printResult(writer: anytype, result: Result) !void {
    switch (result) {
        .ok => try ctlwire.message.writeOk(writer),
        .help => |text| try ctlwire.message.writeOkPayload(writer, text),
        .err_parse => |err| try ctlwire.message.writeErr(writer, .{ .kind = @tagName(err) }),
        .err_runtime => |err| try ctlwire.message.writeErr(writer, .{ .kind = @tagName(err) }),
        .state => |state| {
            var buf: [256]u8 = undefined;
            const payload = if (!state.attached)
                try std.fmt.bufPrint(&buf, "attached=false control={s}", .{state.control_path})
            else
                try std.fmt.bufPrint(&buf, "attached=true control={s} data={s} target_control={s}", .{ state.control_path, state.data_path.?, state.target_control_path.? });
            try ctlwire.message.writeOkPayload(writer, payload);
        },
    }
}

fn mapRuntimeError(err: anyerror) RuntimeError {
    return switch (err) {
        router_runtime.Error.AlreadyAttached => .already_attached,
        router_runtime.Error.NotAttached => .not_attached,
        router_runtime.Error.OutOfMemory => .out_of_memory,
        else => .out_of_memory,
    };
}

test "router_control parse attach requires data and accepts optional control" {
    try std.testing.expect(parse("attach") == .err);
    try std.testing.expect(parse("attach control=/tmp/b") == .err);
    {
        const parsed = parse("attach data=/tmp/a");
        try std.testing.expect(parsed == .command);
        try std.testing.expect(parsed.command == .attach);
        try std.testing.expectEqualStrings("/tmp/a", parsed.command.attach.data_path);
        try std.testing.expect(parsed.command.attach.control_path == null);
    }
    {
        const parsed = parse("attach data=/tmp/a control=/tmp/b");
        try std.testing.expect(parsed == .command);
        try std.testing.expect(parsed.command == .attach);
        try std.testing.expectEqualStrings("/tmp/a", parsed.command.attach.data_path);
        try std.testing.expectEqualStrings("/tmp/b", parsed.command.attach.control_path.?);
    }
}

test "router_control execute state shows unattached" {
    var runtime = try router_runtime.RouterRuntime.init(std.testing.allocator, "/tmp/router.sock");
    defer runtime.deinit();

    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    var writer = buf.writer(std.testing.allocator);

    try printResult(&writer, executeRuntimeOnly(&runtime, .state));
    try std.testing.expectEqualStrings("ok attached=false control=/tmp/router.sock\n", buf.items);
}
