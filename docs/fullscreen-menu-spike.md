# Full-screen menu spike

Status: proposed architecture; no production runtime changes.
Branch: `epic/fullscreen-menu`, based on main `46551e1` (beta.28).

Replace the persistent status bar with an on-demand full-screen menu. The child
always gets the full terminal size. WSM manages sessions and temporarily presents
a menu; vpty remains responsible for reconstructing the live child display.

The epic stays separate from main and normal releases. Implementation PRs target
the epic branch. Removing durable logging or adding in-memory scrollback is a
separate phase; this spike does not change their behavior.

## Recommended product behavior

- Ctrl+G opens the menu. Esc, Ctrl+C, or Ctrl+G returns to the current child.
- While attached, ordinary input, including Ctrl+C, goes to the child.
- The menu shows sessions and the existing selection, creation, navigation,
  logging, and confirmed destruction actions. Detach is an explicit action.
- Opening the menu does not resize the child. Actual terminal resizing still
  reaches the child, including while the menu is visible.
- Child output continues to be processed while the menu is open. Returning shows
  the latest screen, without replaying everything produced in the meantime.
- If the child exits while the menu is open, keep the menu available to select or
  create another session. Restore the user's terminal on attachment exit/error.
- Start with a keyboard-only menu, rendered on input, resize, or relevant session
  changes. No periodic animation, embedded live preview, or extra polling loop.

Use a menu module in the existing local WSM client initially. A future `wsm menu`
entry point can reuse that module. A separate process is worthwhile only if it
removes more lifecycle and IPC code than it introduces.

## What the code tells us

The persistent chain created by `wsm/src/session_primitives.zig` is an outer
control host, an inner data host, vpty, ptylog, and the shell. Menu phase one does
not change that process chain. The local WSM attachment connects to the data and
control sockets.

| Area | Existing responsibility | Proposed treatment |
| --- | --- | --- |
| `wsm/src/main.zig` | Input routing, event loop, bar drawing, viewport coordination | Keep one event loop; switch between child and full-screen menu ownership |
| `wsm/src/bar_layout.zig`, `bar_render.zig`, `bar_model.zig` | Reserved row, bar representation and drawing | Remove as the menu replaces their callers |
| `wsm/src/ui_state.zig` | Selection and action/prompt transitions | Reuse behavior; remove bar-specific assumptions |
| `wsm/src/policy.zig`, `service.zig`, `executor.zig` | Session operations and action execution | Reuse; detach action data from bar presentation |
| `wsm/src/session_link.zig` | Bounded socket/terminal relay and resize requests | Preserve queue bounds and EOF handling; add a small presentation handoff interface |
| `vpty/src/vpty_main.zig`, `stdout_actor.zig` | Screen model, repaint and output commit ordering | Own suspension/resumption of viewer presentation |
| `vpty/src/side_effects.zig` | Forwarded terminal controls | Retain supported persistent mode state for restoration |

Concrete deletion targets include `renderBar`, `clearBar`, the first-pump bar
reassertion, and resize calculations that reserve a row. Generic attach/redraw
coordination still needs to exist; moving it is not itself a simplification.
Some menu state and rendering code will replace bar code, so counting all current
UI lines as removable would exaggerate the savings.

The former `alt` package (removed in `96321b6`) was a two-PTY switcher. It drained
inactive output and requested repaint on switching, but did not restore a complete
terminal state. The older hotkey implementation was about 972 lines; the former
shell menu was about 761. Recovering that whole stack would reintroduce process,
signal, resize, and input-routing machinery. Its useful idea is exclusive screen
ownership, which does not require resurrecting the package.

## The handoff is the first engineering gate

There are three implementation choices:

| Choice | Finding |
| --- | --- |
| Disconnect or stop reading while the menu is visible | `host/src/server.zig::masterPollEvents` stops reading its PTY when no owner can receive output. This can eventually back-pressure the child. |
| Keep draining and discard hidden output, then request a redraw | Restores cells in the probe below, but loses terminal modes. Arbitrary stream cut points and queued output also need handling. |
| Explicitly yield and resume presentation in vpty | Recommended prototype: vpty continues consuming/modeling child output and controls a clean display handoff. Requires a small ordered protocol. |

A successful same-size resize is already a full repaint trigger in vpty. That
does **not** make resize a complete presentation protocol: the control socket's
reply is not a barrier for bytes still pending in the data socket or local output
queue, and a screen snapshot does not contain every forwarded terminal mode.

The required contract is:

1. The attachment requests a yield. vpty finishes any partially emitted output
   sequence/frame, cancels unstarted display work, and emits an ordered boundary.
   The attachment drains preceding bytes to the terminal before painting the menu.
2. While yielded, vpty keeps reading the child and updating its bounded model and
   supported mode state. Suppress/coalesce display work; do not build a hidden
   replay queue or spin rendering frames that nobody sees. The attachment keeps
   servicing its connection and lifecycle events.
3. The menu establishes its own keyboard/cursor/mouse baseline and owns terminal
   output. Do not depend on nested alternate-screen escapes acting as a stack.
