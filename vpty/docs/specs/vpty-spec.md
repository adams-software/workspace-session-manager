# VPty: Minimal Terminal Frontend for PTY-Hosted Applications

## Summary

VPty is a small standalone application that runs an arbitrary child process behind an inner PTY, maintains terminal state with libvterm, and renders that state to its own outer terminal. It is not a session manager, not a multiplexer, and not a resumable runtime. Its job is only to sit between an outer PTY and a child PTY, pass input and resize through normally, and make redraw/refresh possible because it owns an emulated screen model. PTYs already provide the right substrate for this: the slave side behaves like a normal terminal to the child, while the parent drives the master side. libvterm provides the terminal-state APIs VPty needs, including ingesting terminal bytes, resizing the emulator, and inspecting screen cells. ([man7.org][1])

## Product intent

VPty exists to solve one narrow problem well: run a normal terminal application in a way that still feels like a normal PTY-hosted app, while giving the wrapper enough terminal knowledge to repaint the current screen when needed. It should behave like a normal foreground terminal program from the outside, and the child should behave like a normal PTY-backed terminal program from the inside. The wrapper must exit when the child exits, preserving the child’s exit behavior as closely as practical. ([man7.org][1])

## Operational contract

The implementation should be guided by a short set of hard rules.

VPty is **state-faithful, not byte-faithful**. It aims to preserve usable terminal state and behavior, not to reproduce the child’s original PTY byte stream exactly on the outer terminal.

VPty is a foreground interactive terminal application, not a non-interactive pipe transformer. Phase 1 explicitly targets interactive tty use. Non-interactive stdin/stdout behavior is out of scope or best-effort only.

While active, VPty owns the outer screen contents and outer terminal mode. The renderer is the only writer to outer stdout while VPty is active. Diagnostics and debugging output must not be mixed into the render stream.

VPty must have a full repaint path internally, even if normal operation prefers row-based redraw. VPty must exit with stable, documented child-exit semantics.

## What VPty is

VPty is a terminal frontend. It launches a child on an inner PTY, reads the child’s terminal output from the PTY master, feeds that output into libvterm with `vterm_input_write()`, and renders the resulting terminal state to its own stdout. It also forwards user input from its stdin to the child PTY and mirrors terminal size changes to both the child PTY and libvterm using `TIOCSWINSZ` and `vterm_set_size()`. ([GitHub][2])

## What VPty is not

VPty is not a session runtime, not a detach/reattach protocol, not a terminal recorder, and not a transparent PTY proxy that preserves the child’s original output byte stream. The outer terminal sees VPty’s rendering of terminal state, not the child’s raw PTY bytes. That is an intentional simplification: it trades strict passthrough transparency for reliable redraw ownership and a smaller, clearer product boundary. PTYs themselves only provide the master/slave terminal channel; they do not define any built-in resume or replay mechanism. ([man7.org][1])

Byte-for-byte transparency is not a goal. Exotic terminal behaviors may differ from a native terminal in edge cases. The goal is normal usability for ordinary terminal applications, not exact escape-stream identity.

## User-facing behavior

The primary invocation shape is:

```bash
vpty -- <command> [args...]
```

Everything after `--` is passed through to the real child unchanged. VPty should be usable with shells, editors, REPLs, long-running terminal apps, and line-oriented processes. The child must receive a real PTY slave as its controlling terminal, so terminal-oriented programs continue to behave normally. `forkpty()` is the simplest conventional way to create this process model. ([Linux Die][3])

## Core expectations

From the outside, VPty should behave like a normal terminal application. It reads from stdin, writes terminal output to stdout, reacts to terminal resizes, and exits when its child exits. From the child’s point of view, it should look like an ordinary PTY-backed terminal. The child should receive input normally, observe size changes through the standard PTY window-size path, and continue to use normal terminal semantics. When the outer terminal size changes, VPty must apply that size to the inner PTY with `TIOCSWINSZ`, which in turn causes `SIGWINCH` to be sent to the foreground process group, and must also update libvterm to the same size. ([man7.org][4])

## Design constraints

The design is intentionally narrow.

