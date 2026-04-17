const std = @import("std");

pub const ValueKind = enum {
    none,
    string,
    u16,
    signal,
    path,
    command_tail,
};

pub const ArgCardinality = enum {
    required,
    optional,
    repeated,
};

pub const ContextBehavior = enum {
    normal,
    requires_current_session,
    meaning_changes_with_current_session,
};

pub const CommandId = enum {
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

pub const PositionalSpec = struct {
    name: []const u8,
    kind: ValueKind,
    cardinality: ArgCardinality = .required,
    help: []const u8,
};

pub const FlagSpec = struct {
    long: []const u8,
    short: ?u8 = null,
    value_name: ?[]const u8 = null,
    kind: ValueKind = .none,
    help: []const u8,
};

pub const ExampleSpec = struct {
    command: []const u8,
    help: []const u8,
};

pub const CommandSpec = struct {
    id: CommandId,
    name: []const u8,
    aliases: []const []const u8,
    summary: []const u8,
    description: []const u8,
    positionals: []const PositionalSpec,
    flags: []const FlagSpec,
    examples: []const ExampleSpec,
    context_behavior: ContextBehavior = .normal,
};

pub fn hasFlagAlias(cmd: *const CommandSpec, alias: []const u8) bool {
    for (cmd.flags) |flag| {
        if (std.mem.eql(u8, flag.long, alias)) return true;
        if (flag.short) |short| {
            var buf: [1]u8 = .{short};
            if (std.mem.eql(u8, buf[0..], alias)) return true;
        }
    }
    return false;
}

pub fn usageLine(cmd: *const CommandSpec) []const u8 {
    switch (cmd.id) {
        .create => return "  msr create [--wait-attach] <path> [-- <cmd...>]\n",
        .attach => return "  msr attach [-f|--force] <path>\n",
        .detach => return "  msr detach\n",
        .current => return "  msr current\n",
        .resize => return "  msr resize [-f|--force] <path> <cols> <rows>\n",
        .terminate => return "  msr terminate [-f|--force] <path> [TERM|INT|KILL]\n",
        .wait => return "  msr wait <path>\n",
        .status => return "  msr status <path>\n",
        .exists => return "  msr exists <path>\n",
        .help => return "  msr help\n",
    }
}

pub fn aliasSummary(allocator: std.mem.Allocator, cmd: *const CommandSpec) ![]u8 {
    var list = std.ArrayList(u8){};
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "  ");
    try list.appendSlice(allocator, cmd.aliases[0]);
    for (cmd.aliases[1..]) |alias| {
        try list.appendSlice(allocator, ", ");
        try list.appendSlice(allocator, alias);
    }
    try list.appendSlice(allocator, "  ");
    try list.appendSlice(allocator, cmd.summary);
    try list.append(allocator, '\n');
    return try list.toOwnedSlice(allocator);
}

pub fn shortUsage(id: CommandId) []const u8 {
    for (&commands) |*cmd| {
        if (cmd.id == id) {
            return usageLine(cmd);
        }
    }
    return "";
}

pub const create_flags = [_]FlagSpec{
    .{ .long = "wait-attach", .help = "delay child startup until the first attach/owner is present" },
};

pub const create_positionals = [_]PositionalSpec{
    .{ .name = "path", .kind = .path, .help = "session socket path" },
    .{ .name = "cmd", .kind = .command_tail, .cardinality = .optional, .help = "command to run after --; defaults to $SHELL -i" },
};

pub const attach_flags = [_]FlagSpec{
    .{ .long = "force", .short = 'f', .help = "take over ownership when direct attach requires it" },
};

pub const resize_flags = [_]FlagSpec{
    .{ .long = "force", .short = 'f', .help = "take ownership before resizing" },
};

pub const terminate_flags = [_]FlagSpec{
    .{ .long = "force", .short = 'f', .help = "send KILL immediately" },
};

pub const one_path_positional = [_]PositionalSpec{
    .{ .name = "path", .kind = .path, .help = "session socket path" },
};

pub const resize_positionals = [_]PositionalSpec{
    .{ .name = "path", .kind = .path, .help = "session socket path" },
    .{ .name = "cols", .kind = .u16, .help = "terminal columns" },
    .{ .name = "rows", .kind = .u16, .help = "terminal rows" },
};

pub const terminate_positionals = [_]PositionalSpec{
    .{ .name = "path", .kind = .path, .help = "session socket path" },
    .{ .name = "signal", .kind = .signal, .cardinality = .optional, .help = "TERM, INT, or KILL" },
};

