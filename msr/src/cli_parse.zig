const std = @import("std");
const argv_parse = @import("argv_parse");
const command_spec = @import("command_spec");
const c = @cImport({
    @cInclude("stdlib.h");
});

pub const CommandKind = enum {
    help,
    current,
    create,
    attach,
    detach,
    resize,
    terminate,
    wait,
    status,
    exists,
};

pub const ParseFailure = struct {
    kind: Kind,
    command: ?CommandKind = null,

    pub const Kind = enum {
        no_command,
        unknown_command,
        missing_argument,
        invalid_argument,
        unexpected_argument,
        unsupported_option,
    };
};

pub const ParsedCli = struct {
    current_session: ?[]const u8,
    command: Command,

    pub fn deinit(self: *ParsedCli, allocator: std.mem.Allocator) void {
        switch (self.command) {
            .create => |args| {
                if (args.child_argv) |tail| allocator.free(tail);
            },
            else => {},
        }
    }
};

pub const Command = union(enum) {
    help,
    current,
    create: CreateArgs,
    attach: AttachArgs,
    detach,
    resize: ResizeArgs,
    terminate: TerminateArgs,
    wait: PathArgs,
    status: PathArgs,
    exists: PathArgs,
};

pub const PathArgs = struct { path: []const u8 };
pub const CreateArgs = struct {
    path: []const u8,
    attach_after_create: bool,
    vterm: bool,
    child_argv: ?[]const []const u8,
};
pub const AttachArgs = struct {
    target: []const u8,
    force: bool,
};
pub const ResizeArgs = struct {
    path: []const u8,
    cols: u16,
    rows: u16,
    force: bool,
};
pub const SignalSpec = enum { term, int, kill };
pub const TerminateArgs = struct {
    path: []const u8,
    signal: SignalSpec,
};

fn commandKindFor(name: []const u8) ?CommandKind {
    if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) return .help;
    if (command_spec.findCommandByAlias(name)) |cmd| {
        return switch (cmd.id) {
            .help => .help,
            .current => .current,
            .create => .create,
            .attach => .attach,
            .detach => .detach,
            .resize => .resize,
            .terminate => .terminate,
            .wait => .wait,
            .status => .status,
            .exists => .exists,
        };
    }
    return null;
}

fn parseU16(s: []const u8) ?u16 {
    return std.fmt.parseInt(u16, s, 10) catch null;
}

fn signalFromString(s: []const u8) ?SignalSpec {
    if (std.mem.eql(u8, s, "TERM")) return .term;
    if (std.mem.eql(u8, s, "INT")) return .int;
    if (std.mem.eql(u8, s, "KILL")) return .kill;
    return null;
}

fn optionHasValue(parsed: argv_parse.ParsedArgv, aliases: []const []const u8) bool {
    for (parsed.options) |opt| {
        for (aliases) |alias| {
            if (std.mem.eql(u8, opt.name, alias) and opt.value != null) return true;
        }
    }
    return false;
}

fn specForKind(cmd_kind: CommandKind) ?*const command_spec.CommandSpec {
    return switch (cmd_kind) {
        .help => command_spec.findCommandById(.help),
        .current => command_spec.findCommandById(.current),
        .create => command_spec.findCommandById(.create),
        .attach => command_spec.findCommandById(.attach),
        .detach => command_spec.findCommandById(.detach),
        .resize => command_spec.findCommandById(.resize),
        .terminate => command_spec.findCommandById(.terminate),
        .wait => command_spec.findCommandById(.wait),
        .status => command_spec.findCommandById(.status),
        .exists => command_spec.findCommandById(.exists),
    };
}

fn hasFlag(parsed: argv_parse.ParsedArgv, cmd_kind: CommandKind, alias: []const u8) bool {
    const spec = specForKind(cmd_kind) orelse return false;

    if (!command_spec.hasFlagAlias(spec, alias)) return false;
    return argv_parse.hasOption(parsed, &.{alias});
}

fn flagHasUnexpectedValue(parsed: argv_parse.ParsedArgv, cmd_kind: CommandKind, alias: []const u8) bool {
    const spec = specForKind(cmd_kind) orelse return false;

    if (!command_spec.hasFlagAlias(spec, alias)) return false;
    return optionHasValue(parsed, &.{alias});
}

fn envCurrentSession() ?[]const u8 {
    const raw = c.getenv("MSR_SESSION") orelse return null;
    return std.mem.span(raw);
}

