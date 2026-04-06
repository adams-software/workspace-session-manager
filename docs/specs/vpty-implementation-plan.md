# VPty Phase 1 Implementation Plan

## Goal

Build `vpty` as a small foreground terminal frontend that:

- launches a child behind an inner PTY
- places the outer terminal into raw mode when interactive
- forwards stdin to the child PTY
- feeds child PTY output into libvterm
- renders libvterm screen state to outer stdout
- propagates resize to both the child PTY and libvterm
- exits with stable child-exit semantics

This plan assumes the updated `docs/specs/vpty-spec.md` is the product contract.

---

## Product boundary

### VPty owns

- child process launch on inner PTY
- outer terminal raw-mode lifecycle
- event loop over stdin + PTY + resize
- libvterm ingestion and screen-state ownership
- rendering terminal state to stdout
- wrapper exit semantics

### VPty does not own

- persistence
- detach / reattach
- replay
- session protocols
- remote viewing
- byte-for-byte passthrough fidelity

### msr/wsm relationship

`msr` and `wsm` should not absorb vterm internals.

If later desired, they may:
- launch `vpty -- <cmd>`
- treat `vpty` as a normal PTY-hosted child

But `vpty` should remain standalone and usable without session machinery.

---

## Reuse strategy

The app should stay small, but we should reuse working pieces rather than rewrite blindly.

## Reuse candidates from current repo

### 1. `src/terminal_state_vterm.zig`

**Keep and adapt.**

This is already close to the right role for VPty:
- owns libvterm handle
- feeds bytes
- resizes emulator
- snapshots screen state

### 2. `src/vterm_shim.c` / `src/vterm_shim.h`

**Keep and adapt.**

The C shim already exposes:
- create/free
- feed
- resize
- screen/cursor access
- cell style/color access

This is useful and should stay narrow.

### 3. pieces of `src/host.zig`

**Partially reuse.**

Likely reusable:
- `forkpty()`-based child spawn structure
- PTY read/write helpers
- `TIOCSWINSZ` resize application
- wait/exit handling patterns
- signal/waitpid handling shape

Not reusable as-is if it drags session concepts or terminal-state concepts with it. The reused portion should become a small `vpty`-specific PTY/process module.

### 4. raw terminal handling patterns from `attach_runtime.zig`

**Partially reuse.**

Likely reusable:
- outer tty raw mode setup/restore
- poll loop structure
- stdin handling patterns
- SIGWINCH handling style

But do not copy attach/session assumptions. Only reuse the terminal-control mechanics.

### 5. renderer-related snapshot structures

**Maybe reuse, but only if they stay local to vpty.**

If an existing host/snapshot cell struct helps the renderer, use it. But do not route this through session protocol types.

---

## What not to reuse

Do not reuse session-specific machinery just because it exists:

- `msr` attach/owner protocol code
- replay / snapshot protocol types
- owner-forward control paths
- session server/client structures
- any code whose primary purpose was resumable attach

If reused code has to be explained in terms of “owner”, “attach”, or “after_seq”, it probably belongs to the old architecture, not VPty.

---

## Proposed module layout

Keep the first implementation boring.

## 1. `src/vpty_main.zig`

Owns:
- argv parsing for `vpty -- <cmd...>`
- top-level startup
- wiring modules together
- final exit code mapping

This should stay small.

## 2. `src/vpty_process.zig`

Owns:
- `forkpty()`
- child launch
- PTY master fd ownership
- write-to-pty helper
- read-from-pty helper
- `TIOCSWINSZ` application
- `waitpid` / child exit collection

This is the inner PTY / child management layer.

## 3. `src/vpty_terminal.zig`

Owns:
- outer terminal raw-mode enter/restore
- tty checks
- current terminal size query
- maybe signal-safe-ish restoration hook registration

This should know nothing about libvterm.

## 4. `src/vpty_vterm.zig`

Could be a rename or wrapper around the current `terminal_state_vterm.zig`.

Owns:
- libvterm lifetime
- feed
- resize
- snapshot/screen readout
- cursor visibility/position
- cell style access

This should know nothing about PTY spawning.

## 5. `src/vpty_render.zig`

Owns:
- full repaint
- row-based redraw
- cursor placement
- cursor visibility output
- basic SGR emission if enabled in phase 1

This is the core presentation layer.

## 6. `src/vpty_loop.zig`

Owns:
- poll loop
- stdin → PTY
- PTY → vterm
- resize handling
- render scheduling
- child exit observation

This is the control plane.

---

## Phase 1 delivery order

## Phase 1A — executable scaffold

### deliverable
A `vpty` executable that parses:

```bash
vpty -- <command> [args...]
```

### work
- add build target for `vpty`
- minimal argv parsing
- reject missing command after `--`
- document invocation shape in help text

### success criteria
- `zig build` produces `vpty`
- `vpty -- /bin/echo hi` launches and exits cleanly

---

## Phase 1B — PTY process hosting

