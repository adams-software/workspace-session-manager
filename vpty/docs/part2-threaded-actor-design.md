# vpty Part 2: Threaded Actor Architecture

## Status

Part 1 established the core conceptual boundaries for `vpty`:

- `TerminalModel` is the authoritative terminal state
- `StdoutActor` owns stdout semantics
- render output is replaceable
- control output is durable
- committed render progress is explicit
- the runtime loop is already split into actor-like stages

This means threading is now justified. Before Part 1, multithreading would have spread a monolith across threads. After Part 1, the ownership boundaries are strong enough to make a threaded design coherent and safer.

## Current Part 1 checkpoint reality

As of checkpoint commit `daa095c` (`vpty: checkpoint actorized single-threaded runtime`), the live code is at this state:

- still single-threaded
- explicit staged scheduler in `vpty_main.zig`
- `TerminalModel` extracted and authoritative
- `StdoutActor` is the sole stdout owner
- `RenderActor` owns render-side state
- explicit committed render handoff exists from stdout into both model and renderer
- callback-driven render invalidation has been removed
- old `OutputSink` has been removed

Important caveats from the checkpoint:

- renderer is currently in **full-frame convergence mode**
- intended end-state is still: whole frame on resize / forced redraw, byte diffs otherwise
- large paste into `nvim` still locks up and is unresolved
- visual rendering improved under full-frame mode, so diff/render semantics were at least part of the earlier artifact problem

This document should be read as a Part 2 proposal grounded in that actual checkpoint, not as a claim that Part 1 solved the paste issue.

---

## Goals

Part 2 moves `vpty` from a single-threaded actorized scheduler to a true multi-threaded actor runtime.

Primary goals:

- isolate PTY drainage from render cost
- isolate stdout flushing from PTY traffic
- allow rendering to lag or coalesce without blocking transport
- preserve durable side effects like OSC 52
- prevent large paste/redraw storms from stalling the whole process

## Non-goal clarification

Part 2 is not automatically justified just because a paste lockup still exists. The purpose of Part 2 is to isolate transport, stdout, and rendering so the runtime is healthier under load. It may improve the lockup class, but it should not be sold as a guaranteed direct fix without validation.

---

## Core invariants

These invariants remain the foundation of the design:

- PTY output must always be drained.
- PTY input progress must not depend on rendering progress.
- Control output is durable and ordered.
- Render output is replaceable and coalescible.
- `TerminalModel` is authoritative.
- Visual assumptions advance only on committed stdout progress, not on render generation.

Part 2 adds runtime-level invariants:

- no actor may block another actor’s core progress path
- PTY drainage must continue even if rendering is slow
- stdout flushing must continue even if PTY traffic is heavy
- render generation may skip intermediate states, but transport may not
- cross-thread communication must preserve durable vs replaceable semantics

---

## High-level thread model

Start with **3 threads**, not 4.

### Thread 1: Transport thread

Owns:

- stdin reads
- PTY writes
- PTY reads
- side-effect splitting
- `TerminalModel`
- resize application to PTY and model

Responsibilities:

- keep PTY alive and flowing
- enqueue durable control bytes to stdout thread
- notify render thread when model changes
- consume committed render notifications and mark model committed

This thread must never stop draining PTY output just because rendering or stdout is behind.

### Thread 2: Stdout thread

Owns:

- stdout fd
- `StdoutActor`
- durable control queue
- replaceable render candidate
- committed render publication

Responsibilities:

- flush control output first
- flush current render candidate second
- publish committed render notifications

This is the only thread allowed to touch stdout.

### Thread 3: Render thread

Owns:

- `RenderActor`
- render buffers
- snapshot-driven frame generation

Responsibilities:

- observe model version changes
- coalesce updates
- build newest useful render candidate
- publish replaceable candidate to stdout thread
- consume committed render notifications

This keeps snapshot and byte-generation cost away from PTY drainage.

---

## Why 3 threads first

Do not split stdin and PTY output into separate threads yet.

Reasons:

- stdin -> PTY and PTY -> model are both transport-plane concerns
- fewer queues and wakeups
- lower implementation risk
- enough separation to test the architecture properly

If 3 threads still are not enough, adding a fourth thread later becomes much easier.

---

## Ownership table

| Component | Owner |
|---|---|
| `SessionHost` | Transport thread |
| `TransportState` | Transport thread |
| `SideEffectForwarder` | Transport thread |
| `TerminalModel` | Transport thread |
| `RenderActor` | Render thread |
| `StdoutActor` | Stdout thread |
| stdout fd | Stdout thread |
| PTY master fd | Transport thread |

No shared ownership of these actor objects.

---

## Dataflow

