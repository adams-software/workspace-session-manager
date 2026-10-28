# Full-screen menu architecture

Status: implemented and validated on `epic/fullscreen-menu`.

WSM replaces its persistent status bar with an on-demand full-screen menu. The
child always receives the full terminal geometry. WSM owns menu policy and
session actions; the existing vpty owns the child screen model, terminal-mode
state, and ordered transfer of terminal presentation.

Durable logging and scrollback are unchanged. Their redesign remains a separate
phase.

## Product behavior

- Ctrl+G opens the menu. Esc, Enter, Ctrl+C, or Ctrl+G returns to the child.
- Ordinary input, including Ctrl+C, belongs to the child while the menu is
  closed.
- Attach, create, navigation, back, logs, force-kill, and detach remain available
  from the menu.
- Opening the menu does not resize the child. Real terminal resizes continue to
  reach the child while it is hidden.
- Child output continues to update vpty's bounded model while the menu is open.
  Resume restores the latest screen without replaying hidden output.
- If the hidden child exits, WSM remains in a detached menu so the user can
  attach or create another session. Closing that detached menu exits WSM.
- Prompt editing and clipping operate on Unicode grapheme boundaries and
  terminal cell widths. The prompt cursor remains visible on narrow terminals.

The UI remains keyboard-only and redraws on input, resize, session changes, or
presentation transitions. It has no animation or polling render loop.

## Component boundaries

| Component | Responsibility |
| --- | --- |
| WSM runtime | Hotkey and paste parsing, presentation state machine, menu rendering, session policy and actions |
| `SessionLink` | Bounded terminal/data relay, presentation command requests, incremental boundary decoding |
| vpty presentation server | One active presentation client per session, ordered yield/resume commands, disconnect recovery |
| vpty screen and stdout actors | Child screen model, supported mode state, output ordering, hidden render suppression, repaint |
| host and ptylog | Existing transport, lifecycle, and durable logging behavior |

The implementation adds no process and no second terminal model. Vpty already
needed the screen model to reconstruct a session; hidden output updates that same
model. The historical `alt` switcher is not part of the runtime because it would
duplicate WSM's input routing and vpty's presentation responsibilities.

The former bar renderer and reserved-row layout are removed. `menu_model.zig`
contains only navigation labels, while `menu_render.zig` owns the full-screen
surface.

## Presentation state machine

WSM has four presentation phases:

```text
child --Ctrl+G--> yielding --yield boundary--> menu
  ^                                             |
  |                                             |
  +------ resume boundary <-- resuming <--------+
```

`yielding` and `resuming` are real ordering phases. WSM does not paint the menu
until every surviving child byte before the yield boundary has reached the
terminal. It stops painting the menu when requesting resume and does not release
new child presentation until it consumes the resume boundary.

Input read while yielding is bounded to 4096 bytes and interpreted by the menu
after the yield boundary. Input read while resuming is discarded because it was
typed against the closing menu and must never leak into the child.

## Wire contract

Each new session exposes a Unix socket named `<session>.present`. WSM sends one
newline-delimited command at a time:

```text
yield <hex-token>\n
resume <hex-token>\n
```

Vpty places the correlated boundary on the session data stream:

```text
ESC P +wsm;<yield|resume>;<hex-token> ESC \
```

The yield boundary trails child output already committed for presentation.
Unstarted render work is dropped, and a partially written render finishes before
the boundary. The resume boundary leads terminal-mode restoration, full repaint,
and subsequent live output.

WSM strips all private WSM frames and accepts a transition only when its action
and token match the pending request. Commands and frames are decoded
incrementally across arbitrary socket reads. Data and command buffers retain the
existing bounded queue limits.

While hidden, vpty continues reading the child and updating the model. It
suppresses render publication and one-shot terminal controls rather than building
a replay queue. On resume it restores supported persistent modes, including
application cursor keys, bracketed paste, focus reporting, mouse tracking and
encoding, and supported paste variants.

## Input contract

The Ctrl+G router retains partial prefixes across terminal reads and recognizes
bracketed paste incrementally. Ctrl+G inside a bracketed paste belongs to the
child. A hotkey can occur anywhere in a read; bytes before it reach the child and
bytes after it belong to the opening menu.

