Yes — this is a good fit for a declarative command spec.

Right now your `main` has the classic duplication problem:

* help text is handwritten in `usage()` and the per-command `usageX()` functions
* parse behavior lives elsewhere in `cli_parse.parseArgv(...)`
* dispatch behavior lives in the `switch (ok.command)`
* special error/help wording is duplicated again in the `.fail` branch
* nested/current-session behavior is also encoded separately from the docs   

So I would not try to make the command table execute everything automatically. I would make it the single source of truth for:

* names and aliases
* summaries and long descriptions
* usage patterns
* flags/options
* positional args
* examples
* whether the command changes meaning in nested/current-session mode

Then use that table to generate:

* `help`
* `help <command>`
* per-command usage lines
* parse validation metadata
* shell-completion later, if you want

The actual runtime action can still remain your explicit `switch (ok.command)`.

## What I would build

### 1. A static command schema

Something like this in Zig:

```zig
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
```

This gives you a real schema without over-automating execution.

---

### 2. A single command table

For example:

```zig
pub const create_flags = [_]FlagSpec{
    .{
        .long = "attach",
        .short = 'a',
        .help = "attach immediately after the session becomes ready",
    },
};

pub const create_positionals = [_]PositionalSpec{
    .{
        .name = "path",
        .kind = .path,
        .help = "session socket path",
    },
    .{
        .name = "cmd",
        .kind = .command_tail,
        .cardinality = .optional,
        .help = "command to run after --; defaults to $SHELL -i",
    },
};

pub const create_examples = [_]ExampleSpec{
    .{
        .command = "msr c /tmp/dev.sock",
        .help = "create a session using the default interactive shell",
    },
    .{
        .command = "msr c -a /tmp/dev.sock -- bash -i",
        .help = "create and attach immediately",
    },
};

pub const attach_flags = [_]FlagSpec{
    .{
        .long = "force",
        .short = 'f',
        .help = "take over ownership when direct attach requires it",
    },
};

pub const attach_positionals = [_]PositionalSpec{
    .{
        .name = "path",
        .kind = .path,
        .help = "target session socket path",
    },
};

pub const commands = [_]CommandSpec{
    .{
        .id = .create,
        .name = "create",
        .aliases = &.{ "c" },
        .summary = "create a new session",
        .description =
            "Creates a persistent PTY-backed session at the given socket path. "
            ++ "If no command is provided after --, the current shell is used.",
        .positionals = &create_positionals,
        .flags = &create_flags,
        .examples = &create_examples,
    },
    .{
        .id = .attach,
        .name = "attach",
        .aliases = &.{ "a" },
        .summary = "attach to a session",
        .description =
            "Direct attach uses ownership rules. When a current session is selected, "
            ++ "attach routes through that session owner instead.",
        .positionals = &attach_positionals,
        .flags = &attach_flags,
        .examples = &.{
            .{ .command = "msr a /tmp/dev.sock", .help = "attach directly" },
            .{ .command = "MSR_SESSION=/tmp/current.sock msr a /tmp/other.sock", .help = "route attach through current session" },
        },
        .context_behavior = .meaning_changes_with_current_session,
    },
    // ... current, detach, resize, terminate, wait, status, exists, help
};
```

That gives you a canonical spec for docs and parse expectations.

---

## 3. A small help renderer

Then your help stops being handwritten giant strings and becomes generated.

```zig
pub fn printGlobalHelp() void {
    out("NAME\n  msr - minimal session runtime for persistent PTY-backed sessions\n\n", .{});
    out("USAGE\n  msr <command> [options]\n\n", .{});
    out("COMMANDS\n", .{});

    for (commands) |cmd| {
        out("  {s}", .{cmd.aliases[0]});
        if (!std.mem.eql(u8, cmd.aliases[0], cmd.name)) {
            out(", {s}", .{cmd.name});
        }
        out("  {s}\n", .{cmd.summary});
    }

    out("\nCURRENT SESSION\n  --session=<path> or --session <path> overrides MSR_SESSION\n", .{});
}
```

And command help:

