# Alt: Control-Driven PTY Switcher

## Summary

`alt` is a thin two-PTY switcher with a small control socket.

It runs a primary command and an alternate command on separate PTYs. One side is active at a time. `alt` forwards bytes to the active side, drains and intentionally discards inactive-side output, and exposes a simple line-based control interface for switching.

The goal is to add a lightweight local control plane above an existing interactive terminal stack without pushing workspace semantics into lower layers like `msr` or terminal-rendering semantics into `wsm`.

## Motivation

Once an interactive attach is running, the foreground terminal is owned by the live session. We still want a small local control seam that can:

- switch between two PTY-backed sides
- host a temporary local UI or helper process on the alternate side
- fall back cleanly if one side exits
- stay generic and not absorb workspace/session semantics

## Non-Goals

`alt` is **not** intended to be:

- a session manager
- a terminal multiplexer like tmux
- a full terminal emulator
- a workspace-aware tool
- a command router for side results
- a rich IPC framework
- a screen-state buffer or restorer

Inactive-side output is intentionally drained and discarded. `alt` does not reconstruct hidden views.

## Design Principles

- Keep `alt` generic and pure.
- Keep workspace/session semantics outside `alt`.
- Let each side do whatever it needs to do.
- Keep both sides on symmetric PTY plumbing.
- Keep activation minimal: current tty size sync plus `SIGWINCH`.
- Favor minimal configuration and sensible defaults.
- Keep the control interface human-attachable.

## High-Level Behavior

At runtime, `alt` behaves as follows:

1. Parse startup configuration from CLI flags.
2. Spawn the primary command under a PTY.
3. Defer alternate-side start until first activation.
4. Put the local terminal into raw mode.
5. Proxy local input to the active side PTY and active side PTY output back to the terminal.
6. Drain and intentionally discard inactive-side output.
7. Listen on a Unix control socket.
8. On control commands, switch side, report state, or exit.
9. On activation, ensure the target side is live, sync current tty size, and send `SIGWINCH`.
10. If one side exits, fall back to the other running side. If neither remains, exit.

## CLI

Current CLI:

```text
alt --control <path> --run <path> [--signal-1 <sig>] [--signal-2 <sig>] -- <primary-command...>
```

### Flags

`--control <path>`
: Unix socket path for the control interface.

`--run <path>`
: Alternate-side executable to run on its own PTY.

`--signal-1 <sig>`
: Optional signal to send to side 1's root child PID when switching away from it.

`--signal-2 <sig>`
: Optional signal to send to side 2's root child PID when switching away from it.

`--`
: Separates `alt` options from the child command. Everything after `--` is passed to the child command literally.

## Control Socket

The control socket is intentionally small and line-oriented.

Current commands:

- `help`
- `state`
- `switch <index>`
- `cycle`
- `exit`

Current responses use the shared `ctlwire` message shape:

- `ok`
- `ok <payload>`
- `err <kind>`

The socket is intended to be human-attachable with the generic `attach` tool.

## Side Semantics

Current contract:

- Side 0 is the primary command after `--`.
- Side 1 is the alternate executable from `--run`.
- `alt` does not read or interpret side stdout.
- Inactive-side output is drained and dropped.
- If a side exits and is explicitly reactivated later, it is restarted.
- Optional `--signal-1` / `--signal-2` fire only on switch-away and target that side's root child PID.

## Terminal Behavior

### Child Sides

Both sides run under PTYs so they behave like normal interactive terminal applications.

### Local Terminal

`alt` owns the foreground terminal while it is running.

In normal operation:

- local terminal is placed into raw mode
- active child output is written directly to the terminal
- local input is forwarded directly to the active child PTY

On side activation:

- forwarding switches to the other side
- the newly active side is ensured live
- current tty size is synced to that side
- `SIGWINCH` is sent to that side

### Alternate Screen Policy

`alt` does not own terminal alternate-screen entry or exit for side activation. It only emits a hard local reset and clear at the switch boundary, leaving nested apps to manage any `?1049` usage themselves. It does not own hidden screen restoration for child apps and does not buffer or reconstruct view state.

## Purity and Layering

`alt` should remain generic.

It should **not**:

- infer workspace root
- infer canonical session ids
- inject domain-specific environment variables
- understand `msr` or `wsm` semantics

Higher-level context discovery should happen in outer tooling or in the alternate-side program itself.

## Example Usage

Run a primary shell with an alternate shell:

```bash
alt --control /tmp/test.alt --run /bin/bash -- bash
```

Drive it from another terminal:

```bash
attach /tmp/test.alt
```

Then type:

```text
help
state
switch 1
cycle
exit
```

Use a local helper as the alternate side:

```bash
alt --control /tmp/test.alt --run ./scripts/wsm_menu_alt -- wsm attach foo/bar
```

## Current Implementation Notes

The Zig implementation currently:

- opens `/dev/tty`
- captures and restores terminal attributes with `termios`
- creates a PTY for the primary command and a PTY for the alternate side
- proxies bytes using `poll`
- hosts a simple Unix control socket
- uses an `alt_control` module for command parsing
- emits control replies via `ctlwire`

## Future Direction

Possible future work:

- optional `event ...` lines on the control socket if they add real value
- further alignment with shared control-wire conventions
- continued simplification of the surrounding `wsm` integration surface

Non-goals for now:

- reviving the old hotkey-first model
- making `alt` the mandatory backbone for all `wsm` attach flows
- growing `alt` into a general service manager