Menu escape sequences and UTF-8 scalars also survive arbitrary read boundaries.
Malformed UTF-8 is discarded without consuming a following valid key. Left,
right, and backspace operate on extended grapheme clusters, including combining
marks, emoji modifiers, flags, and ZWJ sequences.

## Failure and compatibility behavior

- If a WSM viewer disappears while vpty is hidden, presentation-client loss
  makes vpty restore modes, enable presentation, and request a full repaint. A
  later viewer can attach normally.
- A hidden child exit leaves the current WSM viewer in a detached menu. Stream
  loss while the child owns the terminal, or after resume has begun, exits the
  viewer cleanly.
- Terminal hangup and runtime errors restore raw mode, interaction modes, cursor
  visibility, and the outer alternate screen before WSM exits.
- New sessions have a presentation socket. A session created by an older binary
  has no such capability; WSM passes Ctrl+G through to that child instead of
  attempting an unsafe fallback.
- The presentation server has one active client. Accepting a replacement client
  recovers visible presentation from the old client before ownership changes.
- Same-size and changed-size redraws restore the child's explicitly supported
  terminal modes.

Replacing the installed executable does not replace vpty inside an already
running session. Older sessions retain their legacy behavior until recreated.

## Validation

The main verification commands are:

```sh
zig build test
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
zig build smoke-wsm-menu
zig build smoke-wsm-menu-actions
zig build stress-wsm-menu
python3 vpty/scripts/test_mode_redraw.py zig-out/bin/vpty
python3 wsm/scripts/test_mode_cleanup.py zig-out/bin/wsm
```

Coverage includes:

- partial writes and ordered yield/resume boundaries;
- hotkeys at arbitrary read boundaries and inside bracketed paste;
- split escape sequences and UTF-8 input;
- repeated transitions, hidden continuous output, and hidden resize;
- navigation, attach, create, cancellation, logs, and force-kill behavior;
- viewer loss and older sessions without presentation capability;
- child exit while hidden followed by attachment to another session;
- terminal mode restoration, Unicode prompt editing, and narrow terminals.

The transition stress test performs twenty menu cycles and samples one second of
continuous hidden output. It requires independent child progress, no hidden
terminal output, at most 24 MiB RSS growth, at most four additional descriptors,
no additional process, and at most 0.75 CPU-seconds in WSM and vpty.

## Main versus epic resources

`experiments/fullscreen-menu/compare_resources.py` runs the exact `origin/main`
and epic binary stacks against identical idle and continuously updating children.
It uses private session roots, drains both terminals, excludes the child process
from infrastructure RSS/CPU/FD totals, and reports all individual runs plus their
medians.

The three-run audit used Linux ReleaseSafe builds of main `ab989ae` and epic
`ac244d6`. The subsequent hidden-child recovery change does not affect these
steady attached workloads, and the comparison tool was rerun against the final
epic during readiness validation.

| Workload and metric | Main median | Epic median |
| --- | ---: | ---: |
| Idle startup | 26.0 ms | 27.7 ms |
| Idle CPU over 1 second | 0.00 s | 0.00 s |
| Idle RSS | 10,412 KiB | 10,304 KiB |
| Continuous-output CPU over 1 second | 0.17 s | 0.18 s |
| Continuous-output RSS | 10,656 KiB | 10,508 KiB |
| File descriptors | 43 | 46 |
| Processes | 6 | 6 |

The three additional descriptors are the presentation listener and connected
client endpoints. The epic adds no process, and CPU/RSS/startup differences are
within run-to-run noise for this sample.

Reproduce the comparison after building both worktrees:

```sh
python3 experiments/fullscreen-menu/compare_resources.py \
  --main /path/to/main/zig-out/bin/wsm \
  --epic /path/to/epic/zig-out/bin/wsm
```

The final transition run reported zero RSS growth, zero descriptor growth, zero
process growth, 0.110 CPU-seconds during the hidden interval, and continued
child progress. Exact timing and RSS values vary; the enforced ceilings are the
regression contract.

## Deferred work

Logging and scrollback redesign remain outside this epic. A future implementation
can enter through the existing logs menu action without changing the presentation
boundary or adding another PTY router.
