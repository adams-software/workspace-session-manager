# Terminal State Reattach v0

## Purpose

Define the narrowest useful terminal-state integration for `msr` that enables:

- detach / reattach to a live session
- immediate screen reconstruction from host memory
- no persistence
- no visual history/replay beyond the minimum required handoff buffer
- no breaking changes to the existing attach path

This document is intentionally narrower than `terminal-state-integration-guide.md`.
It describes the first implementation we actually want in this codebase.

---

## Scope

### In scope

- in-memory terminal-state engine inside `SessionHost`
- host-maintained `screenSeq`
- explicit `getScreenSnapshot` control request
- optional `afterSeq` parameter on attach
- bounded in-memory replay buffer of raw PTY output chunks
- strict replay boundary validation
- feature-flagged / optional behavior

### Out of scope

- persistence / crash recovery
- full visual history playback
- screen diff protocol
- row-patch update stream
- client-side terminal emulation as primary truth
- changing the default attach flow when no snapshot/seq is requested

---

## Core Design

### Existing attach remains the default

If a client performs ordinary attach without a sequence boundary:

- attach behavior is unchanged
- live stream is the same raw PTY byte stream as today

This is a hard compatibility rule.

### Explicit snapshot fetch

Add a new control operation:

- `get_screen_snapshot`

Behavior:

- if terminal-state feature is disabled or unavailable for the session: return explicit unsupported / unavailable error
- if enabled: return current in-memory screen snapshot plus `screenSeq`

### Attach with boundary

Extend attach with an optional parameter:

- `afterSeq?: u64`

Behavior:

- if `afterSeq` is absent: current attach path unchanged
- if `afterSeq` is present:
  - host validates that terminal-state support is enabled
  - host validates that replay for `afterSeq` is still available
  - host replays raw PTY output chunks whose seq is strictly greater than `afterSeq`
  - host then continues with the normal live raw PTY byte stream
- if replay cannot satisfy the boundary exactly: attach fails with a clean resync-required style error

This keeps one attach entry point while making reattach explicit and sequence-bounded.

---

## Sequence Semantics

`screenSeq: u64` is a monotonic host-local sequence number.

### Required invariant

A screen snapshot with `seq = N` represents terminal state exactly after all PTY chunks up to and including sequence `N` have been applied to the terminal-state engine.

### Host rule

For each PTY output chunk that changes terminal-visible state:

1. feed chunk into terminal-state engine
2. advance `screenSeq`
3. store the raw PTY chunk together with the resulting sequence number in the replay buffer

This means replay for `afterSeq = N` consists of all buffered chunks with:

- `seq > N`

---

## Why raw replay is enough for v0

We do **not** need a new long-lived screen-update stream in v0.

Client flow is:

1. request screen snapshot
2. render snapshot immediately
3. attach with `afterSeq = snapshot.seq`
4. receive raw PTY chunks after that boundary
5. continue with the normal attach stream

This preserves the existing attach stream shape and avoids introducing a parallel screen-update streaming protocol in the first version.

---

## Feature Flag

Terminal-state reattach should be optional.

Acceptable shapes:

- compile-time build flag
- runtime session-host option
- server/session config flag

Preferred behavior:

- disabled by default until proven stable
- when disabled:
  - `get_screen_snapshot` returns unsupported / unavailable
  - attach ignores missing `afterSeq` and behaves normally
  - attach with `afterSeq` returns unsupported / invalid-request style error

---

## Host-side State

`SessionHost` (or the nearest owning server layer) needs:

- terminal-state engine instance (optional, feature-gated)
- current `screenSeq: u64`
- current `ScreenSnapshot`
- bounded replay buffer of `{ seq, bytes }`

Suggested replay buffer entry:

```ts
{
  seq: number,
  bytes: Uint8Array,
}
```

Suggested buffer policy for v0:

- fixed-count ring buffer
- no persistence
- drop oldest entries when full

---

## Snapshot Shape

A straightforward first shape is fine:

```ts
type ScreenSnapshot = {
  rows: number
  cols: number
  cursorRow: number
  cursorCol: number
  cursorVisible: boolean
  altScreen: boolean
  title?: string
  seq: number
  cells: ScreenCell[][]
}
```

For v0, correctness matters more than compactness.

---

## New Control Surface

### `get_screen_snapshot`

Request:

- no arguments

Response on success:

- snapshot object

Errors:

- `unsupported`
- `snapshot_unavailable`
- `invalid_state`

### `attach(afterSeq?)`

Current attach request gains optional field:

- `after_seq?: u64`

Behavior:

- absent: existing attach semantics
- present: replay buffered chunks with `seq > after_seq`, then continue live stream

Errors when `after_seq` is present:

- `unsupported`
- `invalid_seq`
- `replay_gap`
- `snapshot_required`
- existing attach errors still apply (`attach_conflict`, etc.)

---

## Client Rules

### Ordinary client

- call attach without `afterSeq`
- unchanged behavior

### Snapshot-aware client

1. call `get_screen_snapshot`
2. if unsupported/unavailable: fall back to plain attach
3. render returned snapshot
4. call attach with `afterSeq = snapshot.seq`
5. apply raw PTY bytes as normal after that boundary

### Error handling

If attach with `afterSeq` fails due to replay boundary issues:

- discard local reconstructed state
- request a fresh snapshot
- retry from the new boundary

---

## Acceptance Criteria

The feature is correct when:

1. a live session with terminal-state feature enabled can return a screen snapshot in memory
2. a client can detach and reattach, render the current screen immediately, and continue from the correct PTY byte boundary
3. no PTY output after snapshot seq is lost on reattach
4. if replay boundary is unavailable, the server fails cleanly instead of silently skipping bytes
5. ordinary attach without `afterSeq` behaves exactly as before
6. the feature can be disabled cleanly without affecting legacy attach behavior

---

## Suggested Implementation Order

1. feature flag plumbing
2. terminal-state engine abstraction in host
3. `screenSeq` + replay buffer in host
4. `get_screen_snapshot` control request/response
5. optional `after_seq` on attach request
6. replay-buffer validation + replay on attach
7. client-side experiment / smoke test with detach-reattach

---

## Deferred Questions

Not required for v0:

- diff/patch update format
- durable checkpoints
- replay buffer sizing heuristics beyond a fixed count
- explicit capability query versus relying on unsupported errors
- explicit “refresh from snapshot” client command
- screen-update streaming separate from raw PTY bytes