pub const commands = [_]CommandSpec{
    .{
        .id = .create,
        .name = "create",
        .aliases = &.{ "c", "create" },
        .summary = "create a session",
        .description = "Creates a persistent PTY-backed session at the given socket path. By default the child starts immediately and the command returns without attaching. Use --wait-attach to delay child startup until the first attach/owner is present. If no command is provided after --, the default interactive shell is used.",
        .positionals = &create_positionals,
        .flags = &create_flags,
        .examples = &.{
            .{ .command = "msr c /tmp/dev.sock", .help = "create a session using the default interactive shell" },
            .{ .command = "msr c --wait-attach /tmp/dev.sock -- nvim", .help = "create a session that waits for first attach before starting" },
        },
    },
    .{
        .id = .attach,
        .name = "attach",
        .aliases = &.{ "a", "attach" },
        .summary = "attach to a session",
        .description = "Direct attach uses ownership rules. When a current session is selected, attach routes through that session owner instead.",
        .positionals = &one_path_positional,
        .flags = &attach_flags,
        .examples = &.{
            .{ .command = "msr a /tmp/dev.sock", .help = "attach directly" },
            .{ .command = "MSR_SESSION=/tmp/current.sock msr a /tmp/other.sock", .help = "route attach through current session" },
        },
        .context_behavior = .meaning_changes_with_current_session,
    },
    .{
        .id = .detach,
        .name = "detach",
        .aliases = &.{ "d", "detach" },
        .summary = "detach the current session",
        .description = "Detaches the current session owner. Requires current-session context.",
        .positionals = &.{},
        .flags = &.{},
        .examples = &.{
            .{ .command = "MSR_SESSION=/tmp/current.sock msr d", .help = "detach the current session" },
        },
        .context_behavior = .requires_current_session,
    },
    .{
        .id = .current,
        .name = "current",
        .aliases = &.{ "current" },
        .summary = "print the current session path",
        .description = "Prints the current session path. Requires current-session context.",
        .positionals = &.{},
        .flags = &.{},
        .examples = &.{
            .{ .command = "MSR_SESSION=/tmp/current.sock msr current", .help = "print the current session path" },
        },
        .context_behavior = .requires_current_session,
    },
    .{
        .id = .resize,
        .name = "resize",
        .aliases = &.{ "resize" },
        .summary = "resize a session PTY",
        .description = "Resizes the PTY for the given session. Ownership may be required unless force is used.",
        .positionals = &resize_positionals,
        .flags = &resize_flags,
        .examples = &.{
            .{ .command = "msr resize /tmp/dev.sock 120 40", .help = "resize normally" },
            .{ .command = "msr resize -f /tmp/dev.sock 120 40", .help = "force ownership before resizing" },
        },
    },
    .{
        .id = .terminate,
        .name = "terminate",
        .aliases = &.{ "terminate" },
        .summary = "send a signal to a session",
        .description = "Sends TERM by default. Use -f for KILL or pass TERM, INT, or KILL explicitly.",
        .positionals = &terminate_positionals,
        .flags = &terminate_flags,
        .examples = &.{
            .{ .command = "msr terminate /tmp/dev.sock", .help = "send TERM" },
            .{ .command = "msr terminate -f /tmp/dev.sock", .help = "send KILL immediately" },
        },
    },
    .{
        .id = .wait,
        .name = "wait",
        .aliases = &.{ "wait" },
        .summary = "wait for session exit",
        .description = "Waits for the specified session to exit and prints the resulting code or signal.",
        .positionals = &one_path_positional,
        .flags = &.{},
        .examples = &.{},
    },
    .{
        .id = .status,
        .name = "status",
        .aliases = &.{ "status" },
        .summary = "print session state",
        .description = "Prints the state of the specified session.",
        .positionals = &one_path_positional,
        .flags = &.{},
        .examples = &.{},
    },
    .{
        .id = .exists,
        .name = "exists",
        .aliases = &.{ "exists" },
        .summary = "test whether a session socket is reachable",
        .description = "Returns whether the specified session socket is reachable.",
        .positionals = &one_path_positional,
        .flags = &.{},
        .examples = &.{},
    },
    .{
        .id = .help,
        .name = "help",
        .aliases = &.{ "help" },
        .summary = "show help",
        .description = "Shows global help or command-specific help.",
        .positionals = &.{},
        .flags = &.{},
        .examples = &.{},
    },
};

pub fn findCommandByAlias(name: []const u8) ?*const CommandSpec {
    for (&commands) |*cmd| {
        for (cmd.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return cmd;
        }
    }
    return null;
}

pub fn findCommandById(id: CommandId) ?*const CommandSpec {
    for (&commands) |*cmd| {
        if (cmd.id == id) return cmd;
    }
    return null;
}
