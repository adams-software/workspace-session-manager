# CLI parser architecture v0

## Goal

Replace ad hoc argument handling in `main.zig` with a small two-layer parsing design:

1. a **generic argv grammar parser** that knows nothing about `msr`
2. an **`msr`-specific matcher/validator** that maps parsed argv into typed commands

This keeps argument grammar independent from application command semantics.

This spec assumes the command surface defined in:
- `cli-refinement-v0.md`

---

## Design principles

1. **No external CLI dependency**
   - Use small manual parsing layers.
   - Keep Zig-version-sensitive argv handling isolated.

2. **Separate syntax from semantics**
   - Generic parser handles tokens, options, values, positionals, and `--`.
   - App-specific layer decides what commands and flags actually mean.

3. **Keep the generic layer reusable**
   - It should be useful beyond `msr`.
   - It should not know command aliases, signal names, or nested mode.

4. **Keep the app-specific layer typed**
   - `msr` command validation should still return a typed command union.

5. **Structured failures at both layers**
   - generic syntax failures
   - app-specific validation failures

6. **Flags are flexible before `--`**
   - command-local flags may appear before or after positional args
   - `--` ends parser handling for the current command

---

# Layer 1: generic argv grammar parser

## Proposed module

```text
src/argv_parse.zig
```

## Responsibility

Turn argv tokens into a generic parsed structure.

The generic parser should understand:
- command token selection
- short/long flags
- long options with `=`
- long/short options with following values
- positional args
- `--` terminator

The generic parser should **not** understand:
- valid command names
- aliases that belong to a specific app
- valid flags for a given command
- nested/current-session semantics
- signal names
- help text formatting

---

## Suggested output structure

```zig
pub const ParsedArgv = struct {
    command: ?[]const u8,
    options: []Option,
    positionals: [][]const u8,
    literal_tail: ?[][]const u8,
};
```

### Option structure

```zig
pub const Option = struct {
    spelling: []const u8,
    name: []const u8,
    value: ?[]const u8,
};
```

### Notes
- `spelling` preserves the original token form, e.g. `-a`, `--attach`, `--session=/tmp/x`
- `name` is normalized, e.g. `a`, `attach`, `session`
- `value` is optional and may come from either:
  - `--option=value`
  - `--option value`
  - `-o value`

---

## Generic parse behavior

### Command selection
- first non-program token that is not consumed as a global option becomes `command`
- if no command token exists, return `command = null`

### Options
Recognize:
- `--flag`
- `--option=value`
- `--option value`
- `-f`
- `-o value`

### Positionals
Any non-option tokens after command selection and before `--` that are not consumed as option values become `positionals`.

### Literal tail
If `--` appears:
- stop parser interpretation
- all remaining tokens go into `literal_tail`

---

## Generic parse errors

The generic parser should only emit syntax-level failures.

```zig
pub const ParseSyntaxError = error{
    MissingOptionValue,
    UnexpectedOptionSyntax,
};
```

Alternative structured form is acceptable if better for diagnostics.

### Examples
Generic parser should reject:
- `--session` with no following token when a value is required
- malformed long option syntax if we decide to treat it as invalid

It should **not** reject:
- unknown command names
- unknown flags
- unsupported flags for a command
- extra positionals for a command

Those belong to layer 2.

---

## Generic parser helper API ideas

These are optional but useful:

```zig
pub fn hasOption(parsed: ParsedArgv, aliases: []const []const u8) bool
pub fn findOption(parsed: ParsedArgv, aliases: []const []const u8) ?Option
pub fn countOption(parsed: ParsedArgv, aliases: []const []const u8) usize
```

These helpers should remain generic and alias-list-driven.

---

# Layer 2: msr-specific matcher / validator

## Proposed module

```text
src/cli_parse.zig
```

## Responsibility

Interpret `argv_parse.ParsedArgv` according to `msr` command rules.

Responsibilities:
- command alias matching
- flag alias matching
- command-local arity rules
- command-local type conversion (e.g. `u16`, signal enum)
- current-session normalization
- typed command result
- app-specific validation failures

Non-responsibilities:
- session/network execution
- PTY handling
- final help rendering

---

## Alias model

### Command aliases

```zig
pub const CommandSpec = struct {
    kind: CommandKind,
    names: []const []const u8,
};
```

Examples:
- create: `{"c", "create"}`
- attach: `{"a", "attach"}`
- detach: `{"d", "detach"}`

### Flag aliases

```zig
pub const FlagSpec = struct {
    kind: FlagKind,
    names: []const []const u8,
};
```

Examples:
- create attach flag: `{"a", "attach"}`
- force flag: `{"f", "force"}`
- global session option: `{"session"}`

The app-specific layer should resolve aliases using lists/specs, not hardcoded repeated string comparisons.

---

## Current-session normalization

The app-specific layer should accept both:
- `--session=<path>`
- `--session <path>`

These should be normalized into:

```zig
current_session: ?[]const u8
```