pub fn parseArgv(allocator: std.mem.Allocator, argv: []const []const u8) (std.mem.Allocator.Error || error{})!union(enum) { ok: ParsedCli, fail: ParseFailure } {
    const parsed = argv_parse.parseArgv(allocator, argv) catch return .{ .fail = .{ .kind = .invalid_argument, .command = null } };
    defer allocator.free(parsed.options);
    defer allocator.free(parsed.positionals);
    defer if (parsed.literal_tail) |tail| allocator.free(tail);

    if (parsed.command == null) return .{ .fail = .{ .kind = .no_command } };

    var current_session: ?[]const u8 = envCurrentSession();
    if (argv_parse.findOption(parsed, &.{ "session" })) |opt| {
        if (opt.value == null) return .{ .fail = .{ .kind = .missing_argument, .command = null } };
        current_session = opt.value.?;
    }

    const kind = commandKindFor(parsed.command.?) orelse return .{ .fail = .{ .kind = .unknown_command } };

    switch (kind) {
        .help => return .{ .ok = .{ .current_session = current_session, .command = .help } },
        .current => {
            if (parsed.positionals.len != 0) return .{ .fail = .{ .kind = .unexpected_argument, .command = .current } };
            return .{ .ok = .{ .current_session = current_session, .command = .current } };
        },
        .detach => {
            if (parsed.positionals.len != 0) return .{ .fail = .{ .kind = .unexpected_argument, .command = .detach } };
            return .{ .ok = .{ .current_session = current_session, .command = .detach } };
        },
        .create => {
            if (flagHasUnexpectedValue(parsed, .create, "a") or flagHasUnexpectedValue(parsed, .create, "attach")) return .{ .fail = .{ .kind = .unexpected_argument, .command = .create } };
            const attach_after_create = hasFlag(parsed, .create, "a") or hasFlag(parsed, .create, "attach");
            if (flagHasUnexpectedValue(parsed, .create, "vterm")) return .{ .fail = .{ .kind = .unexpected_argument, .command = .create } };
            const vterm = hasFlag(parsed, .create, "vterm");
            if (parsed.positionals.len != 1) return .{ .fail = .{ .kind = .missing_argument, .command = .create } };
            return .{ .ok = .{ .current_session = current_session, .command = .{ .create = .{
                .path = parsed.positionals[0],
                .attach_after_create = attach_after_create,
                .vterm = vterm,
                .child_argv = if (parsed.literal_tail) |tail| try allocator.dupe([]const u8, tail) else null,
            } } } };
        },
        .attach => {
            if (flagHasUnexpectedValue(parsed, .attach, "f") or flagHasUnexpectedValue(parsed, .attach, "force")) return .{ .fail = .{ .kind = .unexpected_argument, .command = .attach } };
            const force = hasFlag(parsed, .attach, "f") or hasFlag(parsed, .attach, "force");
            if (parsed.positionals.len != 1) return .{ .fail = .{ .kind = .missing_argument, .command = .attach } };
            return .{ .ok = .{ .current_session = current_session, .command = .{ .attach = .{ .target = parsed.positionals[0], .force = force } } } };
        },
        .resize => {
            if (flagHasUnexpectedValue(parsed, .resize, "f") or flagHasUnexpectedValue(parsed, .resize, "force")) return .{ .fail = .{ .kind = .unexpected_argument, .command = .resize } };
            const force = hasFlag(parsed, .resize, "f") or hasFlag(parsed, .resize, "force");
            if (parsed.positionals.len != 3) return .{ .fail = .{ .kind = .missing_argument, .command = .resize } };
            const cols = parseU16(parsed.positionals[1]) orelse return .{ .fail = .{ .kind = .invalid_argument, .command = .resize } };
            const rows = parseU16(parsed.positionals[2]) orelse return .{ .fail = .{ .kind = .invalid_argument, .command = .resize } };
            return .{ .ok = .{ .current_session = current_session, .command = .{ .resize = .{ .path = parsed.positionals[0], .cols = cols, .rows = rows, .force = force } } } };
        },
        .terminate => {
            if (flagHasUnexpectedValue(parsed, .terminate, "f") or flagHasUnexpectedValue(parsed, .terminate, "force")) return .{ .fail = .{ .kind = .unexpected_argument, .command = .terminate } };
            const force = hasFlag(parsed, .terminate, "f") or hasFlag(parsed, .terminate, "force");
            if (parsed.positionals.len < 1 or parsed.positionals.len > 2) return .{ .fail = .{ .kind = .missing_argument, .command = .terminate } };
            const sig: SignalSpec = if (force) .kill else if (parsed.positionals.len == 2) signalFromString(parsed.positionals[1]) orelse return .{ .fail = .{ .kind = .invalid_argument, .command = .terminate } } else .term;
            return .{ .ok = .{ .current_session = current_session, .command = .{ .terminate = .{ .path = parsed.positionals[0], .signal = sig } } } };
        },
        .wait => {
            if (parsed.positionals.len != 1) return .{ .fail = .{ .kind = .missing_argument, .command = .wait } };
            return .{ .ok = .{ .current_session = current_session, .command = .{ .wait = .{ .path = parsed.positionals[0] } } } };
        },
        .status => {
            if (parsed.positionals.len != 1) return .{ .fail = .{ .kind = .missing_argument, .command = .status } };
            return .{ .ok = .{ .current_session = current_session, .command = .{ .status = .{ .path = parsed.positionals[0] } } } };
        },
        .exists => {
            if (parsed.positionals.len != 1) return .{ .fail = .{ .kind = .missing_argument, .command = .exists } };
            return .{ .ok = .{ .current_session = current_session, .command = .{ .exists = .{ .path = parsed.positionals[0] } } } };
        },
    }
}

