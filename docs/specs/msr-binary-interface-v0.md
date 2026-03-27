# msr Binary + User Interface Spec (v0)

Status: draft

## 1) Purpose
Define a minimal, usable CLI for `msr` while keeping runtime scope small.

This spec covers:
- single-binary process model
- user-facing commands
- lifecycle semantics
- error/exit behavior
- implementation slices

## 2) Goals / Non-goals

### Goals
- Single binary (`msr`) for both control and host runtime.
- Minimal command surface for real usage.
- Behavior aligned with current runtime primitives:
  - create
  - attach
  - resize
  - terminate
  - wait
- Keep single-attacher default semantics.

### Non-goals (v0)
- Multi-client attach/fanout.
- Replay/screen restore.
- Logging/history features.
- Rich project/session discovery UX.
- Stable public RPC protocol.

## 3) Process Model (single binary, hidden host)

Design principle: **thin passthrough layers**.
- Library (`src/lib.zig`) owns session semantics and lifecycle.
- Host role owns transport/streaming and delegates operations to library primitives.
- CLI role only parses user input and forwards to host/library.

`msr` runs in two roles:

1. **Control role (user command)**
   - invoked by user (`msr create`, `msr attach`, ...)
   - starts/contacts host process as needed

2. **Host role (internal)**
   - hidden internal mode: `msr _host ...`
   - owns PTY master, child PID, listener socket, attach lifecycle

### Create flow
`msr create <path> -- <cmd...>`:
- validates path + args
- spawns detached `msr _host <path> -- <cmd...>`
- returns after host reports ready (or timeout/failure)

### Attach flow
`msr attach <path>`:
- connects to socket at `<path>`
- bridges caller stdio <-> host session socket
- exits on detach/session end/connection close

This keeps one binary while preserving daemon-like persistence.

## 4) User-facing CLI (v0)

## 4.1 Commands

- `msr create <path> -- <cmd...>`
- `msr attach <path> [--takeover]`
- `msr resize <path> <cols> <rows>`
- `msr terminate <path> [TERM|INT|KILL]`
- `msr wait <path>`
- `msr exists <path>`

Internal (not documented in normal help):
- `msr _host <path> -- <cmd...>`

## 4.2 Notes
- `--takeover` maps to attach mode `takeover`; default is `exclusive`.
- `<path>` is a unix socket path and session identifier.
- `create` should fail if a live session exists at path.

## 5) Semantics

### 5.1 create
- Success when host is running and socket ready.
- Error if path is already active.
- Stale socket reclaim policy: connect-check before unlink.

### 5.2 attach
- Exactly one active attacher unless takeover mode.
- Detach conditions (v0):
  - client disconnect
  - session PTY end
  - I/O hangup/error

### 5.3 resize
- Applies `TIOCSWINSZ` to PTY.
- Fails for missing/non-running session.

### 5.4 terminate
- Sends signal to child process.
- `TERM` default.

### 5.5 wait
- Returns exit status (code or signal) and performs cleanup.

### 5.6 exists
- true if active session or valid socket endpoint exists.

## 6) Exit Codes (proposed minimal)

- `0` success
- `1` user/runtime error (invalid args, session not found, busy, permission)
- `2` internal/unexpected failure

(Keep coarse for v0; can split later.)

## 7) Errors (high-level mapping)

User-visible classes:
- invalid arguments
- session not found
- session already running / attach busy
- permission denied
- unsupported (internal placeholder only; should be avoided in user paths)

## 8) Minimal implementation slices

### Slice A — CLI parser + command dispatch
- Add command parser in `src/main.zig`.
- Wire subcommands to runtime calls.

### Slice B — Internal host entrypoint
- Add `_host` mode for long-lived runtime owner.
- Implement readiness signaling for `create` caller.

### Slice C — Control command wiring
- `create`, `exists`, `resize`, `terminate`, `wait` end-to-end.

### Slice D — Attach command UX
- `attach <path>` stdio bridge through session socket.
- `--takeover` mapping.

### Slice E — Smoke checks
- create -> attach -> detach -> reattach -> terminate -> wait.

## 9) Open questions
- Should `wait` operate remotely via control socket or only host-local?
- Should `create` block until command exits if host spawn fails after ready window?
- Do we expose `_host` in help with “internal” warning, or hide fully?

## 10) Recommendation
Proceed with slices A+B first. That gets a minimal but actually usable single-binary workflow quickly, without widening scope.
