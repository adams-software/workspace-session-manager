# Session Runtime Invariants

_Status: active design note_

This document captures the **runtime invariants** we want for `msr` so future work hardens the system instead of adding local fixes that fight each other.

The goal is the **strictest rules that still yield the simplest system**.

---

## Why this exists

Recent work on terminal-state resume (`--vterm`, snapshot + replay-after-seq) exposed that several important behaviors had been implicit rather than specified:

- who owns PTY reads
- when detach is considered complete
- how plain attach differs from vterm attach
- what nested-mode commands are allowed to do to the outer attach bridge
- what bridge shutdown means

When those rules are implicit, features appear to work until a new capability touches the same runtime seam.

This note turns those assumptions into explicit constraints.

---

## 1. PTY read ownership

### Invariant

The PTY master has **exactly one reader**.

Every byte read from the PTY is:

1. read exactly once
2. synchronously offered to replay / terminal-state capture
3. optionally forwarded to the attached owner from that same drained byte stream

### Consequences

- No second PTY reader may exist in parallel.
- Live forwarding must never re-read the PTY after replay/vterm capture already consumed it.
- Replay/vterm capture must never depend on a different PTY read path than live forwarding.

### Why

This avoids split-reader races where one subsystem drains PTY bytes before another can see them.

---

## 2. Refresh semantics

### Invariant

`SessionHost.refresh()` is **lifecycle-only**.

It is responsible for:

- child/process state updates
- exit detection / waitpid polling

It is **not** responsible for implicit PTY stream consumption.

### Consequences

- PTY draining must happen through an explicit drain API.
- Callers must not assume that `refresh()` updates replay state, terminal state, or `screen_seq`.

### Why

Combining lifecycle polling and PTY consumption caused hidden ordering dependencies and stale assumptions.

---

## 3. Explicit PTY drain API

### Invariant

There is one explicit PTY drain path that:

- polls / reads available PTY bytes
- records them into replay / terminal-state capture
- exposes those exact bytes to the caller for forwarding decisions

### Preferred shape

A host API equivalent to:

- `drainObservedPtyOutput()`

which returns drained chunks that have already been recorded.

### Consequences

- Server orchestration decides whether drained bytes are forwarded to an attached owner.
- When no owner exists, drained bytes are still recorded and then discarded/freed.

### Why

This keeps ownership explicit and makes attach, replay, and snapshot semantics stable.

---

## 4. Detached-time capture

### Invariant

Replay state, terminal-state, and `screen_seq` must continue to advance while the session is **unattached**.

### Consequences

- PTY draining cannot only happen while an owner exists.
- Unattached sessions must still run the explicit PTY drain path.

### Why

A detached session must continue to accumulate state for resumable reattach.

---

## 5. Attach semantics

### Invariant

Attach semantics are mode-dependent and explicit.

#### Plain attach

- plain attach is **live stream only**
- no promise of historical screen reconstruction
- no replay unless explicitly requested by protocol semantics

#### Vterm attach

- when terminal-state support is enabled, attach may:
  1. obtain a snapshot
  2. attach with `after_seq = snapshot.seq`
  3. render the snapshot only after attach succeeds
  4. receive replay/live tail after the snapshot boundary

### Consequences

- Plain attach and vterm attach must not be conflated.
- Snapshot rendering must never occur before attach success is confirmed.

### Why

This keeps user-visible semantics simple and prevents half-attached visual corruption.

---

## 6. Detach completion semantics

### Invariant

Detach is a **bounded checkpoint**.

Detach is not complete until all **currently-readable** PTY bytes have been drained and recorded into replay / terminal-state.

Detach does **not** wait for hypothetical future output.

### Consequences

- Detach must run an explicit PTY drain pass before final owner release.
- The guarantee is:
  - output already emitted and readable by detach-completion time is captured
  - future output is not waited on

### Why

This gives resumable reattach a meaningful checkpoint without blocking forever.

---

## 7. Snapshot / replay lookup semantics

### Invariant

Operations that consult terminal-state or replay history must first ensure the latest currently-readable PTY bytes have been drained and recorded.

This applies especially to:

- `get_screen_snapshot`
- `attach(after_seq=...)`

### Consequences

- snapshot and replay lookup must not rely on `refresh()` to make state current
- they must explicitly drain before consulting state

### Why

Otherwise snapshots and replay boundaries can lag behind real PTY output.

---

## 8. Bridge exit semantics

### Invariant

Attach bridge termination causes must be **classified**, not collapsed into a generic failure.

At minimum, distinguish:

- clean detach
- intentional bridge replacement / nested attach transition
- owner disconnect
- protocol failure
- IO failure

### Consequences

- HUP/ERR on the attachment fd is not automatically equivalent to “attach stream failed”.
- The bridge/runtime should preserve semantic intent when possible.

### Why

Nested control operations and intentional transitions should not be reported as generic breakage.

---

## 9. Nested-mode semantics

### Invariant

If `MSR_SESSION` is propagated into the child shell, nested mode inside the attached session is **intentional product behavior**.

Therefore:

- nested commands must be robust enough not to accidentally destabilize the outer bridge
- outer bridge logic must tolerate legitimate current-session control transitions

### Consequences

- inner `msr` invocations inside attached sessions are a supported scenario, not a misuse case
- the runtime must distinguish nested control effects from generic bridge failure

### Why

Nested mode is part of the product, so runtime behavior must support it explicitly.

---

## 10. Ownership and state transitions

### Invariant

Owner state transitions should go through the model/state-machine path whenever practical.

Direct ad hoc mutation of owner state should be minimized and treated as suspicious.

### Consequences

- detach / attach / owner-forward transitions should be consistent with model actions
- cleanup side effects should not depend on scattered imperative mutations

### Why

Hidden state changes are exactly where attach/bridge lifecycle bugs tend to accumulate.

---

## 11. Implementation guidance

These invariants imply the following preferred runtime shape:

1. `_host` loop runs server orchestration and explicit PTY drains
2. PTY bytes are drained through one API only
3. server decides whether drained bytes are forwarded to an owner
4. replay/vterm capture always sees the same bytes that forwarding sees
5. detach performs a bounded checkpoint drain before final owner release
6. snapshot/replay lookup explicitly drain before consulting state

---

## 12. Test implications

The runtime should keep regression coverage for at least these cases:

- plain attach produces live shell behavior
- vterm snapshot + reattach restores visible state
- replay-after-seq returns only tail after snapshot boundary
- detached sessions still advance terminal-state/replay
- detach checkpoint preserves output emitted immediately before detach
- nested `msr` inside an attached session does not destabilize the outer bridge unintentionally

---

## 13. Non-goals

These invariants do **not** require:

- waiting for all future PTY output before detach
- perfect historical restoration for plain attach
- exposing snapshot internals directly to end users

They are meant to make the runtime simple, explicit, and robust enough for both plain attach and resumable attach.