VPty must remain a single foreground process, with no server mode, no persistence layer, no background daemon, and no attach/detach protocol. The wrapper’s lifetime is owned by the child’s lifetime. If the child exits, VPty exits. If the outer terminal disappears in a way that terminates VPty, that is outside the scope of this product. Refresh means repainting the current emulated screen state while the process is still alive, not restoring a terminated process later. This constraint is what keeps the product simple and robust. ([Linux Die][3])

The design should not drift into a half-pipe, half-interactive product during the initial implementation.

## Invariants

VPty should be built around a small set of invariants:

The child always runs on a real inner PTY slave. The wrapper always owns the corresponding PTY master. The child’s output is always fed into libvterm before being considered rendered. The outer display is always produced by VPty’s renderer, not by directly copying the child’s PTY bytes to stdout. The outer size and inner size must stay synchronized. The wrapper must terminate promptly when the child terminates. The renderer is the only writer to outer stdout while VPty is active. These invariants match the actual PTY model and the libvterm API surface, and they avoid ambiguous “sometimes passthrough, sometimes emulated” behavior. ([man7.org][1])

## Architecture

The process graph is:

```text
outer terminal/host <-> VPty <-> inner PTY master <-> child on inner PTY slave
```

VPty owns three responsibilities: PTY hosting, terminal emulation, and rendering. PTY hosting creates and manages the child and inner PTY. Terminal emulation feeds child output into libvterm and keeps emulator state current. Rendering turns libvterm’s current screen model into ordinary terminal output for the outer PTY. This is the same general architecture class used by terminal frontends that embed libvterm. libvterm exposes the primitives needed for this, including `vterm_input_write()`, `vterm_set_size()`, and screen inspection functions like `vterm_screen_get_cell()`. ([GitHub][2])

## Operational flow

Startup is straightforward. VPty determines the current outer terminal size, creates a libvterm instance at that size, creates an inner PTY and child process, and enters an event loop. The simplest implementation route is `forkpty()`, which combines PTY creation, `fork`, and terminal setup for the child. ([Linux Die][3])

When VPty is attached to an interactive tty, it places the outer terminal in raw mode. VPty is responsible for restoring terminal settings on normal exit, child exit, and handled signal paths. Restoration is best effort on abnormal termination. If outer stdin is not a tty, VPty does not attempt interactive raw-mode behavior. If outer stdin closes or hangs up during phase 1 interactive operation, the simplest rule is to stop input forwarding and terminate after best-effort cleanup.

During steady state, bytes read from the inner PTY master are written into libvterm with `vterm_input_write()`. Input read from stdin is written directly to the inner PTY master. On terminal resize, VPty sets the new inner PTY size with `TIOCSWINSZ` and updates libvterm with `vterm_set_size()`. After either new child output or a resize event, VPty renders the current terminal state outward. `TIOCSWINSZ` is the standard interface for setting terminal window size, and it triggers `SIGWINCH` to the foreground process group, which is how terminal applications are expected to discover size changes. ([GitHub][2])

When the child exits, VPty stops reading the PTY, restores outer terminal state if necessary, and exits with matching semantics. If the child exits normally with status `N`, VPty exits `N`. If the child dies from signal `SIG`, VPty exits with `128 + SIG`. This rule should be treated as normative, stable wrapper behavior. ([Linux Die][3])

## Refresh semantics

Refresh is intentionally narrow. A refresh means: repaint the current libvterm screen state to the outer terminal. It does not ask the child to redraw from history, does not replay original PTY bytes, and does not require any session protocol. Because VPty owns terminal presentation, it can always clear and repaint the visible screen from libvterm’s current state as long as VPty remains alive. This is the main functional win of the design. libvterm’s screen inspection APIs are what make this possible. ([GitHub][2])

Phase 1 refresh is event-driven. VPty redraws in response to child PTY output and terminal resize. A full repaint path must exist internally and may be exposed later as a manual redraw control, but a user-visible manual refresh trigger is not required for the initial product.

## Simplicity-first rendering policy

Engineering should optimize for correctness and simplicity before clever incremental rendering. The first implementation should support full redraw on explicit refresh and row-based redraw for normal updates. Cursor positioning should be explicit before drawing a row. Since libvterm stores rendered terminal state rather than a replayable original byte log, the renderer needs to map screen state back into ordinary terminal control sequences and text. The right source of truth is screen state, not the original child stream. ([GitHub][2])

