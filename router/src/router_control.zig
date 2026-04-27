const std = @import("std");
const router_runtime = @import("router_runtime");

pub const Command = union(enum) {
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
    err_parse: ParseError,
    err_runtime: RuntimeError,
    state: router_runtime.RouterState,
};

pub fn parse(line: []const u8) Parsed {
    var iter = std.mem.tokenizeScalar(u8, line, ' ');
    const head = iter.next() orelse return .{ .err = .invalid_command };

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
            .control_path = control_path orelse return .{ .err = .missing_control },
        } } };
    }
    return .{ .err = .invalid_command };
}

pub fn execute(runtime: *router_runtime.RouterRuntime, command: Command) Result {
    switch (command) {
        .attach => |spec| {
            runtime.attach(spec) catch |err| return .{ .err_runtime = mapRuntimeError(err) };
            return .ok;
        },
        .detach => {
            runtime.detach() catch |err| return .{ .err_runtime = mapRuntimeError(err) };
            return .ok;
        },
        .state => return .{ .state = runtime.state() },
        .exit => {
            runtime.should_exit = true;
            return .ok;
        },
    }
}

pub fn printResult(writer: anytype, result: Result) !void {
    switch (result) {
        .ok => try writer.writeAll("ok\n"),
        .err_parse => |err| try writer.print("err {s}\n", .{@tagName(err)}),
        .err_runtime => |err| try writer.print("err {s}\n", .{@tagName(err)}),
        .state => |state| {
            if (!state.attached) {
                try writer.print("ok attached=false control={s}\n", .{state.control_path});
            } else {
                try writer.print(
                    "ok attached=true control={s} data={s} target_control={s}\n",
                    .{ state.control_path, state.data_path.?, state.target_control_path.? },
                );
            }
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

test "router_control parse attach requires both paths" {
    try std.testing.expect(parse("attach data=/tmp/a") == .err);
    try std.testing.expect(parse("attach control=/tmp/b") == .err);
    const parsed = parse("attach data=/tmp/a control=/tmp/b");
    try std.testing.expect(parsed == .command);
    try std.testing.expect(parsed.command == .attach);
    try std.testing.expectEqualStrings("/tmp/a", parsed.command.attach.data_path);
    try std.testing.expectEqualStrings("/tmp/b", parsed.command.attach.control_path);
}

test "router_control execute state shows unattached" {
    var runtime = try router_runtime.RouterRuntime.init(std.testing.allocator, "/tmp/router.sock");
    defer runtime.deinit();

    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    var writer = buf.writer(std.testing.allocator);

    try printResult(&writer, execute(&runtime, .state));
    try std.testing.expectEqualStrings("ok attached=false control=/tmp/router.sock\n", buf.items);
}
