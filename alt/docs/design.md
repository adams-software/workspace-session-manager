# Alt: Local Hotkey Alt-Screen Passthrough

## Summary

`alt` is a thin two-PTY switcher.

It runs a primary command and an alternate command on separate PTYs, while reserving a single local hotkey to switch between them. One side is active at a time. `alt` forwards bytes to the active side, drains and intentionally drops inactive-side output, and applies only a minimal activation nudge when switching sides.

The goal is to add a lightweight local control plane above an existing interactive terminal stack without pushing workspace semantics into lower layers like `msr` or terminal-rendering semantics into `wsm`.

## Motivation

Current session usage has a useful higher-level control model in `wsm`, but once an interactive attach is running, the foreground terminal is owned by the live session. That makes it hard to open a local control menu or similar UI with a hotkey while preserving the current screen and returning to it cleanly.

We want:

* a local hotkey while attached
* a second PTY-backed side for a temporary local UI or script
* fast switching between sides
* automatic fallback if one side exits
* no coupling to `wsm`, `msr`, or `vpty` internals

## Non-Goals

`alt` is **not** intended to be:

* a session manager
* a terminal multiplexer like tmux
* a full terminal emulator
* a workspace-aware tool
* a command router for side results
* a structured IPC protocol
* a screen-state buffer or restorer

Inactive-side output is intentionally drained and discarded. `alt` does not reconstruct hidden views.

## Design Principles

* Keep `alt` generic and pure.
* Keep workspace/session semantics outside `alt`.
* Let each side do whatever it needs to do.
* Keep both sides on symmetric PTY plumbing.
* Keep activation minimal: current tty size sync plus `SIGWINCH`.
* Favor minimal configuration and sensible defaults.

## High-Level Behavior

At runtime, `alt` behaves as follows:

1. Parse startup configuration from flags and environment.
2. Spawn the primary command under a PTY.
3. Defer alternate-side start until first activation.
4. Put the local terminal into raw mode.
5. Proxy local input to the active side PTY and active side PTY output back to the terminal.
6. Drain and intentionally discard inactive-side output.
7. Watch for the configured local hotkey in the input stream.
8. When the hotkey is pressed, switch active side.
9. On activation, ensure the target side is live, sync current tty size, and send `SIGWINCH`.
10. If one side exits, fall back to the other running side. If neither remains, exit.

## CLI

Initial CLI:

```text
alt [--key <spec>] --run <path> [--signal-1 <sig>] [--signal-2 <sig>] -- <primary-command...>
```

### Flags

`--key <spec>`
: Local hotkey specification. Overrides `ALT_KEY`.

`--run <path>`
: Alternate-side executable to run on its own PTY. Overrides `ALT_RUN`.

`--signal-1 <sig>`
: Optional signal to send to side 1's root child PID when switching away from it.

`--signal-2 <sig>`
: Optional signal to send to side 2's root child PID when switching away from it.

`--`
: Separates `alt` options from the child command. Everything after `--` is passed to the child command literally.

### Environment

`ALT_KEY`
: Default hotkey specification when `--key` is not provided.

`ALT_RUN`
: Default hook executable when `--run` is not provided.

### Defaults

Initial defaults:

* key: `ctrl-g`

No default for run, must be specified by user.
No default switch-away signals.

## Hotkey Semantics

For the initial version, hotkey handling is intentionally minimal.

Supported initially:

* `ctrl-g`
* single-byte literal key specs

Not yet included in initial scope:

* multi-key prefixes
* double-tap to send the reserved key through
* arbitrary named key combinations
* a command mode or secondary control layer

## Side Semantics

The alternate side is executed as a normal local process on its own PTY.

Current contract:

* Side 1 is the primary command after `--`.
* Side 2 is the alternate executable from `--run`.
* `alt` does not read or interpret side stdout.
* Inactive-side output is drained and dropped.
* If a side exits and is explicitly reactivated later, it is restarted.
* Optional `--signal-1` / `--signal-2` fire only on switch-away and target that side's root child PID.

## Terminal Behavior

### Child Side

The child command is run under a PTY so it behaves like a normal interactive terminal application.

### Local Side

`alt` owns the foreground terminal while it is running.

In normal operation:

* local terminal is placed into raw mode
* child output is written directly to the terminal
* local input is forwarded directly to the child PTY

When the hotkey fires:

* normal forwarding switches to the other side
* the newly active side is ensured live
* current tty size is synced to that side
* `SIGWINCH` is sent to that side

### Alternate Screen Policy

`alt` does not own terminal alternate-screen entry or exit for side activation. It only emits a hard local reset and clear at the switch boundary, leaving nested apps to manage any `?1049` usage themselves. It does not own hidden screen restoration for child apps and does not buffer or reconstruct view state.

## Purity and Layering

`alt` should remain generic.

It should **not**:

* infer workspace root
* infer canonical session ids
* inject domain-specific environment variables
* understand `msr`, `dsm`, or `wsm` semantics

It may infer only what is necessary for its own operation, such as the child argv, alternate executable, configured hotkey, and optional switch-away signals.

Any higher-level context discovery should happen inside the hook script itself or in outer tooling.

## Example Usage

Default hook and key:

```bash
alt -- wsm attach foo/bar
```

Explicit hotkey:

```bash
alt --key ctrl-g -- wsm attach foo/bar
```

Explicit alternate executable:

```bash
alt --run ./scripts/wsm_menu -- wsm attach foo/bar
```

Alternate executable with switch-away signal:

```bash
alt --run ./scripts/wsm_menu --signal-2 TERM -- wsm attach foo/bar
```

Environment-driven configuration:

```bash
ALT_KEY=ctrl-g ALT_RUN=./scripts/wsm_menu alt -- wsm attach foo/bar
```

Generic non-WSM usage:

```bash
alt --run ./local-tools/debug-menu -- bash
```

## Current Implementation Notes

The Zig implementation currently:

* opens `/dev/tty`
* captures and restores terminal attributes with `termios`
* creates a PTY for the primary command and a PTY for the alternate side
* proxies bytes using `poll`
* intercepts the configured hotkey locally before forwarding
* preserves post-hotkey tail bytes and routes them to the newly active side
* uses minimal activation only: tty size sync plus `SIGWINCH`
* supports optional switch-away signaling to a side's root child PID

## Current Limitations

The current version intentionally omits or limits:

* hook/alternate argv beyond a single executable path for `--run`
* transparent literal send-through of the reserved hotkey
* sophisticated error reporting/UI
* action-return protocol from the alternate side
* nested local menus or overlay composition
* hidden-screen restoration for nested apps launched under an outer shell

These can be added later if needed.

## Future Extensions

Possible future enhancements:

* allow a wrapper or argv form for alternate-side execution
* add a “send literal hotkey” escape path
* allow optional side output interpretation
* add structured logging/debug mode
* expose clearer exit status propagation
* expand switch-away signaling semantics if needed

None of these are required for the initial feature.

## Open Questions

These are intentionally left open for now:

* Whether the default alternate executable should remain `wsm_menu` or become unset by default
* Whether `alt` should eventually support alternate-side argv directly
* Whether hotkey passthrough for the reserved key is needed immediately
* Whether the final install path should make `alt` a general utility or an internal helper in the session stack

## Recommended V1 Outcome

A successful first version should prove the following:

* an interactive child command can run transparently through `alt`
* the configured hotkey is intercepted locally
* the hook executable runs in alternate screen
* exiting the hook returns to the original session view
* the design works without embedding higher-level workspace/session semantics in `alt`

