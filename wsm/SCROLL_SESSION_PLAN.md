# Scroll session migration plan

## Goal
Replace the current logs-via-`alt` path with a normal paired session:

- base session: `<id>`
- logs session: `<id>.scroll`

The `.scroll` session is created and attached through the normal `wsm` / `msr` lifecycle, runs the logs viewer command directly, and on exit `wsm` returns to the base session.

## Minimal implementation strategy

### 1. Add a command-backed session create path
Current `session_primitives.createSession(...)` is shell-specific and always assembles:
- `msr(.ctl)`
- `msr(.msr)`
- `vpty`
- `alt`
- scripted shell

Add a sibling primitive for command sessions, conceptually:
- `createCommandSession(...)`

This should:
- reuse normal path generation and socket readiness
- create only the regular control + data sockets
- launch:
  - `msr <ctl> --headless --`
  - `msr <data> --`
  - `vpty --`
  - `<command argv...>`
- not involve `alt`

The existing shell session path can remain as-is for now.

### 2. Make `WorkspaceService` expose command-session creation
Add service helpers parallel to shell session creation:
- `createCommand(...)`
- `createCommandAndAttach(...)`

Inputs:
- session id
- command argv

Use these for `.scroll` only.

### 3. Rework executor `.logs` action
Instead of `altCycle()`, `.logs` should:
1. require a current attached base session
2. derive `<base>.scroll`
3. compute transcript path from the base session data path
4. create a fresh command-backed `.scroll` session running:
   - `wsm/scripts/wsm_logs_viewer <transcript>`
5. attach to `<base>.scroll`
6. remember return target = `<base>`

Recommend recreating `.scroll` fresh each time rather than trying to reuse it.

### 4. Add tiny live return state in executor
Executor should track enough state to auto-return:
- current attached session id
- optional `return_session_id`
- whether current attached session is a managed `.scroll` session

Then when the attached stream dies in `pumpAttachedOutput(...)`:
- if current attached session is a managed `.scroll` session and `return_session_id` is set:
  - reattach to the base session
  - keep interactive mode alive
- otherwise preserve current detach/exit behavior

### 5. Naming helpers
Keep naming logic small and explicit, probably in `policy.zig` or a tiny helper:
- `scrollSessionId(base_id) -> <base>.scroll`
- `isScrollSession(id)`
- `scrollBaseId(id)` if useful

### 6. Keep cleanup simple at first
Do not add new lifecycle machinery initially.

First pass can rely on:
- canonical paired id `<base>.scroll`
- recreate or replace on logs open
- existing cleanup flow for stale artifacts later

A later pass can teach cleanup to recognize `.scroll` sessions specially if needed.

## Suggested implementation order
1. Add naming helpers for `.scroll`
2. Add command-backed create primitive in `session_primitives.zig`
3. Add service wrappers in `service.zig`
4. Add executor state for current session + return target
5. Rework `.logs` action to create/attach `<base>.scroll`
6. Auto-return on `.scroll` session exit
7. Remove or stop using `alt` from the logs path

## Notes
- This keeps logs aligned with the real `wsm/msr` abstraction: ordinary sessions.
- It avoids embedded PTY side-switching semantics for what is really a temporary viewer.
- It should require only light special control in `wsm`, not a new subsystem.
