# ptyflow extraction plan

## Goal

Extract the shared PTY streaming logic that now exists in improved form inside `msr2`, then adapt the other PTY-based binaries to use that same substrate.

The point is not to create a “session manager package.” The point is to create a **generic PTY streaming package** that can support:

- local PTY passthrough apps
- PTY passthrough apps with renderers / side-effect processing
- PTY-over-transport apps like `msr2`

This shared package should own the hard parts that keep recurring:

- nonblocking fd reads/writes
- explicit buffering and backpressure
- single-reader PTY handling
- terminal raw-mode helpers
- reusable pump patterns

## Proposed package name

**`ptyflow`**

Why this name:

- generic enough to cover all three current binaries
- describes the real abstraction: PTY data flow / stream flow
- does not overfit to sessions, rendering, or hooks
- can later support local PTY passthrough, remoting, rendering, and tooling

Other acceptable names if we want alternatives:

- `ptykit`
- `ptycore`
- `termflow`

But `ptyflow` is the best fit right now.

## Non-goals

`ptyflow` should **not** initially own:

- session semantics
- owner / attach / detach control logic
- frame protocol specifics
- vterm rendering policy
- alt-screen hook UX
- OSC52 forwarding policy

Those are application-level concerns.

## What should be extracted

### 1. Stream primitives

Shared low-level pieces:

- `byte_queue`
- nonblocking fd helpers
- bounded read/write operations
- small transport/pump conventions

These are already being proven in the newer `msr2` path.

### 2. PTY host core

A generic PTY child host should provide:

- spawn child attached to PTY
- resize PTY / propagate window size
- terminate child
- wait / refresh lifecycle state
- **single-reader PTY output API**
- optional observed-output hook for replay / terminal-state / rendering layers

This is essentially the generalized direction of `host2`.

### 3. Terminal helpers

Shared helpers for local terminal interaction:

- open / manage tty
- enter raw mode
- restore termios
- current window size
- possibly signal/wake-pipe helpers

This is currently duplicated conceptually between `alt` and `vpty`.

### 4. Generic PTY pump pattern

A reusable raw PTY pump should support:

- local input source -> PTY input queue
- PTY output -> local output queue
- optional interception on input
- optional fanout / processors on PTY output
- bounded per-tick work budgets

This should not be a giant framework. It should just standardize the robust event-loop shape.

## What should remain app-specific

### msr2

Keep in app layer:

- session control semantics
- framed protocol
- attach / detach / takeover / owner-ready logic
- nested forwarding behavior

`msr2` should use `ptyflow` underneath, not disappear into it.

### alt

Keep in app layer:

- hotkey parsing
- hook execution
- alt-screen entry/exit
- hook error UX
- any special passthrough suspension/resume behavior

### vpty

Keep in app layer:

- vterm adapter
- renderer
- side-effect policy
- render scheduling
- snapshot/diff behavior

## Proposed package structure