4. On resume, restore the child's supported modes, full screen and cursor at the
   current geometry before releasing subsequent live display updates. Keep input
   routing explicit during the transition.

Use a bounded state representation for persistent modes already supported by
vpty: application cursor keys, bracketed paste, focus reporting, mouse tracking
and encoding, and supported paste variants. A menu needs its own baseline so a
child's mouse events cannot become menu commands. One-shot side effects such as
clipboard writes must not accumulate for replay; suppress them while hidden.

The prototype uses a session-scoped vpty socket named `<session>.present`; host
remains a generic transport. Requests are newline-delimited `yield <token>` and
`resume <token>` commands. Tokens are caller-generated hexadecimal correlation
values, up to 64 characters. Vpty emits a private DCS frame on the data stream:
`ESC P +wsm;<action>;<token> ESC \\`. The caller strips every WSM frame and accepts
only the action/token it is waiting for.

The yield frame is a trailing boundary: vpty finishes a render already partially
written, drops render work that has not started, and writes the frame after the
surviving bytes. The resume frame is a leading boundary: terminal-mode restoration
and a full repaint follow it. This lets WSM stop painting the menu when it sees the
frame and forward the remainder of the same read as child presentation. Commands,
tokens, and frames all require incremental parsing across arbitrary read splits.

Disconnecting or replacing the presentation-control client recovers visible
presentation and requests a full repaint, so a crashed viewer cannot strand a
session in its hidden state. Sessions created by older binaries have no `.present`
socket; WSM must treat the missing socket as an unsupported capability and leave
the hotkey with the child. Raw clients keep their existing behavior because vpty
does not change presentation until a client explicitly sends a valid request.

The prototype must demonstrate how it preserves raw legacy clients and detects
capability for older persistent sessions. Initially test with new, isolated epic
sessions. Replacing the executable alone does not replace the vpty already running
inside an existing session. Do not silently use an unsafe fallback for an older
session; settle the compatibility/restart behavior before integration.

If this boundary needs a second terminal emulator, another persistent helper, or
a broad transport rewrite, revisit the design before building the menu on it.

## Reproducible evidence

From the repository root, with the current Linux binaries built:

```sh
python3 experiments/fullscreen-menu/probe_handoff.py zig-out/bin/wsm
```

The Python 3 probe creates a private temporary workspace and one owned session,
then kills it on exit. It enables bracketed paste and mouse tracking while the
viewer discards output, and requests a same-size repaint. Observed on the beta.28
implementation:

```json
{
  "same_size_resize_repaints_screen": true,
  "replays_bracketed_paste_mode": false,
  "replays_mouse_tracking_mode": false,
  "hidden_bytes": 147,
  "restored_bytes": 2461
}
```

This establishes a gap in the drain/discard/repaint approach, not a working menu
or a performance result. Byte counts and timings may vary. The probe uses bounded
collection intervals; implementation tests must use explicit protocol boundaries.

## Focused implementation sequence

1. **Prove presentation handoff.** Add the minimal vpty/attachment prototype and
   integration tests, with no replacement UI yet. Exercise terminal modes,
   partial output writes, repeated yield/resume, and a child that keeps producing
   output while hidden. Document the exact wire and compatibility contract.
2. **Replace the bar with the full-screen menu.** Reuse session actions and one
   event loop. Give the child every row and remove the obsolete bar modules and
   redraw workarounds in the same change. The epic provides isolation; avoid a
   long-lived second production UI selected by a feature flag.
3. **Validate transitions and resource behavior.** Cover switching sessions,
   cancellation, log viewer return, child exit, resize while hidden, tiny
   terminals, and restoration on failure. Add repeated menu toggles and hidden
   output to resource testing before considering a main PR.

Input tests must include hotkeys anywhere in a read, multiple events per read,
split escape sequences and UTF-8, and bracketed paste containing Ctrl+G. Specify
what happens to remaining input in a read when ownership changes; do not let a
menu cancellation accidentally execute trailing menu input in the child. Menu
search must handle emoji and combining marks without reviving the split-read bug.

The implemented transition stress harness runs with:

```sh
zig build stress-wsm-menu
```

It uses a real controlling PTY and a continuously producing child. An independent
progress file proves the child advances while hidden. The harness also exercises
hidden resize restoration, twenty yield/resume cycles, and child exit while the
menu owns the terminal. It fails on leaked hidden terminal bytes, more than 24 MiB
RSS growth, more than four additional descriptors, or more than 0.75 CPU-seconds
in WSM and vpty during the one-second hidden-output interval. The process count
must not grow across the repeated transitions.

Measure main versus epic under an idle child, continuously producing child, and
repeated menu transitions. Check idle CPU, RSS after warm-up, queue high-water
marks, descriptors and process counts. Use a progress signal independent of the
hidden display to prove the child continues working. Preserve existing audited
buffer limits and resource checks; a visually correct menu is not sufficient.

At final review, show the deleted bar/viewport machinery, replacement handoff
surface, tests and measured resource results. There should be no additional live
terminal model or persistent process. Only then propose merging the epic to main.
Logging/scrollback redesign follows separately, using a menu action as its future
entry point rather than extending this first change.
