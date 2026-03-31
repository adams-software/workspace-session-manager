# Session Host Terminal State Integration Guide

## Purpose

This document describes how to integrate a terminal state engine (for example, `libvterm`) into `SessionHost` so the host can:

* continuously reduce PTY output into a canonical screen model
* expose the current screen as a snapshot for attach / reattach
* optionally persist checkpoints for crash recovery
* keep terminal emulation server-side, with clients acting as renderers and input sources

This is written as an implementation guide for an engineer or coding agent. It is intentionally practical and biased toward the simplest robust design.

---

## Problem Statement

`SessionHost` already owns:

* process spawn
* PTY lifecycle
* resize
* termination / exit status
* PTY input and output streams

However, PTY output is only a byte stream. That is not sufficient for resumable attach by itself because many terminal programs are full-screen applications that continuously repaint using escape sequences.

If a client disconnects and later reconnects, the host needs a way to answer:

> What does the terminal screen look like **right now**?

That requires a terminal emulator / terminal state engine in the host.

The terminal state engine consumes PTY output bytes and maintains a virtual screen in memory. The host can then return a screen snapshot during attach / reattach without replaying the entire PTY history from the beginning.

---

## Design Goals

1. **Host owns terminal truth**

   * The host is authoritative for current screen state.
   * Clients do not need to emulate terminal state.

2. **Attach is cheap**

   * Reattach should return the current screen immediately.
   * Full byte replay from the start of session should not be required.

3. **Minimal moving parts**

   * PTY output is fed into exactly one terminal state engine per host.
   * The host exposes snapshots and optionally diffs.

4. **Keep public API simple**

   * Extend `SessionHost` only where necessary.
   * Encapsulate terminal emulation behind an internal interface.

5. **Crash recovery can be added incrementally**

   * In-memory snapshots are enough for detach / reattach while the host stays alive.
   * Durable checkpoints are optional and can be added later.

---

## Non-Goals

This integration is **not** trying to implement:

* a full terminal renderer in the host
* tmux-style pane/window management
* client-side emulation as the primary model
* historical visual replay as a requirement for attach
* a generalized logging architecture in this first step

Those can all exist later, but they are not required to add resumable terminal state to `SessionHost`.

---

## High-Level Architecture

```text
child process <-> PTY <-> SessionHost
                         |- PtyStream
                         |- TerminalStateEngine
                         |- current ScreenSnapshot
                         |- optional raw PTY log
                         |- exit/error lifecycle
```

Data flow:

1. child process writes output to PTY
2. `SessionHost` receives PTY bytes via `pty.onData`
3. host forwards those bytes to:

   * live stream subscribers, if any
   * optional raw log, if any
   * terminal state engine
4. terminal state engine updates in-memory screen state
5. host can return a full `ScreenSnapshot` at any time

This means attach / reattach is a read of host state, not a replay job.

---

## Core Decision

### Server-side emulation

This design assumes terminal emulation happens inside the host.

Why:

* one canonical screen state
* resumable attach is easy
* multiple clients can attach without each maintaining their own emulator state
* clients can be simple
* host remains authoritative

Alternative designs where the client owns emulation are possible, but they make reattach, multi-client attach, and canonical recovery significantly more complex.

---

## Recommended Integration Point

The terminal state engine should be integrated directly into `SessionHost` on the PTY output path.

The critical hook is:

```ts
pty.onData((chunk) => {
  term.feed(chunk)
})
```

This is the only required integration point for terminal output.

The other required hook is resize:

```ts
await pty.resize(cols, rows)
term.resize(cols, rows)
```

`SessionHost` is already the natural owner of both PTY output and resize, so this is the correct layer for the integration.

---

## Internal Abstraction

Do **not** make the rest of the host implementation depend directly on `libvterm` APIs.

Create a small internal abstraction for terminal state.

```ts
interface TerminalStateEngine {
  feed(data: Uint8Array): void
  resize(cols: number, rows: number): void
  snapshot(): ScreenSnapshot
  reset(): void
}
```

Recommended concrete implementation:

* `LibvtermEngine` for production
* `FakeTerminalStateEngine` for tests

This keeps the host implementation stable even if the terminal engine changes later.

---

## Public API Changes

The existing `SessionHost` API is already close to sufficient. Add screen-state access.

### Existing API

```ts
type ExitStatus = {
  code: number | null;
  signal: string | null;
};

type SpawnOptions = {
  argv: string[];
  cwd?: string;
  env?: Record<string, string>;
  cols?: number;
  rows?: number;
};

interface PtyStream {
  write(data: Uint8Array): Promise<void>;
  onData(cb: (data: Uint8Array) => void): () => void;
  onClose(cb: () => void): () => void;
}

type SessionHostOptions = {
  spawn: SpawnOptions;
};

interface SessionHost {
  readonly pty: PtyStream;

  start(): Promise<void>;
  resize(cols: number, rows: number): Promise<void>;
  terminate(signal?: string): Promise<void>;
  wait(): Promise<ExitStatus>;
  close(): Promise<void>;

  getState(): HostState;
  getExitStatus(): ExitStatus | null;

  onExit(cb: (status: ExitStatus) => void): () => void;
  onError(cb: (error: Error) => void): () => void;
}
```