test "cli_parse parses create with attach flag after path" {
    const argv = [_][]const u8{ "c", "/tmp/x", "-a" };
    const res = try parseArgv(std.testing.allocator, argv[0..]);
    switch (res) {
        .ok => |ok| switch (ok.command) {
            .create => |cargs| {
                try std.testing.expectEqualStrings("/tmp/x", cargs.path);
                try std.testing.expect(cargs.attach_after_create);
                try std.testing.expect(!cargs.vterm);
            },
            else => return error.UnexpectedResult,
        },
        .fail => return error.UnexpectedResult,
    }
}

test "cli_parse parses spaced session option" {
    const argv = [_][]const u8{ "current", "--session", "/tmp/x" };
    const res = try parseArgv(std.testing.allocator, argv[0..]);
    switch (res) {
        .ok => |ok| {
            try std.testing.expectEqualStrings("/tmp/x", ok.current_session.?);
            try std.testing.expect(ok.command == .current);
        },
        .fail => return error.UnexpectedResult,
    }
}

test "cli_parse parses basic create" {
    const argv = [_][]const u8{ "c", "/tmp/x" };
    const res = try parseArgv(std.testing.allocator, argv[0..]);
    switch (res) {
        .ok => |ok| switch (ok.command) {
            .create => |cargs| {
                try std.testing.expectEqualStrings("/tmp/x", cargs.path);
                try std.testing.expect(!cargs.attach_after_create);
                try std.testing.expect(!cargs.vterm);
                try std.testing.expect(cargs.child_argv == null);
            },
            else => return error.UnexpectedResult,
        },
        .fail => |f| {
            std.debug.print("unexpected fail: {any}\n", .{f});
            return error.UnexpectedResult;
        },
    }
}

test "cli_parse parses long create alias" {
    const argv = [_][]const u8{ "create", "/tmp/x" };
    const res = try parseArgv(std.testing.allocator, argv[0..]);
    switch (res) {
        .ok => |ok| switch (ok.command) {
            .create => |cargs| {
                try std.testing.expectEqualStrings("/tmp/x", cargs.path);
                try std.testing.expect(!cargs.vterm);
            },
            else => return error.UnexpectedResult,
        },
        .fail => |f| {
            std.debug.print("unexpected fail: {any}\n", .{f});
            return error.UnexpectedResult;
        },
    }
}


test "cli_parse parses create with vterm flag" {
    const argv = [_][]const u8{ "create", "--vterm", "/tmp/x" };
    const res = try parseArgv(std.testing.allocator, argv[0..]);
    switch (res) {
        .ok => |ok| switch (ok.command) {
            .create => |cargs| {
                try std.testing.expectEqualStrings("/tmp/x", cargs.path);
                try std.testing.expect(cargs.vterm);
                try std.testing.expect(!cargs.attach_after_create);
            },
            else => return error.UnexpectedResult,
        },
        .fail => |f| {
            std.debug.print("unexpected fail: {any}\n", .{f});
            return error.UnexpectedResult;
        },
    }
}

test "cli_parse parses inline session option before command" {
    const argv = [_][]const u8{ "--session=/tmp/x", "current" };
    const res = try parseArgv(std.testing.allocator, argv[0..]);
    switch (res) {
        .ok => |ok| {
            try std.testing.expectEqualStrings("/tmp/x", ok.current_session.?);
            try std.testing.expect(ok.command == .current);
        },
        .fail => |f| {
            std.debug.print("unexpected fail: {any}\n", .{f});
            return error.UnexpectedResult;
        },
    }
}