```zig
pub fn printCommandHelp(cmd: CommandSpec) void {
    out("NAME\n  {s} - {s}\n\n", .{ cmd.name, cmd.summary });
    out("USAGE\n  ", .{});
    printCommandUsage(cmd);
    out("\nDESCRIPTION\n  {s}\n", .{cmd.description});

    if (cmd.flags.len != 0) {
        out("\nOPTIONS\n", .{});
        for (cmd.flags) |flag| {
            if (flag.short) |s| {
                out("  -{c}, --{s}", .{ s, flag.long });
            } else {
                out("  --{s}", .{flag.long});
            }
            if (flag.value_name) |value_name| {
                out(" <{s}>", .{value_name});
            }
            out("\n      {s}\n", .{flag.help});
        }
    }

    if (cmd.examples.len != 0) {
        out("\nEXAMPLES\n", .{});
        for (cmd.examples) |ex| {
            out("  {s}\n      {s}\n", .{ ex.command, ex.help });
        }
    }
}
```

This immediately replaces most of `usage()` plus all the `usageCreate()`, `usageAttachDirect()`, `usageDetach()`, etc., which are currently hardcoded and repetitive. 

---

## 4. Keep parsing typed, but derive validation from the spec

I would **not** fully replace `cli_parse` with a totally generic parser unless you really want to. Zig gets messy fast if you try to build a magical parser that also returns strongly typed unions.

A better split is:

* generic token scanning from argv
* command lookup from the command table
* generic option/positional validation from the spec
* command-specific conversion into your existing typed parse result

So you can keep something like:

```zig
pub const Parsed = union(enum) {
    fail: ParseFailure,
    ok: struct {
        current_session: ?[]const u8,
        command: Command,
    },
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
```

But instead of hand-validating every usage combination in bespoke code, you do:

1. resolve command by name/alias from `commands`
2. collect flags/positionals generically
3. validate count and allowed flags against the `CommandSpec`
4. convert to typed args for runtime

That keeps the runtime switch clean while still getting the doc/parser unification you want. Your current `main` is already organized around a typed parse result, so this would slot in naturally. 

---

## 5. Model nested/current-session behavior as metadata, not prose only

One important thing in your CLI is that `attach` and `detach` change behavior when a current session exists, while other commands keep their normal meaning. That rule is currently described in help text and enforced separately in runtime.  

I would encode that in the spec directly:

```zig
pub const ContextBehavior = enum {
    normal,
    requires_current_session,
    meaning_changes_with_current_session,
};
```

Then help rendering can automatically print something like:

* “Requires current session context”
* “Meaning changes when `--session` / `MSR_SESSION` is present”

For `detach`, you might even want:

```zig
.context_behavior = .requires_current_session,
```

if that is the true public contract.

For `attach`:

```zig
.context_behavior = .meaning_changes_with_current_session,
```

That keeps docs and behavior aligned.

---

## 6. Add machine-readable synopsis generation

Once you have the schema, you can generate:

* short usage line
* long manual page
* markdown docs
* shell completion
* maybe JSON export later

For example:

```zig
pub fn renderUsageLine(buf: *std.ArrayList(u8), cmd: CommandSpec) !void {
    const w = buf.writer();
    try w.print("msr {s}", .{cmd.aliases[0]});

    for (cmd.flags) |flag| {
        if (flag.kind == .none) {
            try w.print(" [-{c}|--{s}]", .{ flag.short orelse '?', flag.long });
        } else {
            try w.print(" [--{s} <{s}>]", .{ flag.long, flag.value_name.? });
        }
    }

    for (cmd.positionals) |pos| {
        switch (pos.cardinality) {
            .required => try w.print(" <{s}>", .{pos.name}),
            .optional => try w.print(" [<{s}>]", .{pos.name}),
            .repeated => try w.print(" <{s}...>", .{pos.name}),
        }
    }
}
```

This gives you one authoritative usage string per command.

---

## 7. Recommended architecture

I would split it like this:

### `cli_spec.zig`

Pure metadata:

* command ids
* aliases
* flags
* positionals
* examples
* help text
* lookup helpers

### `cli_help.zig`

Pure rendering:

* `printGlobalHelp()`
* `printCommandHelp(id)`
* `printNestedHelp(current_session)`
* `renderUsageLine(id)`

### `cli_parse.zig`

Parsing:

* token scanning
* resolve command from spec
* validate flags/positionals from spec
* convert to typed result

### `main.zig`

Only:

* call parser
* call help renderer on failure/help
* execute parsed command

That would clean up `main` a lot.

---

## 8. The key design choice: declarative docs, explicit execution

This is the part I’d be careful about.

