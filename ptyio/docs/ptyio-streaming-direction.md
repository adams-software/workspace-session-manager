# ptyio streaming direction

## Summary

We should move toward a **stream-first PTY interaction model** across `msr`, `alt`, and `vpty`, while keeping `ptyio` narrow enough to avoid becoming a framework.

Recommended direction:

- keep `ptyio` as the shared PTY/TTY/fd substrate
- allow PTY stream movement to operate against the PTY fd
- lean on **discipline and conventions** rather than hard encapsulation contracts
- avoid pushing app semantics into `ptyio`

This is a middle path between:

- a very low-level substrate that leaves too much correctness burden in each binary
- an over-abstracted PTY runtime framework that callers have to fight

## Problem statement

`msr` was recently refactored toward a more stream-oriented PTY handling model. That work improved behavior under large pastes and other high-volume PTY interaction because it introduced more explicit handling for:

- nonblocking I/O
- partial writes
- buffered stream movement
- bounded pumping
- backpressure-aware flushing

By contrast, `alt` and `vpty` still mostly use a more immediate passthrough style:

- read from one side
- write directly to the other side
- rely on ad hoc loops for correctness

That older shape is simpler initially, but it is more fragile under bursty input/output and duplicates correctness-sensitive stream logic in each binary.

## Recommended architectural direction

## Core decision

Adopt a **B-style model**:

- `PtyChildHost` owns PTY child lifecycle and PTY identity
- callers may use the PTY fd as a streaming endpoint
- shared stream correctness should live in `ptyio` stream primitives/helpers
- single-reader PTY discipline is enforced by convention, not heavy abstraction

This means:

- `PtyChildHost` remains responsible for:
  - spawn/start
  - resize
  - signal delivery
  - refresh/wait
  - close
  - exposing PTY identity/access for stream integration
- stream movement remains a separate concern from child lifecycle

## Why this direction

This direction gives us:

- reuse of the same stream machinery for PTY and non-PTY fds
- a clean migration path for `alt` and `vpty`
- less pressure to invent host-specific buffered read APIs
- less risk of building a framework-like abstraction too early

It intentionally avoids:

- host-owned hidden buffering state
- allocator-heavy hot-path PTY output APIs as the primary interaction model
- callback- or framework-driven PTY app loops
- pushing `msr`, `alt`, or `vpty` semantics into `ptyio`

## Shared vs non-shared responsibilities

## Shared in `ptyio`

These look reusable across all three binaries:

- PTY child lifecycle
- nonblocking fd setup
- queue-backed byte movement
- partial write handling
- EOF / HUP / would-block handling
- bounded read/write pumping
- minimal tty helpers

## Not shared in `ptyio`

These should stay app-local:

### `msr`
- session semantics
- attach/detach/owner-forwarding
- framed transport protocol
- nested attach behavior

### `alt`
- hotkey parsing/interception
- alternate-screen entry/exit
- hook execution and hook UX
- local mode switching semantics

### `vpty`
- vterm integration
- renderer scheduling
- snapshot/diff rendering
- side-effect policy

## Public surface direction for `ptyio`

## Keep

### `PtyChildHost`
Keep it as the public PTY child lifecycle abstraction.

It should remain responsible for:

- process spawn/start
- resize
- terminate/signal
- refresh/wait
- close
- exposing PTY access for stream integration

### `ByteQueue`
Keep as the explicit buffering primitive.

### `fd_stream`
Keep as the shared low-level nonblocking read/write helper layer.

### tty helpers
Keep raw mode and tty size helpers minimal and mechanical.

## Directional changes

### PTY fd exposure
We should likely support a deliberate PTY-fd access path such as `masterFd()`.

Rationale:

- it allows reuse of the same stream machinery for PTY and socket/tty fds
- it avoids forcing host-specific buffered read APIs
- it keeps queueing policy out of the host object

This should be documented with a clear convention:

- exactly one logical PTY output reader
- stream buffering/pumping lives above the host

### Naming cleanup
Settle canonical names and stop carrying transitional naming if possible.

Likely canonical host naming:

- `currentState()` or `state()`
- `masterFd()`
- `exitStatus()`
- `resize(...)`
- `signalWinch()`
- `terminate(...)`
- `refresh()`
- `wait()`
- `close()`

## Avoid as primary public direction

These should not be the main long-term interface shape:

- allocator-returning PTY read APIs on the hot path
- host-owned hidden buffering
- app-loop ownership in `ptyio`
- callback-driven PTY frameworks