### Proposed additions

```ts
type ScreenCell = {
  text: string;
  fg?: number;
  bg?: number;
  bold?: boolean;
  italic?: boolean;
  underline?: boolean;
  inverse?: boolean;
  strike?: boolean;
};

type ScreenSnapshot = {
  rows: number;
  cols: number;
  cursorRow: number;
  cursorCol: number;
  cursorVisible: boolean;
  altScreen: boolean;
  title?: string;
  seq: number;
  cells: ScreenCell[][];
};

interface SessionHost {
  readonly pty: PtyStream;

  start(): Promise<void>;
  resize(cols: number, rows: number): Promise<void>;
  terminate(signal?: string): Promise<void>;
  wait(): Promise<ExitStatus>;
  close(): Promise<void>;

  getState(): HostState;
  getExitStatus(): ExitStatus | null;

  getScreenSnapshot(): ScreenSnapshot;
  getScreenSeq(): number;

  onScreenUpdate(cb: (seq: number) => void): () => void;
  onExit(cb: (status: ExitStatus) => void): () => void;
  onError(cb: (error: Error) => void): () => void;
}
```

### Notes

* `getScreenSnapshot()` returns the current canonical screen state.
* `seq` is a monotonic host-local sequence number for screen updates.
* `onScreenUpdate()` notifies outer layers that the screen changed.
* The outer session layer can use `seq` to decide whether to request a fresh snapshot or incremental data.

---

## Snapshot Model

A usable terminal snapshot is more than text.

At minimum capture:

* rows
* cols
* per-cell text
* per-cell style attributes
* cursor row / col
* cursor visibility
* whether alternate screen is active
* optional terminal title
* sequence number of the last applied PTY chunk

Why each matters:

* **rows / cols**: required for rendering and correct client sizing
* **cells**: visible screen contents
* **cursor state**: necessary for correct display and UX
* **alt screen**: full-screen apps often render here; attach needs to know which buffer is active
* **title**: optional, but useful if the host surfaces terminal title elsewhere
* **seq**: allows attach / reattach to synchronize with subsequent updates

### Cell representation

Keep the first version plain and explicit.

```ts
type ScreenCell = {
  text: string;
  fg?: number;
  bg?: number;
  bold?: boolean;
  italic?: boolean;
  underline?: boolean;
  inverse?: boolean;
  strike?: boolean;
}
```

Do not over-optimize the serialization format early. A straightforward representation is easier to debug and verify.

---

## Host Behavior

### Host startup

On `start()`:

1. spawn the child process attached to a PTY
2. create the terminal state engine using initial `cols` and `rows`
3. subscribe to PTY output
4. feed PTY output into terminal state engine
5. increment `seq` when the screen changes
6. emit `onScreenUpdate(seq)` notifications

Pseudo-flow:

```ts
async function start() {
  spawnChildAndPty()
  term = createTerminalStateEngine(cols, rows)

  unsubData = pty.onData((chunk) => {
    rawSeq += 1

    // optional: append to raw durable log
    // rawLog.append(rawSeq, chunk)

    term.feed(chunk)
    screenSeq += 1
    emitScreenUpdate(screenSeq)
  })

  unsubClose = pty.onClose(() => {
    // finalize state if needed
  })
}
```

### Resize

On `resize(cols, rows)`:

1. resize PTY
2. resize terminal state engine
3. increment screen sequence
4. emit screen update

Pseudo-flow:

```ts
async function resize(cols: number, rows: number) {
  await pty.resize(cols, rows)
  term.resize(cols, rows)
  screenSeq += 1
  emitScreenUpdate(screenSeq)
}
```

### Attach / Reattach

Attach should not talk directly to the PTY.

Instead:

1. request `snapshot = host.getScreenSnapshot()`
2. request `seq = host.getScreenSeq()`
3. subscribe to updates after `seq`

Attach response shape at outer layer might look like:

```ts
{
  snapshot,
  seq,
  exitStatus: host.getExitStatus(),
}
```

This is enough to draw the current terminal immediately and then transition to live updates.

---

## Recommended Update Strategy

There are three possible update strategies after attach:

1. **full snapshot only**
2. **snapshot + row diffs**
3. **snapshot + raw PTY bytes**

Recommended implementation order:

### Phase 1: full snapshot on attach, raw bytes live

Simplest viable path:

* attach returns full snapshot
* live session still forwards PTY bytes to clients
* clients render snapshot initially, then update via existing stream path or a later diff mechanism

### Phase 2: add dirty tracking and row diffs

When the terminal engine reports screen damage, track dirty rows or damaged rectangles.

Then emit events like:

```ts
type ScreenRowsPatch = {
  seq: number;
  rows: Array<{
    row: number;
    cells: ScreenCell[];
  }>;
}
```

This is the sweet spot for efficient host-driven screen sync.

### Phase 3: periodic durable checkpoints

Persist snapshots and an associated PTY offset or host sequence number.

This enables bounded recovery after host restart.

---

## Durable vs In-Memory State

This integration should distinguish two recovery levels.

### Level 1: in-memory snapshot only

Enough for:

* detach / reattach while host stays alive
* current screen recovery after temporary disconnect

Not enough for:

* host crash recovery
* process supervisor restart recovery

### Level 2: durable checkpoints

Persist:

* full screen snapshot
* last applied PTY log offset or screen sequence
* optional raw PTY log tail

Enough for:

* host restart recovery
* bounded replay time
* crash recovery from recent checkpoint

Recommendation:

Implement Level 1 first. Leave clear hooks for Level 2.

---

## Suggested Internal Types

These are implementation-oriented and do not all need to be public.

```ts
type ScreenCell = {
  text: string
  fg?: number
  bg?: number
  bold?: boolean
  italic?: boolean
  underline?: boolean
  inverse?: boolean
  strike?: boolean
}

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

type HostRuntimeState = {
  started: boolean
  closed: boolean
  exited: boolean
  exitStatus: ExitStatus | null
  screenSeq: number
}

interface TerminalStateEngine {
  feed(data: Uint8Array): void
  resize(cols: number, rows: number): void
  snapshot(): ScreenSnapshot
  reset(): void
}
```

---

## Suggested Internal Host Structure

```ts
class SessionHostImpl implements SessionHost {
  readonly pty: PtyStream

  private readonly term: TerminalStateEngine
  private screenSeq: number = 0
  private exitStatus: ExitStatus | null = null

  private unsubData?: () => void
  private unsubClose?: () => void

  // event listeners
  private screenListeners = new Set<(seq: number) => void>()
  private exitListeners = new Set<(status: ExitStatus) => void>()
  private errorListeners = new Set<(error: Error) => void>()
}
```

Important implementation note:

* `getScreenSnapshot()` should return a safe snapshot copy or an immutable view.
* Do not expose live mutable internal buffers to callers.

---

## Why Use an Internal Adapter for libvterm

Do not spread `libvterm` usage throughout the host.

Keep all direct terminal-emulator interaction inside a single adapter module.

Example conceptual structure:

```text
src/
  host/
    session_host.zig
    terminal_state_engine.zig
    libvterm_engine.zig
```

Responsibilities:

* `terminal_state_engine.zig`

  * defines the host-facing interface / contract
* `libvterm_engine.zig`

  * owns FFI bindings and all `libvterm` specifics
* `session_host.zig`

  * depends only on terminal-state abstraction

Benefits:

* easier testing
* easier replacement
* better separation of concerns
* host lifecycle code remains simple

---

## Zig Integration Notes

Implementation is in Zig, but the architectural shape remains the same.

Recommended approach:

* vendor `libvterm` source or pin a version
* compile and statically link it as part of the Zig build
* wrap the small subset of APIs needed for:

  * create / destroy terminal
  * feed bytes
  * resize
  * inspect screen state or receive callbacks
* expose a small Zig-native adapter to the rest of the host

Do **not** require `libvterm` to be separately installed on the user’s system.

This should be treated as a native dependency of the host runtime, not as an external runtime prerequisite.

---

## Recommended Zig-Side Shape

Conceptually, mirror the same abstraction in Zig.

```zig
pub const ScreenCell = struct {
    text: []const u8,
    fg: ?u32 = null,
    bg: ?u32 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strike: bool = false,
};

pub const ScreenSnapshot = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    alt_screen: bool,
    title: ?[]const u8,
    seq: u64,
    cells: [][]ScreenCell,
};

pub const TerminalStateEngine = struct {
    pub fn feed(self: *TerminalStateEngine, data: []const u8) void {}
    pub fn resize(self: *TerminalStateEngine, cols: u16, rows: u16) void {}
    pub fn snapshot(self: *TerminalStateEngine, allocator: Allocator) !ScreenSnapshot {}
    pub fn deinit(self: *TerminalStateEngine) void {}
};
```

Actual Zig implementation can use concrete types rather than dynamic dispatch if preferred.

The key is architectural separation, not a specific Zig polymorphism style.

---

## State Ownership Rules

These rules should be preserved in implementation.

1. **PTY bytes are the source stream**

   * Only PTY output mutates terminal screen state.