I would **not** try to make this table call runtime functions directly with function pointers and erased argument blobs. That usually becomes worse in Zig.

Instead:

* docs/help/usage/examples come from the spec
* parsing rules mostly come from the spec
* actual execution stays in a normal `switch`

That gets you 80–90% of the value without making the codebase too clever.

---

## 9. What this buys you immediately

For your app specifically, this would fix a few pain points:

* no more editing giant `usage()` string by hand
* no more per-command `usageFoo()` duplication
* aliases and canonical names stay in one place
* examples become first-class instead of informal notes
* nested/current-session semantics become explicit metadata
* parser and manual stop drifting apart

That drift risk is real in your current structure because usage text, failure messages, nested behavior, and execution are all separate surfaces.  

---

## 10. My recommendation for your codebase

I’d do this in two phases.

### Phase 1

Only replace help generation:

* add `cli_spec.zig`
* generate `usage()`
* generate per-command usage
* keep current parser mostly intact

### Phase 2

Refactor `cli_parse` to consume the spec for:

* command lookup
* alias resolution
* option validation
* positional count checks

That keeps the refactor controlled.

---

## 11. Concrete suggestion for your command model

Given your current command set, I’d make these canonical names:

* `create` alias `c`
* `attach` alias `a`
* `detach` alias `d`
* `current`
* `resize`
* `terminate`
* `wait`
* `status`
* `exists`
* `help`

Then render the short aliases in the compact usage output, but use canonical names in long-form help and docs.

That gives you nicer future docs while preserving the minimal CLI feel.

Below is a concrete cut you can drop in. It assumes the architecture from the previous response, but keeps things practical:

* `cli_spec.zig` is the single source of truth for command docs/schema
* `cli_help.zig` renders help/usage from that schema
* it does **not** try to auto-execute commands
* it is designed so `cli_parse.zig` can start consuming it incrementally later

This is aimed directly at your current command surface in `main.zig` 

## `cli_spec.zig`

