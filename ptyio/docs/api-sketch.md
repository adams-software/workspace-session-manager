# ptyio API sketch

## Goal

Define the initial **public interface boundary** for `ptyio` before extraction work starts.

This is intentionally a sketch, not a full spec.
The purpose is to avoid winging the public API while moving code out of `msr`.

## Design principles

### 1. Keep the API mechanical

`ptyio` should expose the hard low-level PTY / TTY / fd operations.
It should not encode application intent.

Good:

- read bytes from PTY
- write bytes to fd
- resize PTY
- enter raw mode

Bad:

- attach semantics
- hook semantics
- rendering policy
- generic PTY app loop ownership

### 2. Caller owns policy

The library should make data movement and lifecycle reliable.
The caller decides:

- why bytes are moved
- when to flush
- what to do with output
- whether to intercept or transform data

### 3. Prefer explicit buffers and state

Do not hide queue ownership or event-loop policy unless there is a very strong reason.
The first version should bias toward explicit caller control.

---

# Proposed public surface

## `ByteQueue`

Purpose:

- explicit byte buffering for partial reads/writes
- bounded queue semantics for stream movement

### likely public API

```zig
pub const ByteQueue = struct {
    pub fn init(allocator: Allocator) ByteQueue;
    pub fn deinit(self: *ByteQueue) void;

    pub fn len(self: *const ByteQueue) usize;
    pub fn isEmpty(self: *const ByteQueue) bool;

    pub fn append(self: *ByteQueue, bytes: []const u8) !void;
    pub fn consume(self: *ByteQueue, n: usize) void;
    pub fn slice(self: *const ByteQueue) []const u8;
    pub fn clear(self: *ByteQueue) void;
};
```

### notes

- keep it small
- do not add application-specific semantics
- avoid building a complicated ring-buffer API unless it is clearly needed

---

## `FdStream`

Purpose:

- reliable nonblocking fd read/write helpers
- centralize partial write / `EINTR` / `EAGAIN` behavior

### likely public types

```zig
pub const ReadResult = union(enum) {
    bytes: usize,
    would_block,
    eof,
};

pub const WriteResult = union(enum) {
    bytes: usize,
    would_block,
};
```

### likely public API

```zig
pub fn readIntoQueue(fd: c_int, queue: *ByteQueue, max_bytes: usize) !ReadResult;
pub fn writeFromQueue(fd: c_int, queue: *ByteQueue, max_bytes: usize) !WriteResult;
```

### notes

- caller owns the `ByteQueue`
- helper just moves bytes reliably
- no event-loop ownership
- no PTY-specific logic here

### possible later additions

Only if clearly useful:

```zig
pub fn readChunk(fd: c_int, buf: []u8) !ReadResult;
pub fn writeSome(fd: c_int, bytes: []const u8) !WriteResult;
```

But initial version should stay minimal.

---

## `PtyChildHost`

Purpose:

- own a PTY-backed child process
- provide a **single-reader PTY output interface**
- provide PTY input, resize, signal, lifecycle refresh, and wait

This is the most important extracted abstraction.

## naming

Prefer a public name like:

- `PtyChildHost`
- or `PtyHost`

Avoid a vague public type name like just `Host`.

## likely public types

```zig
pub const ChildState = enum {
    starting,
    running,
    exited,
    closed,
};

pub const ExitStatus = union(enum) {
    code: u8,
    signal: u8,
};

pub const PtySize = struct {
    cols: u16,
    rows: u16,
};

pub const ReadChunkResult = union(enum) {
    bytes: usize,
    would_block,
    eof,
};
```

## likely public API

```zig
pub const PtyChildHost = struct {
    pub fn init(allocator: Allocator, config: Config) !PtyChildHost;
    pub fn deinit(self: *PtyChildHost) void;

    pub fn start(self: *PtyChildHost) !void;
    pub fn close(self: *PtyChildHost) !void;

    pub fn refresh(self: *PtyChildHost) !void;
    pub fn state(self: *const PtyChildHost) ChildState;
    pub fn exitStatus(self: *const PtyChildHost) ?ExitStatus;

    pub fn writeInput(self: *PtyChildHost, bytes: []const u8) !usize;
    pub fn readOutputChunk(self: *PtyChildHost, buf: []u8) !ReadChunkResult;

    pub fn resize(self: *PtyChildHost, size: PtySize) !void;
    pub fn terminate(self: *PtyChildHost, sig: Signal) !void;
    pub fn wait(self: *PtyChildHost) !ExitStatus;
};
```

## notes

### single-reader discipline

`readOutputChunk()` should assume there is exactly one reader of PTY output.
If later a consumer needs fanout, that should happen **outside** the host.

### caller-provided buffer

Prefer a caller-provided output buffer for `readOutputChunk()`.

Why:

- keeps allocator policy out of the hot path
- makes data flow more explicit
- better matches the intended narrowness of the package

### observed-output hook

Only extract an observed-output hook if it can remain very generic.
If it starts carrying replay / rendering assumptions, keep it app-local for now.

---

## `tty/raw_mode`

Purpose:

- minimal local terminal raw-mode helper
- no higher-level terminal ownership policy

## likely public API

```zig
pub const RawModeGuard = struct {
    pub fn restore(self: *RawModeGuard) void;
};

pub fn enterRawMode(fd: c_int) !RawModeGuard;
pub fn getTtySize(fd: c_int) !PtySize;
```

### optional small helpers

If clearly needed:

```zig
pub fn openControllingTty() !c_int;
```

But keep this layer tiny.

---

# What is intentionally missing

## No pump abstraction

There is no `RawPtyPump` public API in the initial sketch.

Reason:

- too opinionated too early
- event-loop shape differs subtly across `msr`, `alt`, and `vpty`
- likely to become framework-like very quickly

## No framed protocol helpers

`ptyio` does not own message framing or control protocols.

## No key parsing

`alt` keeps hotkey logic.

## No render scheduling

`vpty` keeps render and side-effect logic.

---

# Consumer expectations

## `msr`

Should use:

- `ByteQueue`
- `FdStream`
- `PtyChildHost`

Keeps:

- session semantics
- attach / detach / takeover
- bridge logic
- framed transport

## `alt`

Should use:

- `PtyChildHost`
- minimal tty helpers
- maybe `FdStream` / `ByteQueue` where useful

Keeps:

- hotkeys
- hook execution
- alt-screen control

## `vpty`

Should use:

- `PtyChildHost`
- minimal tty helpers
- maybe `FdStream`

Keeps:

- vterm integration
- renderer
- side effects
- redraw policy

---

# Open questions

## 1. Does `PtyChildHost.writeInput()` write directly or via queue?

Initial recommendation:

- direct write API at host boundary
- app can queue above it if needed

Reason:

- keeps host narrow
- avoids forcing one buffering policy on all consumers

## 2. Should `FdStream` expose queue-oriented helpers only, or also raw helpers?

Initial recommendation:

- queue-oriented helpers first
- raw helpers only if a real consumer needs them

## 3. Should `PtyChildHost` expose master fd directly?

Initial recommendation:

- no, not initially

Reason:

- easier to preserve single-reader discipline
- easier to keep lifecycle and I/O invariants local to the host abstraction

If later a consumer truly needs it, revisit deliberately.

---

# Recommended next step

Before moving files, use this sketch to do a tiny public API sanity check against:

- current `msr`
- current `alt`
- current `vpty`

Question to ask of each:

> Can this consumer get what it needs from these interfaces **without** pushing app policy into the library?

If yes, proceed with the narrow extraction.
If no, adjust the interface sketch first — not after code has already moved.