2. **Terminal engine is a reducer**

   * It derives current screen state from PTY bytes and resize events.

3. **Host owns the current snapshot**

   * Clients never become the source of truth.

4. **Attach reads host state**

   * Attach is a snapshot operation, not a replay protocol.

5. **Input flows separately**

   * Client keyboard/input bytes still go to `pty.write()`.
   * Client input should not directly mutate snapshot state.

---

## Handling Alternate Screen

This is important enough to call out explicitly.

Many interactive programs use the alternate screen buffer, including editors, pagers, and TUIs.

Requirements:

* track whether alternate screen is active
* ensure `getScreenSnapshot()` reflects the active visible buffer
* if the terminal engine distinguishes primary vs alternate screen, the snapshot must represent what the user would currently see

Do not treat terminal state as a single plain text log. That will break resume for full-screen applications.

---

## Error Handling Guidance

Terminal emulation should be treated as part of host internals.

Guidelines:

* PTY failures remain host errors
* terminal-engine internal failures should surface via `onError`
* if terminal-state update fails unexpectedly, prefer preserving PTY/process lifecycle over crashing immediately if possible
* if the terminal engine becomes unusable, future attach should fail clearly rather than returning nonsense state

Recommended posture:

* fail clearly
* do not silently degrade to incorrect screen state

---

## Concurrency / Ordering Guidance

Ordering matters.

Rules:

* PTY output chunks must be fed to the terminal engine in the exact order received
* screen sequence increments must follow that same order
* resize operations must be serialized relative to PTY output handling

A simple single-threaded event loop or serialized host executor is preferable to complicated locking.

This subsystem benefits from strict ordering much more than from parallelism.

---

## Testing Strategy

Testing should be layered.

### 1. Unit tests for terminal engine adapter

Feed known byte sequences and verify snapshots.

Examples:

* plain text output
* newline handling
* cursor movement
* clear screen
* color/style changes
* alternate screen entry/exit
* resize

### 2. Host integration tests

Run a real PTY-backed child and verify:

* output updates snapshot
* attach returns current screen
* resize updates snapshot dimensions
* exit state and screen state remain coherent

### 3. Reattach tests

Simulate:

1. start host
2. run shell command or TUI action
3. disconnect client
4. call `getScreenSnapshot()` later
5. verify screen matches expected visible state

### 4. Durable checkpoint tests later

If/when checkpointing is added:

* persist snapshot + offset
* restore host state from checkpoint
* replay tail if needed
* verify final visible screen

---

## Suggested Implementation Plan

### Phase 1 — in-memory snapshots only

* add `TerminalStateEngine`
* implement `LibvtermEngine`
* add `getScreenSnapshot()` and `getScreenSeq()`
* feed PTY output into terminal engine
* update terminal engine on resize
* expose `onScreenUpdate()`

Outcome:

* resumable attach while host remains alive

### Phase 2 — dirty rows / patches

* track screen damage
* emit row diffs or damage patches
* reduce bandwidth for live clients

Outcome:

* efficient live sync

### Phase 3 — durable checkpoints

* persist snapshots with associated sequence / offset
* restore from latest checkpoint on restart
* optionally replay PTY tail after checkpoint

Outcome:

* bounded crash recovery

---

## Advice for the Implementer / Agent

1. **Keep the first version simple**

   * full snapshot on attach
   * no fancy compression
   * no clever diff format yet

2. **Do not over-couple host to libvterm**

   * create a small adapter
   * keep all FFI isolated

3. **Prefer correctness over optimization**

   * terminal state bugs are user-visible and painful
   * a slightly heavier snapshot is acceptable initially

4. **Treat attach as state read, not replay**

   * this is the central design principle

5. **Preserve strict event ordering**

   * PTY output and resize must be applied in order

6. **Design for alternate screen from day one**

   * this is not optional if editors / TUIs matter

7. **Leave hooks for durability, but do not block on it**

   * in-memory snapshot is already a major usability improvement

---

## Minimal Acceptance Criteria

The integration is successful when all of the following are true:

1. a shell or full-screen TUI can run under `SessionHost`
2. PTY output continuously updates host-maintained terminal state
3. `getScreenSnapshot()` returns the current visible screen
4. after temporary client disconnect, reattach can redraw current screen from host snapshot
5. `resize()` correctly updates both PTY and snapshot dimensions
6. terminal state remains coherent until process exit or host close

---

## Summary

The simplest robust solution is:

* embed a terminal state engine inside `SessionHost`
* feed PTY output into it continuously
* keep an in-memory canonical screen snapshot
* return that snapshot on attach / reattach
* keep clients as renderers/input sources, not terminal authorities

This puts terminal truth where it belongs: next to the PTY and process lifecycle.

That is the right foundation for resumable terminal sessions, and it can later be extended with diffs, durable checkpoints, and richer replay without changing the core model.