```zig
const std = @import("std");

pub const ValueKind = enum {
    none,
    string,
    path,
    u16,
    signal,
    command_tail,
};

pub const Cardinality = enum {
    required,
    optional,
    repeated,
};

pub const ContextBehavior = enum {
    normal,
    requires_current_session,
    meaning_changes_with_current_session,
};

pub const FlagSpec = struct {
    long: []const u8,
    short: ?u8 = null,
    value_name: ?[]const u8 = null,
    value_kind: ValueKind = .none,
    help: []const u8,
};

pub const PositionalSpec = struct {
    name: []const u8,
    value_kind: ValueKind,
    cardinality: Cardinality = .required,
    help: []const u8,
};

pub const ExampleSpec = struct {
    command: []const u8,
    help: []const u8,
};

pub const CommandId = enum {
    help,
    create,
    attach,
    detach,
    current,
    resize,
    terminate,
    wait,
    status,
    exists,
};

pub const CommandSpec = struct {
    id: CommandId,
    name: []const u8,
    aliases: []const []const u8,
    summary: []const u8,
    description: []const u8,
    flags: []const FlagSpec,
    positionals: []const PositionalSpec,
    examples: []const ExampleSpec,
    context_behavior: ContextBehavior = .normal,
};

pub const current_session_flag = [_]FlagSpec{
    .{
        .long = "session",
        .value_name = "path",
        .value_kind = .path,
        .help = "override MSR_SESSION for current-session context",
    },
};

pub const create_flags = [_]FlagSpec{
    .{
        .long = "attach",
        .short = 'a',
        .help = "attach immediately after create",
    },
};

pub const attach_flags = [_]FlagSpec{
    .{
        .long = "force",
        .short = 'f',
        .help = "take over ownership for direct attach",
    },
};

pub const resize_flags = [_]FlagSpec{
    .{
        .long = "force",
        .short = 'f',
        .help = "take over ownership before resizing",
    },
};

pub const terminate_flags = [_]FlagSpec{
    .{
        .long = "force",
        .short = 'f',
        .help = "convenience alias for KILL behavior where supported by parsing",
    },
};

pub const no_flags = [_]FlagSpec{};

pub const create_positionals = [_]PositionalSpec{
    .{
        .name = "path",
        .value_kind = .path,
        .help = "session socket path",
    },
    .{
        .name = "cmd",
        .value_kind = .command_tail,
        .cardinality = .optional,
        .help = "command after --; defaults to $SHELL -i",
    },
};

pub const attach_positionals = [_]PositionalSpec{
    .{
        .name = "path",
        .value_kind = .path,
        .help = "target session socket path",
    },
};

pub const detach_positionals = [_]PositionalSpec{};

pub const current_positionals = [_]PositionalSpec{};

pub const resize_positionals = [_]PositionalSpec{
    .{
        .name = "path",
        .value_kind = .path,
        .help = "session socket path",
    },
    .{
        .name = "cols",
        .value_kind = .u16,
        .help = "terminal column count",
    },
    .{
        .name = "rows",
        .value_kind = .u16,
        .help = "terminal row count",
    },
};

pub const terminate_positionals = [_]PositionalSpec{
    .{
        .name = "path",
        .value_kind = .path,
        .help = "session socket path",
    },
    .{
        .name = "signal",
        .value_kind = .signal,
        .cardinality = .optional,
        .help = "TERM, INT, or KILL; default TERM",
    },
};

pub const wait_positionals = [_]PositionalSpec{
    .{
        .name = "path",
        .value_kind = .path,
        .help = "session socket path",
    },
};

pub const status_positionals = [_]PositionalSpec{
    .{
        .name = "path",
        .value_kind = .path,
        .help = "session socket path",
    },
};

pub const exists_positionals = [_]PositionalSpec{
    .{
        .name = "path",
        .value_kind = .path,
        .help = "session socket path",
    },
};

pub const help_positionals = [_]PositionalSpec{
    .{
        .name = "command",
        .value_kind = .string,
        .cardinality = .optional,
        .help = "command name or alias",
    },
};

pub const help_examples = [_]ExampleSpec{
    .{ .command = "msr help", .help = "show global help" },
    .{ .command = "msr help attach", .help = "show help for a command" },
};

pub const create_examples = [_]ExampleSpec{
    .{ .command = "msr c /tmp/dev.sock", .help = "create a session with the default shell" },
    .{ .command = "msr c -a /tmp/dev.sock -- bash -i", .help = "create and attach immediately" },
};

pub const attach_examples = [_]ExampleSpec{
    .{ .command = "msr a /tmp/dev.sock", .help = "attach directly to a session" },
    .{ .command = "MSR_SESSION=/tmp/current.sock msr a /tmp/other.sock", .help = "route attach through current session owner" },
};

pub const detach_examples = [_]ExampleSpec{
    .{ .command = "MSR_SESSION=/tmp/dev.sock msr d", .help = "detach the current session" },
};

pub const current_examples = [_]ExampleSpec{
    .{ .command = "MSR_SESSION=/tmp/dev.sock msr current", .help = "print current session path" },
};

pub const resize_examples = [_]ExampleSpec{
    .{ .command = "msr resize /tmp/dev.sock 120 40", .help = "resize a session PTY" },
};

pub const terminate_examples = [_]ExampleSpec{
    .{ .command = "msr terminate /tmp/dev.sock", .help = "send TERM" },
    .{ .command = "msr terminate /tmp/dev.sock KILL", .help = "send KILL" },
};

pub const wait_examples = [_]ExampleSpec{
    .{ .command = "msr wait /tmp/dev.sock", .help = "wait for exit and print status" },
};

pub const status_examples = [_]ExampleSpec{
    .{ .command = "msr status /tmp/dev.sock", .help = "print session state" },
};

pub const exists_examples = [_]ExampleSpec{
    .{ .command = "msr exists /tmp/dev.sock", .help = "test whether a session socket is reachable" },
};

pub const commands = [_]CommandSpec{
    .{
        .id = .help,
        .name = "help",
        .aliases = &.{ "h" },
        .summary = "show help",
        .description = "Show global help or help for a specific command.",
        .flags = &no_flags,
        .positionals = &help_positionals,
        .examples = &help_examples,
    },
    .{
        .id = .create,
        .name = "create",
        .aliases = &.{ "c" },
        .summary = "create a session",
        .description =
            "Create a persistent PTY-backed session at the given socket path. "
            ++ "If no command is provided after --, the current shell is started interactively.",
        .flags = &create_flags,
        .positionals = &create_positionals,
        .examples = &create_examples,
    },
    .{
        .id = .attach,
        .name = "attach",
        .aliases = &.{ "a" },
        .summary = "attach to a session",
        .description =
            "Attach directly to a session. When a current session is selected via "
            ++ "--session or MSR_SESSION, attach routes through the current session owner instead.",
        .flags = &attach_flags,
        .positionals = &attach_positionals,
        .examples = &attach_examples,
        .context_behavior = .meaning_changes_with_current_session,
    },
    .{
        .id = .detach,
        .name = "detach",
        .aliases = &.{ "d" },
        .summary = "detach the current session",
        .description =
            "Detach the current session. This command requires current-session context "
            ++ "through --session or MSR_SESSION.",
        .flags = &no_flags,
        .positionals = &detach_positionals,
        .examples = &detach_examples,
        .context_behavior = .requires_current_session,
    },
    .{
        .id = .current,
        .name = "current",
        .aliases = &.{},
        .summary = "print current session path",
        .description =
            "Print the current session path resolved from --session or MSR_SESSION.",
        .flags = &no_flags,
        .positionals = &current_positionals,
        .examples = &current_examples,
        .context_behavior = .requires_current_session,
    },
    .{
        .id = .resize,
        .name = "resize",
        .aliases = &.{},
        .summary = "resize a session PTY",
        .description =
            "Resize a session PTY to the given columns and rows. This is an owner-scoped operation.",
        .flags = &resize_flags,
        .positionals = &resize_positionals,
        .examples = &resize_examples,
    },
    .{
        .id = .terminate,
        .name = "terminate",
        .aliases = &.{},
        .summary = "terminate a session process",
        .description =
            "Send a termination signal to the session process. Default signal is TERM.",
        .flags = &terminate_flags,
        .positionals = &terminate_positionals,
        .examples = &terminate_examples,
    },
    .{
        .id = .wait,
        .name = "wait",
        .aliases = &.{},
        .summary = "wait for session exit",
        .description =
            "Wait for the session process to exit and print its exit status.",
        .flags = &no_flags,
        .positionals = &wait_positionals,
        .examples = &wait_examples,
    },
    .{
        .id = .status,
        .name = "status",
        .aliases = &.{},
        .summary = "print session state",
        .description =
            "Print the current session state such as starting, running, or exited.",
        .flags = &no_flags,
        .positionals = &status_positionals,
        .examples = &status_examples,
    },
    .{
        .id = .exists,
        .name = "exists",
        .aliases = &.{},
        .summary = "test whether a session is reachable",
        .description =
            "Attempt to connect to the session socket and report whether it is reachable.",
        .flags = &no_flags,
        .positionals = &exists_positionals,
        .examples = &exists_examples,
    },
};

pub fn findCommandById(id: CommandId) *const CommandSpec {
    for (&commands) |*cmd| {
        if (cmd.id == id) return cmd;
    }
    unreachable;
}

pub fn findCommandByName(name: []const u8) ?*const CommandSpec {
    for (&commands) |*cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
        for (cmd.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return cmd;
        }
    }
    return null;
}

pub fn commandHasAlias(cmd: *const CommandSpec, alias: []const u8) bool {
    for (cmd.aliases) |a| {
        if (std.mem.eql(u8, a, alias)) return true;
    }
    return false;
}
```