## Stream helper direction

## Recommendation

Do **not** jump straight to a full generic PTY framework.

Instead, if we add more opinion to `ptyio`, add only a **small stream-helper layer** above `ByteQueue` and `fd_stream`.

Possible location:

- `ptyio/src/stream/pump.zig`
- or `ptyio/src/stream/bridge.zig`

## Intended responsibilities of that helper layer

Only mechanical stream movement concerns:

- queue bytes from fd/PTY endpoints
- flush queue contents toward endpoints
- bounded pumping budgets
- progress reporting
- would-block / eof / closed reporting

## Explicit non-goals for that helper layer

- poll-loop ownership for all apps
- terminal UI behavior
- hotkeys
- hooks
- attach/session policy
- rendering policy

This layer should simplify correctness without owning application control flow.

## Feasibility assessment

## `msr`
Already the best evidence that the stream-first direction is sound.

`msr` currently uses:

- `ByteQueue`
- nonblocking setup
- bounded pumping
- `fd_stream.writeFromQueue(...)`
- framed transport pumping

This is the strongest proof that queue-based stream movement improves robustness.

## `alt`
Feasible to migrate.

Current `alt` is still fundamentally non-streaming. A good migration target would be:

- tty input treated as a stream
- hotkey interception applied before enqueue to PTY
- PTY output treated as a stream toward tty
- hook execution remains an app-local mode switch

This should improve correctness while keeping `alt` conceptually simple.

## `vpty`
Also feasible, but with a stricter boundary.

The PTY side can become stream-first while leaving rendering local:

- stdin/input queue toward PTY
- PTY output consumed as a stream
- decoded bytes fed into terminal state / side effects / renderer

The renderer should remain fully local to `vpty`.

## Integration strategy by binary

## Phase 1: settle `ptyio` surface

Before migrating more binaries:

1. settle canonical `PtyChildHost` naming
2. decide the intentional PTY-fd access path (`masterFd()` or equivalent)
3. keep `ByteQueue` + `fd_stream` as the preferred stream mechanics
4. avoid committing further to allocator-per-read PTY APIs as the primary hot path

## Phase 2: `alt` integration

Use `alt` as the first migration target for the new direction.

### `alt` should import from `ptyio`
- `PtyChildHost`
- tty/raw helpers
- `ByteQueue` / `fd_stream` and any tiny shared pump helpers if added

### `alt` should keep locally
- hotkey parsing
- input interception policy
- hook execution
- alternate-screen behavior
- hook error messaging

### intended `alt` shape after migration
- local tty open/ownership remains local or thin-wrapper local
- PTY child lifecycle comes from `PtyChildHost`
- tty input becomes buffered stream movement
- PTY output becomes buffered stream movement
- hotkey interception occurs on the tty input stream before PTY enqueue
- hook execution temporarily pauses normal passthrough and then resumes it

## Phase 3: `vpty` integration

After `alt` proves the model:

### `vpty` should import from `ptyio`
- `PtyChildHost`
- tty/raw helpers
- `ByteQueue` / `fd_stream` and any tiny shared pump helpers if added

### `vpty` should keep locally
- terminal state integration
- rendering
- side effects
- redraw scheduling

### intended `vpty` shape after migration
- PTY child lifecycle via `PtyChildHost`
- stdin/input path uses stream-first buffering
- PTY output path uses stream-first consumption
- output bytes are fed into terminal state / side-effect pipeline
- rendering remains local and policy-specific

## Phase 4: optional `msr` cleanup

Only after the above are stable:

- evaluate whether `msr` should consume more of the shared stream helper layer
- do not force `msr` to hide protocol/session logic behind generic abstractions

## Design constraints

To avoid fighting the design later:

- do not abstract app semantics into `ptyio`
- do not make `ptyio` own the full event loop for all consumers
- do not require all consumers to share identical fairness or pump ordering policies
- prefer discipline and conventions over hard framework contracts
- keep the shared layer mechanical and composable

## Bottom line recommendation

Recommended direction:

- keep `ptyio` as the PTY/TTY/fd substrate
- allow PTY streaming to work against the PTY fd
- keep buffering and pumping shared where it is purely mechanical
- keep app semantics local to each binary
- migrate `alt` first, then `vpty`

This gives us a realistic path toward a stream-first architecture across all three binaries without prematurely locking the codebase into a framework we may regret.
