# scroll architecture

## Goal

Build `scroll` as a standalone transcript-to-buffer tool that:

- reads a `script` typescript file
- reconstructs terminal behavior with libvterm-backed logic
- extracts committed normal-screen history lines
- emits a normalized linear text buffer to stdout
- suppresses alternate-screen and TUI regions instead of rendering them

This should be a new tool, not more logic inside `vpty`.

## Core model

The architecture is intentionally simpler than the earlier frame-browser direction.

For v1:

- `scroll` is not a pager UI
- `scroll` does not browse frames
- `scroll` does not seek through transcript history
- `scroll` is an offline extraction pass from transcript bytes to a normalized line buffer

The key extraction model is event-oriented:

1. **line committed to normal-screen history**
2. **alternate-screen enter/exit transition**
3. **final visible normal-screen flush at EOF**

## Reuse

The strongest reusable pieces from the current repo are:

- libvterm shim
- Zig adapter around libvterm
- terminal cell extraction
- Unicode and grapheme handling
- alt-screen state detection
- snapshot or visible-row access for final flush behavior

You can also reuse the existing transcript capture path in `wsm`:

- `create --log`
- `.typescript` stored next to the socket
- `wsm log` locating the transcript file

That side already works and should not need major design change.

## Extraction target

Right now terminal-state logic lives inside `vpty` alongside live PTY hosting and runtime orchestration. The architectural goal is to extract a reusable core with this shape.

### `term_engine`

Responsibilities:

- initialize libvterm state
- feed raw terminal bytes
- maintain terminal state
- emit committed-history-line events for normal-screen output
- emit alternate-screen enter/exit transitions
- expose visible normal-screen rows or a helper for EOF flush
- expose minimal metadata as needed, such as resize information

This is the core reusable layer.

It should not know about:

- PTYs
- polling
- `/dev/tty`
- transcript files
- CLI behavior
- output formatting policy
- editor or pager integration
- `msr`
- `alt`
- `wsm`
- menus

Keep it generic and composable.

## Event model

The preferred `term_engine` surface for `scroll` is an event stream oriented around history extraction.

Conceptually:

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

The important part is the semantics, not the exact spelling.

### Primary event

`line_committed`

This is the canonical extraction hook.
It should fire when a rendered normal-screen row leaves the visible screen and becomes history according to terminal scrollback semantics.

This is better than snapshot diffing because it is:

- terminal-aware
- line-oriented
- less noisy
- less policy-heavy in the application layer

### Secondary events

`alternate_enter` and `alternate_exit`

These let `scroll` suppress normal line extraction while alternate screen is active.

### Finalization path

Committed-line events are not sufficient by themselves.
At EOF, the engine must also support extracting the visible normal-screen tail that never scrolled off.

That can come from:

- current visible snapshot
- visible-row helper
- another small finalization API

The point is to avoid losing the trailing shell page.

## Application layer

### `scroll`

`scroll` owns all app-specific logic under `scroll/src`.

Responsibilities:

- read transcript bytes from file or stdin
- feed bytes into `term_engine`
- listen to history events
- build a logical linear buffer
- suppress alternate-screen regions
- perform EOF visible flush
- emit final normalized text to stdout

This is where product policy lives.

## Internal buffer model

`scroll` can build a single logical history buffer as a sequence of text lines.

Example:

```text
$ cargo test
running 12 tests
$ echo done
done
```

A minimal structured representation is enough:

```zig
const Record = union(enum) {
    text_line: []u8,
};
```

## Data flow

### Replay pass

1. open transcript file or stdin
2. feed bytes into `term_engine`
3. consume committed-line and mode-transition events
4. append text-line records into the logical buffer when not in alternate screen
5. at EOF, flush remaining visible normal-screen lines
6. emit final normalized text to stdout

This is a single forward pass in v1.

## Core policies

### Normal-screen extraction

Use committed normal-screen history lines as the primary source.

Priority order:

1. libvterm-backed committed-line / scrollback-push hook
2. visible-row extraction only for EOF tail flush
3. snapshot-based fallback only if absolutely necessary

Do not use snapshot diffing as the primary extractor.

### Alternate-screen handling

When alternate screen is entered:

- suppress normal line extraction while alternate screen is active

When alternate screen is exited:

- resume normal line extraction

This intentionally omits TUI regions from output in v1.

### Resize handling

Resize effects can be preserved internally for correctness, but they do not need user-visible output in v1.

## Output normalization

The emitted output should be designed for standard Unix text tools.

Required behavior:

- UTF-8 output
- sensible newline normalization
- no terminal control sequences in v1 output
- no terminal control sequences from suppressed regions

Later options may include:

- ANSI-preserving mode
- optional alternate-screen markers
- offset annotations

But v1 should stay plain text.

## Handling large files

Compared with a frame browser, this design is cheap.

For v1:

- process transcript once
- keep logical output buffer in memory
- dump to stdout at end

That is acceptable because v1 does not need:

- interactive seek
- timeline snapshots
- frame index structures

If scaling becomes a problem later, possible options are:

- temp-file spill for records
- streaming output
- sidecar metadata

None are required to start.

## What to reuse from the current codebase

### Directly reusable

- libvterm shim and adapter
- terminal cell extraction
- Unicode and grapheme handling
- alt-screen state handling
- current transcript capture path in `wsm`

### Reusable with refactor

- terminal-state adapter logic under `term_engine`
- row or cell conversion helpers that are not PTY-host-specific

### Not reusable as-is

- `alt` switching logic
- live PTY host loop
- `wsm_menu`
- `msr` session control
- live output plumbing

Those are runtime orchestration concerns, not transcript extraction concerns.

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

## Suggested implementation order

### Phase 1

Extract `term_engine`.

Goal:

- bytes in
- state out

### Phase 2

Expose history extraction events.

Goal:

- committed normal-screen line events
- alternate-screen enter/exit events
- EOF visible flush support

### Phase 3

Build `scroll` replay pipeline.

Goal:

- read transcript file/stdin
- feed engine
- accumulate logical records
- emit normalized output

### Phase 4

Validate against real transcripts.

Test with:

- shell commands
- build logs
- long-running line-oriented output
- transcripts that launch and exit `nvim`

Success criteria:

- shell output looks clean in `less`
- TUI regions are omitted instead of turning into garbage
- output is copyable and searchable in editors and pagers

### Phase 5

Polish.

Possible later work:

- optional alternate-screen markers
- normalization cleanup
- optional flags
- streaming or temp storage if needed

## V1 boundaries

Keep v1 tight:

- offline transcript only
- stdout-oriented output
- line buffer extraction only
- alternate-screen suppression for TUIs
- no custom pager UI
- no frame model
- no seek/index layer
- no TUI rendering
- no streaming stdin incrementally
- no ANSI-preserving mode yet

## Main risks

The hardest technical question is now clear:

- what exact hook in `term_engine` best represents a committed normal-screen history line?

The recommended answer is:

- the libvterm-backed scrollback-push or equivalent committed-line callback

Other real questions:

- how best to convert committed row cells into normalized text lines
- how to avoid duplicating EOF visible-tail lines

These are real design questions, but they are narrow and do not block starting.

## Bottom line

This is now a focused extraction-and-output project, not a replay-browser project.

The new work is:

- extract a reusable `term_engine`
- expose committed-line and mode-transition events
- build `scroll` as a transcript-to-buffer application on top

That is smaller, cleaner, and much more likely to produce a useful v1 quickly.
