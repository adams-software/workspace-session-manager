# ptyio streaming next steps

## Goal

Move `msr`, then `alt`, then `vpty` toward a shared stream-first PTY interaction model using `ptyio`, while keeping the scope tight and avoiding framework creep.

This document is intentionally execution-oriented.
It focuses on the next concrete steps rather than restating the full design rationale.

## Working rules

- keep the scope tight
- prefer small mechanical refactors over broad rewrites
- preserve application-specific behavior in each binary
- do not move app semantics into `ptyio`
- prefer conventions and discipline over hard abstraction contracts
- stop if a proposed shared abstraction starts to feel framework-like

## Migration order

1. `msr`
2. `alt`
3. `vpty`

Rationale:

- `msr` is already closest to the stream-first model
- `msr` is the best place to settle `ptyio` interfaces with the least guesswork
- `alt` is the next-best pressure test after `msr`
- `vpty` should come last because its rendering layer makes it the easiest place to accidentally overfit the shared design

## Phase 1: settle `ptyio` host + stream surface through `msr`

## Objectives

- settle the canonical `PtyChildHost` surface
- make PTY streaming work naturally with `fd_stream` + `ByteQueue`
- avoid further commitment to allocator-per-read PTY APIs as the primary hot path
- keep `msr` behavior stable while tightening the shared substrate

## Concrete tasks

### 1. settle canonical `PtyChildHost` naming

Make the host surface consistent and deliberate.

Target naming direction:

- `currentState()` or `state()`
- `masterFd()`
- `exitStatus()`
- `resize(...)`
- `signalWinch()`
- `terminate(...)`
- `refresh()`
- `wait()`
- `close()`

Immediate cleanup targets:

- replace transitional accessors like `hostState()` and `ptyFd()`
- update `msr` call sites to use the canonical naming
- remove compatibility naming once call sites are migrated

### 2. make PTY-fd streaming intentional

Expose PTY-fd access deliberately enough for stream integration.

What this means:

- `PtyChildHost` continues to own lifecycle
- `msr` uses the PTY fd with `fd_stream` and `ByteQueue`
- single-reader PTY output remains a documented convention

### 3. reduce dependence on allocator-returning PTY reads

Current allocator-returning PTY read helpers should not become the long-term hot path.

In `msr`, shift toward:

- PTY fd as the endpoint
- `fd_stream` / queue-based movement where practical
- small bounded pumping loops

The main question for this phase is not “can we delete every helper immediately?” but rather:

- can `msr` demonstrate the intended PTY streaming style cleanly enough to serve as the reference consumer?

### 4. document the settled `ptyio` conventions

Once the host surface is stable, update docs to make the conventions explicit:

- `PtyChildHost` owns lifecycle
- PTY stream movement may operate via PTY fd
- exactly one logical PTY output reader
- buffering lives above the host
- `ptyio` does not own app semantics

## Exit criteria for Phase 1

We are ready to move on from `msr` when:

- `PtyChildHost` naming is settled
- PTY-fd streaming is an intentional documented path
- `msr` is clean/building and remains stable
- the resulting `ptyio` surface still feels narrow and mechanical

## Phase 2: migrate `alt`

## Objectives

- replace `alt`’s current immediate passthrough shape with a stream-first shape
- keep hotkey/hook semantics local to `alt`
- use `msr`-validated `ptyio` patterns rather than inventing a separate model

## Concrete tasks

### 1. switch PTY lifecycle to `PtyChildHost`

Remove local PTY-child ownership logic from `alt` in favor of `PtyChildHost`.

This includes replacing local behavior derived from:

- `openpty`
- `fork`
- child PTY setup
- direct PTY lifecycle ownership

### 2. keep tty ownership local and thin

`alt` should keep a small local tty-owner abstraction if needed.

That layer should stay tiny and only cover things like:

- opening `/dev/tty`
- entering/restoring raw mode
- reading terminal size

Do not turn this into a broader abstraction unless a second consumer clearly needs it.

### 3. change input/output paths to stream-first movement

Target `alt` shape:

- tty input is treated as a stream
- PTY output is treated as a stream
- buffering is explicit
- writes are partial-write-safe
- hotkey interception happens before PTY enqueue

The hook behavior remains local policy:

- pause normal passthrough
- restore tty mode as needed
- enter alt screen
- run hook
- leave alt screen
- resume streaming loop

### 4. keep `alt` semantics unchanged where possible

Do not broaden scope during migration.

Preserve:

- existing hotkey behavior
- existing hook execution contract
- existing alternate-screen UX
- existing key debugging behavior

## Exit criteria for Phase 2

We are ready to move on from `alt` when:

- PTY lifecycle is using `PtyChildHost`
- stream movement is buffered/nonblocking rather than immediate passthrough
- hotkey/hook behavior still works
- the migration did not force app semantics into `ptyio`

## Phase 3: migrate `vpty`

## Objectives

- adopt the same stream-first PTY discipline
- keep renderer and terminal-state policy local
- avoid letting `vpty` push `ptyio` toward renderer/framework concerns

## Concrete tasks

### 1. switch PTY lifecycle to settled `PtyChildHost` surface

Use the already-settled `ptyio` host surface rather than introducing vpty-specific host needs into the public API.

### 2. make stdin -> PTY path stream-first

Replace direct immediate writes with queue-based/nonblocking movement where appropriate.

### 3. make PTY output consumption stream-first

Consume PTY output using the same settled streaming conventions, then feed bytes into:

- terminal state
- side effects
- rendering pipeline

### 4. keep render policy completely local

Do not move any of these into `ptyio`:

- damage tracking
- diff rendering
- alt-screen render policy
- side-effect/render scheduling

## Exit criteria for Phase 3

We are done when:

- `vpty` uses the shared stream-first PTY substrate
- renderer behavior remains local
- `ptyio` still looks like a substrate, not a framework

## Optional Phase 4: tiny shared stream helper layer

This phase is optional and should happen only if real duplication remains after `msr` and `alt` are in good shape.

## Candidate trigger for doing this

If, after the first two migrations, we still see repeated mechanical code for:

- queue read/write pumping
- bounded movement loops
- repeated poll-ready handling
- repeated EOF / would-block / closed handling

then we may add a tiny helper layer under `ptyio/src/stream/`.

## Guardrails

That helper layer must stay:

- mechanical
- queue-centric
- free of app semantics
- optional/composable rather than loop-owning

If it starts to feel like a PTY app framework, stop.

## Recommended immediate next actions

1. update the `ptyio` host surface to the chosen canonical naming
2. make PTY-fd streaming an explicit intentional path
3. adjust `msr` to be the reference consumer of that surface
4. confirm the docs still match reality
5. then begin the `alt` migration

## Definition of success

This effort succeeds if:

- `msr`, `alt`, and `vpty` converge on a stream-first PTY interaction model
- large-paste / bursty I/O correctness improves outside `msr`, not just inside it
- `ptyio` becomes a more useful shared substrate
- `ptyio` does **not** become a framework that the binaries have to fight
