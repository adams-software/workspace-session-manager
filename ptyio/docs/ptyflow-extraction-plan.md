# ptyio extraction plan

## Goal

Extract only the **narrow PTY/TTY I/O substrate** that is now proven inside the newer `msr` path, then let `msr`, `alt`, and later `vpty` reuse that substrate.

The point is **not** to create a PTY app framework.
The point is to create a **small, boring, reliable library** for the parts that are easy to get wrong and are already duplicated:

- PTY child lifecycle
- nonblocking fd reads/writes
- explicit byte buffering
- single-reader PTY discipline
- minimal local tty/raw-mode helpers

This package should stay intentionally small and mechanical.

## Proposed package name

**`ptyio`**

Why this name:

- narrower than `ptyflow`
- describes the real abstraction: PTY + TTY + fd I/O mechanics
- does not imply a framework or end-to-end orchestration layer
- fits the actual intended scope better than a broader name

## Non-goals

`ptyio` should **not** own:

- session semantics
- attach / detach / takeover policy
- frame protocol specifics
- renderer or vterm policy
- alt-screen hook UX
- keybinding / hotkey parsing
- generic PTY pump frameworks
- output fanout policy
- signal / wake orchestration unless a tiny helper is clearly required by multiple consumers

Rule of thumb:

> If the code needs to know **why** bytes are being moved, it probably does **not** belong in `ptyio`.

`ptyio` should own **data movement and PTY lifecycle**, not application intent.

## What should be extracted

### 1. Stream primitives

Shared low-level pieces:

- `byte_queue`
- `fd_stream`
- bounded read / write helpers
- partial write handling
- retry-on-`EINTR` / retry-on-`EAGAIN` behavior

This layer should be generic fd/byte movement, not PTY-specific policy.

### 2. PTY child host

A generic PTY child host should provide:

- spawn child attached to PTY
- resize PTY / propagate window size
- terminate child
- wait / refresh lifecycle state
- **single-reader PTY output API**
- PTY input write API
- optional observed-output hook only if it stays generic enough to avoid app policy leakage

This is the most valuable shared layer.

Prefer a narrow public concept like:

- `PtyChildHost`
- or `PtyHost`

rather than a vague name like `Host`.

### 3. Minimal tty helpers

Shared local terminal helpers should stay tiny:

- open tty if needed
- raw mode enter / restore
- winsize read
- maybe winsize apply helper if it stays generic

Do **not** extract more until multiple consumers clearly need it.

## What should remain app-specific

### msr

Keep in app layer:

- session control semantics
- attach / detach / takeover / owner-ready logic
- framed protocol
- nested forwarding behavior
- attachment bridge semantics

`msr` should depend on `ptyio` underneath, not disappear into it.

### alt

Keep in app layer:

- hotkey parsing
- hook execution
- alt-screen entry/exit
- hook error UX
- any attach/resume semantics specific to `alt`

### vpty

Keep in app layer:

- vterm adapter
- renderer
- side-effect policy
- render scheduling
- snapshot/diff behavior

`vpty` should reuse the substrate, not force renderer concerns into it.

## What should NOT be extracted yet

### 1. Generic pump abstraction

Do **not** extract a `pump/*` framework initially.

Why:

- this is where opinion sneaks in fastest
- different apps want subtly different loop ownership and policy
- it is too easy to accidentally build a framework instead of a substrate

If later two consumers converge naturally on the same pump shape, revisit it then.
Not now.

### 2. Protocol adapters

Do **not** move framed transport / message codec logic into `ptyio` initially.

That is application-level protocol glue, not PTY substrate.
If later it proves reusable, it can move into an adapter layer — but only after real duplication exists.

### 3. Render / side-effect coordination

Anything renderer-related stays out.
Full stop.

## Proposed package structure

```text
ptyio/
  build.zig
  src/
    root.zig

    stream/
      byte_queue.zig
      fd_stream.zig

    tty/
      raw_mode.zig
      tty_size.zig

    pty/
      child_host.zig
```

That is intentionally small.

No `pump/`.
No `adapters/` yet.
No rendering.
No protocol.

## Public API strategy

Expose only the curated public pieces from `root.zig`.

Likely exports:

- `ByteQueue`
- `FdStream`
- `PtyChildHost`
- `RawModeGuard` or equivalent tiny raw-mode helper
- `getTtySize` or equivalent small winsize helper

Do not over-export internals.

## Migration strategy

Do this in stages. Keep the first extraction intentionally boring.

### Stage 1: extract proven low-level pieces

Move into `ptyio` first:

- `byte_queue`
- `fd_stream`
- minimal tty helper(s)
- `host2`-derived PTY child host, renamed to a cleaner public PTY-host concept

Outcome:

- current `msr` continues to work
- behavior should not change
- `ptyio` proves it can hold the substrate cleanly

### Stage 2: switch current `msr` to `ptyio`

Update `msr` imports to use `ptyio` for:

- buffering
- fd streaming helpers
- PTY child lifecycle

Keep all session semantics local.

Outcome:

- current `msr` becomes the first real consumer of the extracted substrate
- this validates the package without broadening scope prematurely

### Stage 3: adapt `alt`

Refactor `alt` to use:

- `ptyio` PTY child host
- `ptyio` tty helpers
- maybe `ptyio` stream helpers directly where useful

Keep hotkey and hook logic local to `alt`.

Outcome:

- `alt` becomes the second real consumer
- proves the substrate works for local passthrough use, not just `msr`

### Stage 4: evaluate `vpty`

Only after `msr` and `alt` are stable on `ptyio` should `vpty` be migrated.

Use `ptyio` only for:

- PTY child host
- fd/queue helpers
- tty/raw helpers

Keep rendering and side effects local.

Outcome:

- `vpty` benefits from the same low-level robustness
- `ptyio` still remains narrow

## Recommended repo layout after migration

```text
msr/
vpty/
alt/
ptyio/
shared/
```

Longer term, PTY-related logic should migrate toward `ptyio`, not remain split between `shared/` and app-local files.

## Testing strategy

### Package-level tests

`ptyio` should have its own tests for:

- byte queue behavior
- nonblocking fd read/write helpers
- PTY child spawn / wait / resize
- chunked PTY read behavior

Keep tests low-level and mechanical.

### App-level tests

Each app still owns its own semantics:

- `msr`: attach/detach/routed attach/routed detach/large paste
- `alt`: hotkey interception / hook / resume passthrough
- `vpty`: resize / redraw / exit cleanup / rendering behavior

## Risks and how to avoid them

### Risk: extracting too much too early

Mitigation:

- only extract the low-level PTY/TTY/fd pieces first
- no pump layer
- no protocol layer
- no render layer

### Risk: `ptyio` becomes another vague shared junk drawer

Mitigation:

- keep `ptyio` strictly about PTY/TTY/fd mechanics
- reject anything that needs application intent to make sense

### Risk: `vpty` pushes the package toward renderer concerns

Mitigation:

- do not let `vpty` drive the first extraction boundary
- migrate `alt` before `vpty`

## Immediate next step

Create the initial `ptyio/` skeleton and extract only:

- `byte_queue`
- `fd_stream`
- minimal tty helpers
- PTY child host

Then switch current `msr` to use those imports with no intended behavior change.

That establishes the package boundary while keeping the scope narrow and safe.
