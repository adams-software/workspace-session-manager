# scroll design

## Summary

`scroll` is a standalone CLI tool that converts a `script` typescript file into a clean, terminal-aware linear buffer that can be piped into standard Unix tools like `less`, `vim`, or `nvim`.

The v1 goal is deliberately narrow:

- ingest a raw typescript file
- interpret it with a real terminal engine
- produce a normalized scrollback-style text stream
- keep plain text as the default output mode
- support optional ANSI-preserving output for pager use
- omit TUI rendering for now
- suppress alternate-screen/TUI regions instead of replaying them

Example usage:

```bash
scroll session.typescript | less
scroll --ansi session.typescript | less -R
scroll session.typescript | nvim -
cat session.typescript | scroll
```

This is not a live session manager feature and not a replay browser in v1. It is an offline terminal-aware scrollback extractor.

## Goals

### Primary goals

- Convert raw terminal transcript bytes into a usable, line-oriented history buffer.
- Feel Unixy and composable.
- Work on very large typescript files.
- Reuse the existing libvterm/vterm work already present in the repo.
- Keep `scroll` simpler than `vpty`.

### Non-goals for v1

- Do not render TUIs or alternate-screen applications faithfully.
- Do not support time-accurate replay.
- Do not build a custom fullscreen pager UI.
- Do not solve perfect hyperlink preservation in output.
- Do not support stdin streaming incrementally, full read/process is fine in v1.
- Do not introduce session-manager-specific control flow.

## Product behavior

### Input

`scroll` accepts:

- a path to a typescript file
- or stdin if no file is provided

Examples:

```bash
scroll session.typescript
cat session.typescript | scroll
```

### Output

`scroll` writes a normalized UTF-8 linear buffer to stdout.

Modes:

- default: plain text
- `--ansi`: preserve ANSI styling and OSC 8 hyperlinks where supported by the extracted data

That output is intended to be piped to:

- `less`
- `vim -`
- `nvim -`
- files
- other Unix text tools

### User-visible handling policy

#### Normal shell / line-oriented output

Normal output becomes ordinary lines in the emitted buffer.

#### Alternate screen / TUIs

When the transcript enters alternate screen, `scroll` does not try to preserve or replay the TUI body in v1.

Instead, v1 simply suppresses alternate-screen content from the emitted buffer.

This keeps the v1 output:

- safe
- copyable
- searchable
- composable with standard text tools
- free of confusing marker-placement edge cases

## Core extraction strategy

The best extraction hook is the terminal engine's normal-screen line-committed event, not snapshot diffing.

### Primary hook

Use the libvterm-backed scrollback push callback as the primary extraction hook.

This is best because it:

- fires when a rendered normal-screen row leaves the visible screen and becomes history
- is already terminal-aware
- avoids guessing from snapshots
- avoids most redraw noise
- naturally produces line-oriented history, which is exactly what `scroll` wants

Conceptually, the engine should expose events in a shape like:

```zig
pub const HistoryEvent = union(enum) {
    line_committed: struct {
        cells: []const HostScreenCell,
        continuation: bool,
    },
    alternate_enter,
    alternate_exit,
    resize: struct { rows: u16, cols: u16 },
};
```

`scroll` should build around that event stream.

### Why snapshot diffing is not primary

Snapshot diffing can still be useful for debugging, validation, or fallback behavior.

But it is the wrong primary hook because it:

- creates too much noise from cursor motion and redraws
- makes line boundaries ambiguous
- makes it harder to distinguish stable history from temporary screen state
- leaks too much terminal policy into `scroll`

### Final visible flush

Committed-history events alone are not enough.

At EOF, `scroll` must also extract the remaining visible normal-screen contents that never scrolled off the screen. Otherwise the trailing shell page can be lost.

So the engine also needs:

- current visible snapshot
- or a helper to extract visible normal-screen lines at finalization time

That is a finalization hook, not the main history source.

## High-level architecture

There are two architectural layers.

### 1. `term_engine` (shared library)

This is the reusable terminal-aware core that should eventually be shared with `vpty`.

Responsibilities:

- wrap libvterm / current terminal-state adapter work
- accept raw terminal bytes
- maintain terminal state
- expose history events for committed normal-screen lines
- expose alternate-screen enter/exit transitions
- expose current rendered visible rows/cells for EOF flush and debugging

Non-responsibilities:

- file I/O
- transcript indexing
- CLI
- output formatting policy
- pager/editor integration

This package should remain generic and reusable.

### 2. `scroll` (application)

`scroll` owns all app-specific logic under `scroll/src`.

Responsibilities:

- read transcript bytes from file or stdin
- feed bytes into `term_engine`
- build the logical history buffer
- decide how to suppress alt-screen regions
- emit the final normalized text buffer to stdout

This is where product policy lives.

## Internal model for v1

`scroll` can build a simple linear sequence of text lines from the transcript.

Example:

```text
$ cargo test
running 12 tests
...
$ echo done
done
```

Internally, v1 can stay as simple as:

```zig
const Record = union(enum) {
    text_line: []u8,
};
```

## Core policies

### Normal buffer policy

During replay through `term_engine`, when a normal-screen row is committed to history, `scroll` appends the corresponding text line into the logical history buffer.

Priority order for extraction sources:

1. explicit scrollback / line-committed events from libvterm-backed hooks
2. visible-row extraction only for final EOF flush
3. snapshot-based fallback only if absolutely necessary for special cases

Correctness matters more than elegance.

### Alternate-screen policy

When alternate screen is entered:

- suppress line extraction while alternate screen is active

When alternate screen is exited:

- resume normal line extraction

This means TUI-heavy regions are omitted from output in v1.
That is intentional.

### Resize policy