The phase 1 render contract should explicitly cover the visible grid, cursor position, cursor visibility, and alt-screen state if libvterm exposes it cleanly enough for stable implementation. Terminal title handling is not required in phase 1. Basic SGR support should be included if it falls out naturally from the renderer; otherwise some styling complexity can be deferred. Rendering fidelity for wide and combining characters should be based on libvterm’s cell model, with the explicit understanding that phase 1 aims for usable correctness rather than perfect fidelity in every Unicode edge case.

## Robustness model

This product should promise “normal PTY behavior plus owned redraw,” not “perfect terminal transparency.” The child is standard PTY-backed and should behave normally. Resize should be standard. Input should be standard. But the outer terminal is seeing VPty’s rendering, so there may be rendering differences from a native terminal in edge cases involving unusual private modes or highly terminal-specific behavior. The design stays robust by explicitly owning that tradeoff instead of hiding it. ([man7.org][1])

While active, VPty owns the outer screen contents. On exit it should restore terminal mode, but it does not implicitly promise to restore prior screen contents unless that behavior is explicitly designed and implemented.

## Implementation guidance

The simplest implementation should use a single event loop and no internal worker threads. Poll stdin, the inner PTY master, and a resize notification source. When PTY output arrives, feed it into libvterm and schedule a render. When stdin arrives, forward it to the PTY. When resize occurs, update both the inner PTY and libvterm, then render. This keeps ownership simple and avoids concurrency bugs in a product whose value is mostly architectural clarity. `forkpty()` is the best default unless engineering has a strong reason to prefer a more manual `openpty()` plus `fork` path. ([Linux Die][3])

Signal handling should remain minimal and explicit. Resize should propagate via `TIOCSWINSZ`. Handled termination signals should trigger best-effort outer-terminal restoration before exit. Child termination governs wrapper termination. Diagnostic or debug output should go to stderr only and should not be allowed to corrupt the rendered terminal stream on stdout.

## Suggested module layout

A good first cut could be split into four modules: process/PTY management, libvterm state, rendering, and the event loop. The process/PTY module owns `forkpty()` and child exit handling. The vterm module owns `VTerm`, size updates, and screen access. The renderer converts libvterm cells and attributes into terminal bytes for stdout. The event loop glues these together. This separation is enough to keep the code understandable without creating unnecessary abstraction layers. ([Linux Die][3])

## Non-goals

This first product should explicitly not support persistent sessions, attach/detach, remote viewers, terminal recording, scrollback persistence, multi-viewer synchronization, or exact replay of original PTY bytes. Those are separate products or future layers. The whole point of VPty is to be the smallest useful terminal frontend that can host a child, keep a live screen model, repaint on demand, and exit with the child. ([man7.org][1])

## Acceptance criteria

A good first implementation should satisfy these practical checks:

Running `vpty -- bash` should behave like a normal shell inside a terminal. Running `vpty -- vim file.txt` should be usable and responsive. Resizing the outer terminal should resize the child and remain visually coherent. Triggering a refresh should redraw the visible screen without restarting the child. If the child exits with a specific status, VPty should exit with the corresponding wrapper status. None of these require persistence or session semantics; they are all direct consequences of standard PTY behavior plus libvterm-backed rendering. ([man7.org][1])

## Recommended rollout

Phase 1 should focus only on foreground execution, resize propagation, child exit passthrough, and a simple renderer. Phase 2 can improve redraw quality and rendering efficiency. Anything related to session persistence or reattach should be deferred to a separate system that can choose to host VPty as just another PTY application. That preserves the simplicity and reuse value of this component. ([man7.org][1])

If you want, I can turn this into a tighter RFC-style document with sections like Motivation, Goals, Non-goals, Architecture, API, and Open Questions.

[1]: https://man7.org/linux/man-pages/man7/pty.7.html?utm_source=chatgpt.com "pty(7) - Linux manual page"
[2]: https://github.com/neovim/libvterm/blob/nvim/include/vterm.h?utm_source=chatgpt.com "libvterm/include/vterm.h at nvim"
[3]: https://linux.die.net/man/3/forkpty?utm_source=chatgpt.com "forkpty(3): terminal utility functions - Linux man page"
[4]: https://man7.org/linux/man-pages/man2/TIOCSWINSZ.2const.html?utm_source=chatgpt.com "TIOCSWINSZ(2const) - Linux manual page"