## `cli_help.zig`

```zig
const std = @import("std");
const spec = @import("cli_spec.zig");

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn printWrappedIndented(text: []const u8, prefix: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        out("{s}{s}\n", .{ prefix, line });
    }
}

fn printFlag(flag: spec.FlagSpec) void {
    out("  ", .{});
    if (flag.short) |s| {
        out("-{c}, ", .{s});
    } else {
        out("    ", .{});
    }
    out("--{s}", .{flag.long});
    if (flag.value_name) |value_name| {
        out(" <{s}>", .{value_name});
    }
    out("\n", .{});
    printWrappedIndented(flag.help, "      ");
}

fn printPositional(pos: spec.PositionalSpec) void {
    out("  {s}\n", .{pos.name});
    printWrappedIndented(pos.help, "      ");
}

fn printExample(ex: spec.ExampleSpec) void {
    out("  {s}\n", .{ex.command});
    printWrappedIndented(ex.help, "      ");
}

pub fn renderUsageLine(
    writer: anytype,
    cmd: *const spec.CommandSpec,
) !void {
    try writer.print("msr ", .{});

    if (cmd.aliases.len > 0) {
        try writer.print("{s}", .{cmd.aliases[0]});
    } else {
        try writer.print("{s}", .{cmd.name});
    }

    for (cmd.flags) |flag| {
        if (flag.value_name) |value_name| {
            if (flag.short) |s| {
                try writer.print(" [-{c}|--{s} <{s}>]", .{ s, flag.long, value_name });
            } else {
                try writer.print(" [--{s} <{s}>]", .{ flag.long, value_name });
            }
        } else {
            if (flag.short) |s| {
                try writer.print(" [-{c}|--{s}]", .{ s, flag.long });
            } else {
                try writer.print(" [--{s}]", .{flag.long});
            }
        }
    }

    for (cmd.positionals) |pos| {
        switch (pos.cardinality) {
            .required => try writer.print(" <{s}>", .{pos.name}),
            .optional => {
                if (pos.value_kind == .command_tail) {
                    try writer.print(" [-- <{s}...>]", .{pos.name});
                } else {
                    try writer.print(" [<{s}>]", .{pos.name});
                }
            },
            .repeated => try writer.print(" <{s}...>", .{pos.name}),
        }
    }
}

pub fn printUsageLine(cmd: *const spec.CommandSpec) void {
    out("usage: ", .{});
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    renderUsageLine(fbs.writer(), cmd) catch unreachable;
    out("{s}\n", .{fbs.getWritten()});
}

fn printContextBehavior(behavior: spec.ContextBehavior) void {
    switch (behavior) {
        .normal => {},
        .requires_current_session => {
            out("\nCURRENT SESSION CONTEXT\n", .{});
            out("  This command requires --session=<path>, --session <path>, or MSR_SESSION.\n", .{});
        },
        .meaning_changes_with_current_session => {
            out("\nCURRENT SESSION CONTEXT\n", .{});
            out("  This command changes behavior when --session=<path>, --session <path>, or\n", .{});
            out("  MSR_SESSION is set.\n", .{});
        },
    }
}

pub fn printCommandHelp(cmd: *const spec.CommandSpec) void {
    out("NAME\n", .{});
    out("  {s}", .{cmd.name});
    if (cmd.aliases.len > 0) {
        out(" (", .{});
        for (cmd.aliases, 0..) |alias, i| {
            if (i != 0) out(", ", .{});
            out("{s}", .{alias});
        }
        out(")", .{});
    }
    out(" - {s}\n\n", .{cmd.summary});

    out("USAGE\n", .{});
    out("  ", .{});
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    renderUsageLine(fbs.writer(), cmd) catch unreachable;
    out("{s}\n", .{fbs.getWritten()});

    out("\nDESCRIPTION\n", .{});
    printWrappedIndented(cmd.description, "  ");

    printContextBehavior(cmd.context_behavior);

    if (cmd.positionals.len != 0) {
        out("\nARGS\n", .{});
        for (cmd.positionals) |pos| printPositional(pos);
    }

    if (cmd.flags.len != 0) {
        out("\nOPTIONS\n", .{});
        for (cmd.flags) |flag| printFlag(flag);
    }

    if (cmd.examples.len != 0) {
        out("\nEXAMPLES\n", .{});
        for (cmd.examples) |ex| printExample(ex);
    }
}

pub fn printGlobalHelp() void {
    out(
        "NAME\n" ++
            "  msr - minimal session runtime for persistent PTY-backed sessions\n\n" ++
            "DESCRIPTION\n" ++
            "  msr runs a command inside a persistent PTY-backed session identified by\n" ++
            "  a socket path. Sessions can be created, attached, detached, and\n" ++
            "  re-attached.\n\n" ++
            "  A current session can be selected with --session=<path>, --session <path>,\n" ++
            "  or MSR_SESSION.\n\n" ++
            "USAGE\n" ++
            "  msr <command> [options]\n" ++
            "  msr help [command]\n\n" ++
            "COMMANDS\n",
        .{},
    );

    for (spec.commands) |cmd| {
        out("  ", .{});
        if (cmd.aliases.len > 0) {
            out("{s}", .{cmd.aliases[0]});
            out(" ({s})", .{cmd.name});
        } else {
            out("{s}", .{cmd.name});
        }
        out("\n      {s}\n", .{cmd.summary});
    }

    out(
        "\nGLOBAL CURRENT-SESSION OPTION\n" ++
            "  --session=<path> or --session <path> overrides MSR_SESSION.\n\n" ++
            "NESTED MODE\n" ++
            "  When a current session is selected:\n" ++
            "    attach routes through the current session owner\n" ++
            "    detach detaches the current session\n" ++
            "    current prints the current session path\n" ++
            "    all other commands keep their normal explicit-argument behavior\n",
        .{},
    );
}

pub fn printNestedHelp(current_session: []const u8) void {
    out("NESTED MODE\n", .{});
    out("  current session: {s}\n\n", .{current_session});
    printGlobalHelp();
}
```

