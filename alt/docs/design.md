# Alt: Local Hotkey Alt-Screen Passthrough

## Summary

`alt` is a thin terminal-owning passthrough shim.

It runs a child command under normal interactive terminal passthrough, but reserves a single local hotkey. When that hotkey is pressed, `alt` temporarily pauses passthrough, switches to the terminal alternate screen, runs a local hook executable, exits the alternate screen when the hook finishes, and then resumes the original passthrough session.

The goal is to add a lightweight local control plane above an existing interactive terminal stack without pushing workspace semantics into lower layers like `msr` or terminal-rendering semantics into `wsm`.

## Motivation

Current session usage has a useful higher-level control model in `wsm`, but once an interactive attach is running, the foreground terminal is owned by the live session. That makes it hard to open a local control menu or similar UI with a hotkey while preserving the current screen and returning to it cleanly.

We want:

* a local hotkey while attached
* a temporary local UI or script execution path
* automatic return to the original interactive session view
* no special return protocol from the hook
* no coupling to `wsm`, `msr`, or `vpty` internals

## Non-Goals

`alt` is **not** intended to be:

* a session manager
* a terminal multiplexer like tmux
* a full terminal emulator
* a workspace-aware tool
* a command router for hook results
* a structured IPC protocol

For the initial version, `alt` does not interpret hook output. The hook runs for side effects only.

## Design Principles

* Keep `alt` generic and pure.
* Keep workspace/session semantics outside `alt`.
* Let the hook do whatever it needs to do.
* Preserve the user’s current session screen by using the terminal alternate screen.
* Resume normal passthrough automatically after the hook exits.
* Favor minimal configuration and sensible defaults.

## High-Level Behavior

At runtime, `alt` behaves as follows:

1. Parse startup configuration from flags and environment.
2. Spawn the child command under a PTY.
3. Put the local terminal into raw mode.
4. Proxy local input to the child PTY and child PTY output back to the terminal.
5. Watch for the configured local hotkey in the input stream.
6. When the hotkey is pressed:

   1. pause normal passthrough
   2. restore terminal mode as needed for the hook
   3. enter alternate screen
   4. run the configured hook executable
   5. leave alternate screen when the hook exits
   6. re-enable raw passthrough mode
   7. resume the child session

The child session continues to exist throughout this flow unless the hook itself changes external state.

## CLI

Initial CLI:

```text
alt [--key <spec>] [--run <path>] -- <child-command...>
```

### Flags

`--key <spec>`
: Local hotkey specification. Overrides `ALT_KEY`.

`--run <path>`
: Hook executable to run when the hotkey is pressed. Overrides `ALT_RUN`.

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

## Hook Semantics

The hook is executed as a normal local process.

Initial contract:

* The hook is invoked for side effects only.
* `alt` does not read or interpret the hook’s stdout.
* `alt` does not require the hook to return a structured command.
* When the hook exits, `alt` returns to the prior passthrough session view.

This keeps the first version extremely simple.

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

* normal forwarding pauses
* the terminal leaves raw passthrough mode as needed for the hook
* `alt` enters alternate screen
* the hook runs attached to the terminal
* on hook exit, `alt` leaves alternate screen
* raw passthrough mode is restored

### Why Alternate Screen

Using the terminal alternate screen gives a clean way to show a temporary local UI without manually repainting or preserving the child session contents.

This allows the hook to display whatever it needs, then disappear cleanly, revealing the original session view underneath.

## Purity and Layering

`alt` should remain generic.

It should **not**:

* infer workspace root
* infer canonical session ids
* inject domain-specific environment variables
* understand `msr`, `dsm`, or `wsm` semantics

It may infer only what is necessary for its own operation, such as the child argv and the configured hotkey/hook executable.

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

Explicit hook executable:

```bash
alt --run ./scripts/wsm_menu -- wsm attach foo/bar
```

Environment-driven configuration:

```bash
ALT_KEY=ctrl-g ALT_RUN=./scripts/wsm_menu alt -- wsm attach foo/bar
```

Generic non-WSM usage:

```bash
alt --run ./local-tools/debug-menu -- bash
```

## Initial Implementation Notes

The initial Zig prototype is expected to:

* open `/dev/tty`
* capture and restore terminal attributes with `termios`
* create a PTY for the child command
* proxy bytes using `poll`
* intercept the configured hotkey locally before forwarding
* run the hook with inherited environment and inherited stdio
* use standard alternate-screen enter/leave sequences

## Expected Limitations in V1

The first version may intentionally omit:

* hook arguments beyond a single executable path
* SIGWINCH forwarding
* transparent literal send-through of the reserved hotkey
* sophisticated error reporting/UI
* action-return protocol from the hook
* nested local menus or overlay composition

These can be added later if needed.

## Future Extensions

Possible future enhancements:

* forward resize events to the child PTY
* allow a wrapper or argv form for hook execution
* add a “send literal hotkey” escape path
* allow optional hook output interpretation
* add structured logging/debug mode
* expose clearer exit status propagation

None of these are required for the initial feature.

## Open Questions

These are intentionally left open for now:

* Whether the default hook should remain `wsm_menu` or become unset by default
* Whether `alt` should eventually support hook args directly
* Whether hotkey passthrough for the reserved key is needed immediately
* Whether the final install path should make `alt` a general utility or an internal helper in the session stack

## Recommended V1 Outcome

A successful first version should prove the following:

* an interactive child command can run transparently through `alt`
* the configured hotkey is intercepted locally
* the hook executable runs in alternate screen
* exiting the hook returns to the original session view
* the design works without embedding higher-level workspace/session semantics in `alt`