Resizes can optionally influence future behavior, but they do not need user-visible output in v1.

## Output normalization

The emitted output should be designed to work well with standard text tools.

### Required behavior

- UTF-8 output
- preserve ordinary text content
- normalize line endings sensibly
- plain-text mode avoids emitting terminal control sequences
- ANSI mode preserves styling on supported extracted lines

### Nice-to-have later

- richer hyperlink preservation for committed history lines
- optional alt-screen markers
- offset annotations

Recommendation for v1: plain text remains the default, with ANSI as an opt-in mode.

## CLI shape

### Proposed v1 interface

```bash
scroll [typescript-file]
```

Behavior:

- if file is provided, read file
- if not, read stdin
- write normalized output to stdout

Examples:

```bash
scroll session.typescript | less
scroll session.typescript | nvim -
cat session.typescript | scroll | less
```

### Optional later flags

```bash
scroll --help
```

Recommendation: keep v1 minimal. A single input plus stdout path is enough.

## Scaling and large files

The system should be designed so very long typescript files are at least feasible.

### v1 strategy

- process the transcript once from start to finish
- keep the logical output buffer in memory
- dump to stdout at end

This is acceptable for a first implementation.

### Why this is okay

The output model is much cheaper than a frame-based replay browser:

- no full timeline of snapshots
- no seek index required
- no interactive history UI

The main costs are:

- raw input size
- engine state during replay
- accumulated logical output lines

### Future scaling options

If memory becomes a problem later:

- spill logical output lines to temp storage
- chunk output and stream as it is produced
- add optional sidecar index or metadata

None of these are required for v1.

## Reuse from existing codebase

### Reuse directly

- libvterm shim and terminal adapter work
- terminal cell extraction
- Unicode and grapheme handling already in the terminal stack
- alt-screen detection and state awareness
- any existing snapshot or row extraction utilities that are engine-safe

### Reuse after extraction/refactor

- `terminal_state_vterm`-style logic should move behind `term_engine`
- any row or cell conversion helpers that are not PTY-host-specific

### Do not reuse directly

These should stay out of `scroll`:

- `vpty` PTY host loop
- `alt`
- `msr`
- `wsm`
- output sink or live passthrough plumbing

Those are orchestration and runtime concerns, not transcript-extraction concerns.

## Suggested source layout

### Shared package

```text
term_engine/
  src/
    root.zig
    terminal_state_vterm.zig
    vterm_shim.c
    vterm_shim.h
    vterm_screen_types.zig
```

### App

```text
scroll/
  src/
    main.zig
    cli.zig
    replay.zig
    history.zig
    output.zig
```

### Suggested module responsibilities

- `main.zig`
  - app entrypoint
- `cli.zig`
  - argument parsing
- `replay.zig`
  - file/stdin read loop feeding `term_engine`
- `history.zig`
  - logical history line storage
- `output.zig`
  - final stdout emission

This keeps all app-specific behavior inside `scroll/src` while letting `term_engine` stay reusable.

## Implementation plan

### Phase 1: extract `term_engine`

- identify terminal-aware pieces in current `vpty` stack
- move them behind a reusable engine API
- ensure bytes-in/state-out works without PTY hosting

Deliverable:
- a minimal engine that can be fed transcript bytes from a file

### Phase 2: expose history events

- add line-committed events for normal-screen history
- add alternate-screen enter/exit transitions
- add visible-screen extraction for EOF flush

Deliverable:
- a reusable event-oriented engine API for transcript extraction

### Phase 3: build `scroll` replay pipeline

- read transcript file/stdin
- feed bytes through engine
- build logical history lines
- emit normalized output

Deliverable:
- a program that produces normalized text output

### Phase 4: validate against real transcripts

Test with:

- shell commands
- build logs
- long-running line-oriented output
- transcripts that launch and exit `nvim`

Success criteria:

- shell output looks clean in `less`
- TUI regions are suppressed rather than dumped as raw garbage
- output is copyable and searchable in editors and pagers

### Phase 5: polish

- normalization cleanup
- optional flags if needed

## Open design questions

These should be resolved during implementation, but none block starting.

### 1. Best committed-line hook details

Exactly which libvterm-backed callback or wrapper shape should be the canonical committed-history signal?

Preferred answer:
- the most correct and robust scrollback push hook available

### 2. Normalization policy

How aggressively should output be normalized?

Recommendation:
- plain UTF-8 text only in v1
- no ANSI preservation yet

### 3. When to flush output

Should the tool accumulate entire output before writing, or stream progressively?

Recommendation:
- accumulate first in v1 for simpler correctness

## Explicit v1 decisions

- `scroll` is an offline transcript-to-buffer tool.
- Output is stdout-oriented and meant to be piped into existing tools.
- The system is terminal-aware, not raw-text or regex-based.
- Normal-screen output becomes logical scrollback lines.
- Alternate-screen and TUI regions are suppressed.
- No custom pager UI in v1.
- No TUI rendering in v1.
- No frame browser in v1.
- `term_engine` is the only reusable shared layer.
- All history-building and output policy stays inside `scroll/src`.

## Example UX

```bash
scroll session.typescript | less
```

For a shell-heavy transcript, the user sees a normal readable log.

For a transcript that launched `nvim`, the user sees the surrounding shell output without the fullscreen editor body.

This is intentionally incomplete for TUIs, but clean and useful.

## Recommendation

Build this as a focused v1.

Do not try to solve:

- TUI replay
- full snapshot browsing
- custom pager UI
- search/copy model
- rich terminal feature preservation

Those can come later if the terminal-aware extraction core proves useful.

The right first milestone is much simpler:

> `scroll` takes a typescript and emits a clean terminal-aware linear buffer that works great with `less` and editors.