```text
stdin -> Transport thread -> PTY child input

PTY child output -> Transport thread
  -> control bytes -> Stdout thread durable FIFO
  -> screen bytes -> TerminalModel(version++)
                   -> Render thread notification

Render thread
  -> snapshot TerminalModel
  -> build render candidate
  -> publish latest candidate to Stdout thread

Stdout thread
  -> flush control queue
  -> flush current render candidate
  -> publish committed render version

Transport thread
  -> consume committed render version
  -> mark TerminalModel committed

Render thread
  -> consume committed render version
  -> advance committed frame state
```

---

## Queue and mailbox semantics

This design needs three communication semantics.

### 1. Durable FIFO

Used for:

- control bytes such as OSC 52
- shutdown / reset control output if modeled as control messages

Properties:

- ordered
- lossless
- backpressured

### 2. Latest-value mailbox

Used for:

- render candidate publication
- committed render version
- model-update notifications

Properties:

- latest wins
- old value may be replaced
- no historical backlog required

### 3. Wake/notify primitive

Used for:

- waking sleeping threads when new work appears
- shutdown propagation

Properties:

- coalesced
- no durable history needed

---

## Recommended local primitives

Keep these local to `vpty` for now.

### Durable FIFO

```zig
const DurableQueue(T) = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    items: std.ArrayList(T),
    closed: bool,
};
```

### Latest-value mailbox

```zig
const LatestBox(T) = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    value: ?T,
    closed: bool,
};
```

Writing replaces the old value. Reading gets the latest available value.

### Wake mechanism

Start with:

- mutex + condition variable
- timed waits where useful

This keeps the implementation simple and local.

---

## Shared model strategy

There are two main options for `TerminalModel` access.

### Option A: mutex-protected shared model

Recommended first implementation.

Shape:

```zig
const SharedTerminalModel = struct {
    mutex: std.Thread.Mutex = .{},
    model: TerminalModel,
};
```

Usage:

- transport thread locks to mutate model
- render thread locks only long enough to snapshot
- render thread unlocks before expensive byte generation

This is the simplest correct approach.

### Option B: copied snapshots / double buffering

Possible later optimization.

This reduces lock hold time further, but adds more complexity. Do not start here.

---

## Critical locking rule

The render thread must **not** hold the model lock while generating render bytes.

Correct pattern:

1. lock
2. snapshot model
3. unlock
4. generate candidate from snapshot
5. publish candidate

If the render thread holds the model lock during full byte generation, the old starvation problem comes back via mutex contention.

---

## Message contracts

### Control publication

Transport -> Stdout:

```zig
const ControlChunk = struct {
    bytes: []u8,
};
```

Durable FIFO semantics.

### Render publication

Render -> Stdout:

```zig
const RenderPublish = struct {
    version: u64,
    bytes: []u8,
};
```

Latest-only semantics.

A newer render candidate replaces an older pending candidate.

### Commit notice

Stdout -> Transport and Render:

```zig
const CommitNotice = struct {
    version: u64,
};
```

Latest-only semantics.
Monotonic by version.

### Model update notice

Transport -> Render:

```zig
const ModelChanged = struct {
    version: u64,
};
```

Latest-only semantics.

The render thread does not need one message per PTY chunk. It only needs to know the latest model version worth considering.

---

## Actor loop sketches

### Transport thread loop

Responsibilities:

- drain stdin
- flush PTY input
- drain PTY output
- split control vs screen bytes
- update model
- publish latest model version
- consume committed render notices

Sketch:

```text
loop:
  poll stdin / pty / resize / shutdown
  drain stdin -> PTY write queue
  flush PTY write queue
  drain PTY output
  split PTY output:
    control -> stdout durable queue
    screen -> model.feedScreenBytes()
  publish latest model version to render mailbox
  consume latest committed version:
    model.markCommittedThrough(version)
```

### Render thread loop

Responsibilities:

- wait for latest model changes
- snapshot model
- build newest useful frame candidate
- publish candidate
- consume committed notices

Sketch:

```text
loop:
  wait for model-changed notification or shutdown
  read latest model version
  compare against committed / last generated state
  snapshot model under lock
  unlock
  generate frame candidate
  publish candidate to stdout mailbox
  consume latest committed version:
    render_actor.noteCommittedThrough(version)
```

### Stdout thread loop

Responsibilities:

- flush control first
- flush pending render second
- publish committed versions
- emit shutdown/reset best effort

Sketch:

```text
loop:
  wait for control/render/shutdown work
  flush durable control queue
  flush pending render candidate
  if render candidate fully flushed:
    publish committed version
```

---

## Commit flow

This is the threaded equivalent of the current single-threaded commit handoff.

### On stdout commit

When stdout thread fully flushes a render candidate:

- update `committed_render_version`
- publish latest commit notice

### On transport receipt

Transport thread consumes the latest commit notice and calls:

```zig
model.markCommittedThrough(version)
```

### On render receipt

Render thread consumes the same notice and calls:

```zig
render_actor.noteCommittedThrough(version)
```

This preserves the invariant that internal visual assumptions only advance on real stdout commit.

---

## Render policy in threaded mode

The current Part 1 refactor already introduced committed render semantics, but rendering is still effectively full-frame convergence. That is acceptable for the first threaded version.

### Recommended initial render behavior

- keep render candidates replaceable
- keep rendering full-frame if needed for correctness
- allow newer candidates to replace stale older ones
- prefer convergence over perfect intermediate history

Do **not** rush to reintroduce committed-frame diff rendering until the threaded runtime is stable.

### Intended later render behavior

The known long-term target remains:

- whole-frame render on resize / forced redraw / alt-screen discontinuity
- diff rendering otherwise
- any diffing must be based on committed frame state, not merely generated state

That restoration should be treated as a later step, not part of the first threaded runtime migration.

---

## Resize handling

Resize belongs to the transport thread.

On SIGWINCH:

1. wake transport thread
2. transport reads current size
3. applies size to PTY
4. applies size to `TerminalModel`
5. publishes model-changed notification

Render thread then generates the next appropriate candidate.

Stdout thread flushes it when ready.

---

## Shutdown protocol

Use one shared shutdown signal.

Suggested shape:

- atomic `shutdown_requested`
- wake all actors
- actors exit loops cleanly
- stdout thread attempts best-effort terminal reset / alt-screen exit
- join all threads

Important rule:

- terminal reset and alt-screen exit remain stdout-thread responsibilities

---

## Migration plan

### Phase 2A: local mailboxes and queues, still single-threaded

Before starting real threads:

- introduce the queue/mailbox types
- route communication through them
- keep execution in one thread temporarily

Purpose:

- validate message contracts
- validate durable vs latest-only semantics
- reduce threading risk

### Phase 2B: move `StdoutActor` to its own thread

This should be the first real thread.

Why:

- stdout already has clean single ownership
- easiest actor to isolate
- immediately removes stdout flush cost from transport loop

Expected payoff:

- PTY drainage becomes less sensitive to stdout pressure

### Phase 2C: move `RenderActor` to its own thread

This isolates snapshot/render generation from transport.

Expected payoff:

- large redraw storms stop directly stealing time from PTY drainage

### Phase 2D: synchronization tuning

After the 3-thread design works:

- minimize lock hold times
- consider snapshot-copy optimizations
- add extra instrumentation
- only then evaluate whether input also needs its own thread

---

## Thread startup order

Suggested startup:

1. create shared shutdown signal
2. create shared model wrapper
3. create stdout queues / mailboxes
4. create render mailboxes
5. start stdout thread
6. start render thread
7. start transport thread or run transport in main thread

Suggested shutdown:

1. set shutdown flag
2. wake all threads
3. join transport
4. join render
5. join stdout

---

## Instrumentation recommendations

Before or during Part 2, add cheap counters:

- stdin bytes read
- PTY bytes written
- PTY bytes read
- control bytes queued
- render candidates published
- render candidates replaced
- render candidates committed
- max stdout pending bytes
- max model version lag vs committed version

This will make it much easier to distinguish:

- true deadlock
- backlog growth
- render starvation
- stdout saturation
- PTY flow-control stalls

---

## Non-goals for Part 2

Do not do these yet:

- generic reusable actor runtime extraction
- fully general queue library for other apps
- committed-frame diff rendering redesign
- lock-free data structures unless profiling proves need
- 4+ thread decomposition without evidence

Keep Part 2 local and specific to `vpty`.

---

## Expected benefits

If implemented correctly, this design should eliminate the class of bugs where:

- render cost blocks PTY drainage
- stdout pressure blocks PTY transport
- large redraw storms stall the whole runtime
- committed render assumptions get ahead of actual stdout progress

It may not instantly make every large `nvim` paste smooth, but it should convert system-wide lockups into bounded lag or coalesced rendering, which is a much healthier failure mode.

---

## Decision rule for future changes

Use this rule when evaluating design changes:

- if a change lets PTY drainage depend on render or stdout progress, it is wrong
- if a change treats historical redraw bytes as durable state, it is wrong
- if a change advances visual assumptions before committed stdout progress, it is wrong

---

## Immediate next implementation recommendation

Do Part 2 in this order:

1. introduce thread-safe local mailboxes/queues
2. move stdout actor to its own thread
3. move render actor to its own thread
4. keep transport in main thread initially
5. stabilize and instrument
6. only then consider deeper optimizations