```text
packages/
  ptyflow/
    build.zig
    src/
      root.zig

      stream/
        byte_queue.zig
        fd_stream.zig

      tty/
        terminal_mode.zig
        resize_signal.zig

      pty/
        host.zig
        child_session.zig

      pump/
        raw_pty_pump.zig
        pump_types.zig

      adapters/
        framed_transport.zig        # optional, used by msr2
        message_codec.zig           # optional, used by msr2

      tests/
        stream_test.zig
        host_test.zig
        raw_pty_pump_test.zig
````

## Module boundary strategy

### `stream/*`

Purpose:

* generic nonblocking byte movement

Contents:

* byte queue
* read-into-queue
* write-from-queue
* maybe fd readiness helpers

No PTY-specific behavior here.

### `tty/*`

Purpose:

* local terminal helpers

Contents:

* raw mode enter/restore
* tty open/init
* current size
* maybe SIGWINCH + wake-pipe helper

No PTY child logic here.

### `pty/*`

Purpose:

* child process and PTY ownership

Contents:

* spawn child under PTY
* resize PTY
* signal child
* wait / refresh state
* chunked PTY read/write APIs
* optional observed PTY output support

This is the most important reusable layer.

### `pump/*`

Purpose:

* reusable event-loop / shuttling logic

Contents:

* bounded tick model
* stdin/pty/stdout style shuttling
* interception hooks
* output processors
* explicit per-direction buffers

This is what `alt` and `vpty` should sit on most directly.

### `adapters/*`

Purpose:

* optional higher-level protocol glue

Initially:

* `msr2` framed transport can either remain local to `msr2` or move here later
* do not force this extraction too early

## Migration strategy

Do this in stages. Do not try to fully generalize everything up front.

### Stage 1: extract the proven low-level pieces

Move into `ptyflow` first:

* `byte_queue`
* `fd_stream`
* terminal raw-mode helper(s)
* the generalized PTY host from `host2`

Outcome:

* `msr2` continues to work, but now depends on `ptyflow` for the base substrate
* no behavior change intended

### Stage 2: adapt `alt`

`alt` is the best next consumer because it is simpler than `vpty`.

Current `alt` shape still has the old pattern:

* direct read/write
* synchronous `writeAll`
* loop-until-AGAIN PTY draining
* no explicit output queue model

Refactor `alt` to use `ptyflow`:

* terminal mode from `ptyflow/tty`
* PTY child host from `ptyflow/pty`
* raw pump pattern from `ptyflow/pump`
* keep hotkey interception and hook execution local to `alt`

Outcome:

* `alt` becomes the proving ground for the generic local PTY passthrough abstraction

### Stage 3: adapt `vpty`

Refactor `vpty` to use the same `ptyflow` substrate:

* terminal mode from `ptyflow/tty`
* PTY child host from `ptyflow/pty`
* pump loop from `ptyflow/pump`
* keep renderer / side effects / vterm local to `vpty`

Recommended design:

* PTY output chunk
  -> side effect processor
  -> vterm feed
  -> render request
* no more monopolizing “read until empty then render” loop shape

Outcome:

* `vpty` gets the same robustness improvements as `msr2`

### Stage 4: clean up `msr2`

Once `ptyflow` is stable:

* make `msr2` depend on `ptyflow` for stream and PTY substrate
* keep session protocol / control logic in `msr2`
* decide later whether framed transport pieces belong in `ptyflow/adapters` or stay inside `msr2`

Outcome:

* `msr2` becomes thinner and more obviously layered

## Recommended repo layout after migration

```text
packages/
  ptyflow/

apps/
  msr/
  vpty/
  alt/

shared/
  # ideally shrinks over time, or disappears for PTY-related logic
```

If current repo structure should stay flatter, that is fine too:

```text
packages/ptyflow/
msr/
vpty/
alt/
```

The important part is that PTY flow logic is not trapped under `shared/` with vague ownership. It should have its own package boundary.

## Import strategy

Each app should import `ptyflow` as a package/module dependency, not copy files around.

Examples:

* `@import("ptyflow").stream.byte_queue`
* `@import("ptyflow").pty.host`
* `@import("ptyflow").tty.terminal_mode`

Or if Zig module structure wants flatter exports:

* `@import("ptyflow").ByteQueue`
* `@import("ptyflow").FdStream`
* `@import("ptyflow").SessionHost`

I recommend exposing a tidy `root.zig` with curated re-exports, while still keeping internal file structure organized.

## Suggested `root.zig`

`root.zig` should re-export the important public entrypoints:

* stream primitives
* terminal mode
* PTY host
* raw PTY pump types

Do not over-export every internal helper.

## Execution plan

### Phase A: package skeleton

1. Create `packages/ptyflow/`
2. Add `build.zig`
3. Add `src/root.zig`
4. Move/copy in:

   * `byte_queue`
   * `fd_stream`
   * terminal helper
   * `host2` as initial `ptyflow` PTY host
5. Get package tests building

### Phase B: switch `msr2` to package imports

1. Replace local imports of:

   * `byte_queue`
   * `fd_stream`
   * `host2`
2. Keep behavior identical
3. Run:

   * `test-host2` equivalent package tests
   * `test-session-server2`
   * `test-client2-integration`
   * `test-v2`

### Phase C: refactor `alt`

1. Extract `TerminalState`-like behavior into `ptyflow/tty`
2. Replace `ChildSession` with `ptyflow` PTY host
3. Replace direct passthrough loop with buffered pump model
4. Keep hotkey and hook logic inside `alt`
5. Add or update tests / smoke scripts

### Phase D: refactor `vpty`

1. Replace local terminal/PTY loop with `ptyflow` pieces
2. Keep renderer and side-effect code local
3. Make rendering driven by chunked PTY reads and explicit scheduling
4. Test resize, exit, and visual correctness

### Phase E: optional cleanup

1. Decide whether old shared PTY code can be removed
2. Decide whether framed transport helpers belong in `ptyflow`
3. Shrink `shared/` or eliminate PTY-related logic from it

## Testing strategy

### Package-level tests

`ptyflow` should have its own tests for:

* byte queue behavior
* nonblocking fd read/write helpers
* PTY spawn / wait / resize
* chunked PTY read behavior
* raw pump no-deadlock behavior

### App-level tests

Each app still needs app-specific integration tests:

* `msr2`: attach/detach/routed attach/routed detach/large paste
* `alt`: hotkey interception / hook / resume passthrough
* `vpty`: resize / redraw / exit cleanup / side effects

### Manual tests

Keep manual tests for:

* nvim large paste in `msr2`
* hook invocation in `alt`
* real TUI rendering in `vpty`

These are still worth keeping even with better automation.

## Risks and how to avoid them

### Risk: extracting too much too early

Mitigation:

* only extract the low-level PTY flow pieces first
* keep session/render/hook policy local

### Risk: package becomes vague “misc shared”

Mitigation:

* keep `ptyflow` narrowly about PTY and stream flow
* refuse unrelated helpers

### Risk: `msr2` protocol shapes pollute the package

Mitigation:

* keep framed transport as optional adapter layer
* do not let session semantics leak into core PTY types

### Risk: breaking all binaries at once

Mitigation:

* migrate one app at a time
* `msr2` first for dependency switch only
* `alt` next as proving ground
* `vpty` after that

## Immediate next step

Create the initial `packages/ptyflow/` skeleton and move in:

* `byte_queue`
* `fd_stream`
* `host2` (renamed to package PTY host)
* terminal helper abstraction

Then update `msr2` imports to use that package with no intended behavior change.

That gets the package boundary in place before larger refactors begin.