Precedence:
1. explicit `--session`
2. `MSR_SESSION`

This is application-specific rather than generic because it is part of `msr` semantics.

---

## Typed `msr` result

```zig
pub const ParsedCli = struct {
    current_session: ?[]const u8,
    command: Command,
};
```

### Command union

```zig
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

### Supporting structs

```zig
pub const PathArgs = struct {
    path: []const u8,
};

pub const CreateArgs = struct {
    path: []const u8,
    attach_after_create: bool,
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

pub const TerminateArgs = struct {
    path: []const u8,
    signal: SignalSpec,
};

pub const SignalSpec = enum {
    term,
    int,
    kill,
};
```

---

## App-specific validation failures

Use a structured failure rather than immediately printing help from the parser.

```zig
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
```

### Command kind helper

```zig
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
```

This allows `main.zig` to decide:
- full help
- nested help header + full help
- command-specific usage
- command-specific error text

---

## App-specific parse rules

## Canonical commands to recognize

### `help`
Accepted command aliases:
- `help`
- plus direct top-level `-h`, `--help`

### `current`
Accepted command aliases:
- `current`

### `c` / `create`
Accepted command aliases:
- `c`
- `create`

Recognized flags:
- `-a`, `--attach`

Rules:
- one required path positional before `--`
- optional literal tail after `--`

### `a` / `attach`
Accepted command aliases:
- `a`
- `attach`

Recognized flags:
- `-f`, `--force`

Rules:
- one required target/path positional
- no literal tail
- app-specific execution later decides direct vs nested meaning

### `d` / `detach`
Accepted command aliases:
- `d`
- `detach`

Rules:
- no extra positionals
- no options

### `resize`
Recognized flags:
- `-f`, `--force`

Rules:
- path, cols, rows positional triple
- no literal tail

### `terminate`
Recognized flags:
- `-f`, `--force`

Rules:
- one required path positional
- optional signal positional from `{TERM, INT, KILL}`
- `-f|--force` normalizes to `kill`

### `wait`
Rules:
- one required path positional

### `status`
Rules:
- one required path positional

### `exists`
Rules:
- one required path positional

---

## Recommended implementation strategy

## Generic layer
Implement a compact tokenizer/parser that:
1. skips argv0
2. captures global tokens in order
3. identifies command
4. parses options/positionals before `--`
5. captures `literal_tail`

## App-specific layer
Implement small per-command validators that:
1. match command aliases
2. inspect parsed options via generic helper functions
3. validate positional count/types
4. normalize typed fields
5. return `ParsedCli` or `ParseFailure`

This keeps both layers small and straightforward.

---

## Execution-layer responsibilities after parse

`main.zig` (or a later `cli_exec.zig`) should do runtime interpretation like:

### Attach
- if current-session context exists:
  - `attach` means nested attach
  - reject `force`
  - reject self-target explicitly
- else:
  - `attach` means direct attach
  - `force` means takeover

### Detach
- requires current-session context

### Current
- requires current-session context

### Terminate
- map `SignalSpec` to current client API string form (`TERM`, `INT`, `KILL`) or later internal enum

This keeps parse/validation separate from runtime dispatch.

---

## Testing strategy

## Layer 1 tests: generic parser
Examples:
- `cmd --flag pos1 pos2`
- `cmd --opt=value pos`
- `cmd --opt value pos`
- `cmd -f pos`
- `cmd pos -- literal -a --force`
- missing option value for a value-taking generic parse path

These tests should not mention `msr` semantics.

## Layer 2 tests: msr parser
Examples:
- `msr c /tmp/x`
- `msr create /tmp/x`
- `msr c -a /tmp/x`
- `msr c /tmp/x -a`
- `msr c /tmp/x -- /bin/sh -i`
- `msr a /tmp/x`
- `msr attach /tmp/x`
- `msr a /tmp/x -f`
- `msr a -f /tmp/x`
- `msr terminate /tmp/x`
- `msr terminate /tmp/x -f`
- `msr terminate -f /tmp/x`
- `msr terminate /tmp/x INT`
- `msr current`
- `msr --session=/tmp/current current`
- `msr --session /tmp/current current`

### Failure cases
- no command
- unknown command
- `wait` missing path
- `resize` missing rows
- `terminate /tmp/x BOGUS`
- `d extra`
- `current extra`
- `c --attach` missing path
- `--session` missing path
- flags appearing after `--` and therefore not being treated as `msr` flags

---

## Migration plan

## Phase 1
- implement `src/argv_parse.zig`
- implement `src/cli_parse.zig`
- keep execution in `main.zig`

## Phase 2
- move command execution into a cleaner dispatch layer if desired
- keep parser layers stable

## Phase 3
- if CLI grammar changes later, most churn should stay confined to `cli_parse.zig`

---

## Non-goals

This spec does not yet define:
- path-first grammar
- shell completion
- global option expansion beyond current-session handling
- session execution architecture changes