## How I would wire it into `main.zig`

At the top:

```zig
const cli_spec = @import("cli_spec");
const cli_help = @import("cli_help");
```

Then replace the handwritten usage helpers:

```zig
fn usage() void {
    cli_help.printGlobalHelp();
}

fn usageCreate() void {
    cli_help.printUsageLine(cli_spec.findCommandById(.create));
}

fn usageAttachDirect() void {
    cli_help.printUsageLine(cli_spec.findCommandById(.attach));
}

fn usageAttachNested() void {
    cli_help.printUsageLine(cli_spec.findCommandById(.attach));
}

fn usageDetach() void {
    cli_help.printUsageLine(cli_spec.findCommandById(.detach));
}

fn usageCurrent() void {
    cli_help.printUsageLine(cli_spec.findCommandById(.current));
}

fn usageResize() void {
    cli_help.printUsageLine(cli_spec.findCommandById(.resize));
}

fn usageTerminate() void {
    cli_help.printUsageLine(cli_spec.findCommandById(.terminate));
}

fn usageWait() void {
    cli_help.printUsageLine(cli_spec.findCommandById(.wait));
}

fn usageStatus() void {
    cli_help.printUsageLine(cli_spec.findCommandById(.status));
}

fn usageExists() void {
    cli_help.printUsageLine(cli_spec.findCommandById(.exists));
}

fn nestedUsage(current_session: []const u8) void {
    cli_help.printNestedHelp(current_session);
}
```