### deliverable
A minimal child-on-inner-PTY runner.

### work
- create `vpty_process.zig`
- port/adapt `forkpty()` child launch from existing host code
- own PTY master fd
- own child pid
- support:
  - read PTY bytes
  - write PTY bytes
  - resize PTY
  - wait for child exit

### success criteria
- child runs on real PTY slave
- `vpty -- bash` starts a shell on inner PTY
- normal exit code can be observed

---

## Phase 1C — outer terminal mode control

### deliverable
Reliable raw-mode lifecycle for interactive use.

### work
- create `vpty_terminal.zig`
- detect tty vs non-tty stdin/stdout
- if interactive:
  - save current termios
  - enter raw mode
  - restore on normal exit
- best-effort restoration on handled termination path

### success criteria
- shell/editor interaction feels normal
- terminal is restored after child exit
- broken terminal mode is not left behind on normal path

---

## Phase 1D — libvterm integration

### deliverable
A clean vterm adapter that can accept PTY output and expose screen state.

### work
- split or rename current `terminal_state_vterm.zig` into `vpty_vterm.zig`
- keep C shim narrow
- confirm feed/resize/snapshot contract
- keep state local to VPty only

### success criteria
- PTY output can be fed into libvterm
- current screen state can be queried reliably
- resize keeps vterm size in sync with PTY size

---

## Phase 1E — renderer

### deliverable
A simple but correct renderer.

### work
- create `vpty_render.zig`
- implement full repaint path first
- implement row-based redraw path second
- support:
  - explicit cursor positioning
  - visible grid output
  - cursor position
  - cursor visibility
  - alt-screen if stable enough
- optional basic SGR if easy enough from current cell model

### success criteria
- `vpty -- bash` is visibly usable
- `vpty -- vim file.txt` is usable
- redraws are coherent
- no logs are mixed into stdout render stream

---

## Phase 1F — event loop

### deliverable
A single-threaded foreground loop.

### work
- create `vpty_loop.zig`
- poll:
  - stdin
  - PTY master
  - resize notification source / signal integration
- on stdin:
  - write to PTY
- on PTY output:
  - feed libvterm
  - schedule redraw
- on resize:
  - apply `TIOCSWINSZ`
  - resize vterm
  - redraw
- on child exit:
  - clean up
  - exit with contract status

### success criteria
- no internal worker threads needed
- resize works
- output/render loop is stable
- wrapper exits promptly with child

---

## Phase 1G — polish and hardening

### deliverable
Stable phase-1 tool.

### work
- ensure diagnostics go to stderr only
- harden restoration path
- lock exit code behavior
- document known edge-case limitations
- trim debug prints

### success criteria
- tool is usable without visible internal noise
- tty is restored on normal path
- no session/runtime concepts leaked in

---

## Minimal initial rendering scope

To keep implementation small, phase 1 should explicitly support:

- full repaint path
- row-based redraw
- cursor position
- cursor visibility
- visible text grid
- resize coherence

Optional in phase 1 if easy enough:
- basic SGR attributes
- alt-screen handling

Deferred unless naturally easy:
- title handling
- aggressive incremental diffing
- exotic terminal private modes beyond what falls out cleanly

---

## Acceptance checklist

A phase-1-complete VPty should satisfy:

- `vpty -- bash` behaves like a normal interactive shell
- `vpty -- vim file.txt` is usable and responsive
- resize propagates correctly and remains visually coherent
- redraw happens on child output and resize
- terminal mode is restored on normal exit
- normal exit `N` maps to wrapper exit `N`
- signal exit maps to `128 + SIG`
- no attach/detach/session/replay concepts are present in implementation
- stderr diagnostics do not corrupt stdout rendering

---

## Suggested implementation order in code terms

If we want the shortest path to a working prototype:

1. extract minimal PTY child host from existing `host.zig`
2. extract/adapt raw tty handling from `attach_runtime.zig`
3. keep/adapt current libvterm adapter + shim
4. write full repaint renderer
5. wire the single poll loop
6. test with:
   - `bash`
   - `vim`
   - simple resize loop
7. only then consider row-level optimization and style polish

---

## Open questions for review

These should be answered before or during implementation:

1. Should phase 1 include basic SGR styling immediately, or is monochrome acceptable for the first usable cut?
2. Should alt-screen support be required for phase 1, or “best effort if libvterm path is already stable”?
3. Do we want a user-visible manual redraw trigger later, or should refresh remain entirely internal/event-driven?
4. Should `vpty` live as a separate executable only, or should there eventually be a library-ish internal module that other tools can embed?

---

## Recommendation

Keep phase 1 aggressively small.

The highest-risk failure mode is accidentally rebuilding another mini session system around vterm. Avoid that by keeping VPty as:

- foreground only
- local only
- tty only
- child-lifetime-bound
- render-state-owned
- protocol-free

If we hold that line, this should stay relatively simple and actually shippable.