And for the `help` command, you can improve it later to support `msr help attach`:

```zig
.help => {
    usage();
    return 0;
},
```

or, once parser supports optional help target:

```zig
.help => |args| {
    if (args.command_name) |name| {
        const cmd = cli_spec.findCommandByName(name) orelse {
            err("msr: unknown command: {s}\n", .{name});
            return 1;
        };
        cli_help.printCommandHelp(cmd);
    } else {
        cli_help.printGlobalHelp();
    }
    return 0;
},
```

## What I would do next in `cli_parse.zig`

Not a full rewrite yet. Just start consuming `cli_spec` for:

* command lookup by alias/name
* optional `help <command>`
* maybe central validation helpers like `unknown flag for command`
* later, positional count checks

That way the migration stays controlled instead of turning into a generic parser project.

## Small refinement I’d recommend

Your current public docs emphasize short aliases (`c`, `a`, `d`) in usage text. That is fine for terseness, but I’d still treat the long names as canonical internally:

* `create`
* `attach`
* `detach`

That makes `help create`, markdown docs, and completions much nicer, while preserving the compact CLI feel.

## One subtle mismatch to keep in mind

In the current code, `terminate` mentions `-f|--force` in usage and error text, but execution still calls `cli.terminate(signalName(args.signal))`, so the real effect depends entirely on how `cli_parse` maps `-f` into `args.signal` 

That means the spec should match parser reality, not just the old help prose. If you clean up anything first, I’d make sure `terminate`’s `-f` semantics are explicit and unambiguous in `cli_parse`.

If you want, next I can sketch the matching `cli_parse` refactor shape so this spec actually becomes the lookup/validation source without over-generalizing it.


## Recommended phased rollout

### v1 scope
Use the command table as the source of truth for:
- command names and aliases
- summaries and descriptions
- usage patterns
- flags/options
- positional args
- examples
- nested/current-session behavior notes

### Not in v1
Do **not** try to use the table for:
- automatic command execution
- full parser generation
- deeply inferred validation behavior
- overcomplicated metadata requirements

The runtime action layer should remain an explicit switch in code.

### Suggested phases
1. **Phase A — add `command_spec.zig`**
   - define a compact schema and fill in the current command table
2. **Phase B — generate help/usage from the command table**
   - replace handwritten global help and per-command usage strings
3. **Phase C — use the table for alias/flag lookup in `cli_parse`**
   - reduce duplicated parser metadata
4. **Phase D — optional deeper validation from schema**
   - only if it still feels worth it after the first three phases
