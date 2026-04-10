# Terminal Control Routing for `vpty`

## Purpose

Document the control-plane split that `vpty` actually needs between:

1. **virtual-only bytes** consumed by the terminal model and renderer,
2. **pass-through terminal controls** that must reach the real outer terminal,
3. **policy-controlled controls** that may be forwarded, virtualized, or denied,
4. **unknown/unsupported controls** that should be handled conservatively.

This doc exists because the large-paste `nvim` lockup turned out to be a control-routing bug, not a PTY transport bug.

`nvim` enabled bracketed paste mode with `CSI ? 2004 h/l`, but `vpty` initially treated that as ordinary screen traffic. The real outer terminal never entered bracketed paste mode, so pasted text arrived as plain typed input and `nvim` behaved as if every newline were an interactive Enter key.

The lesson is simple:

> `vpty` is not only a screen renderer. It is also a control router between an inner PTY application and a real outer terminal.

---

## Problem statement

Applications running under `vpty` can emit terminal control traffic with very different semantic effects:

- **screen/model effects**: cursor movement, erases, SGR, scrolling, ordinary text
- **outer-terminal device effects**: bracketed paste mode, focus reporting, mouse reporting, clipboard, titles
- **extension negotiation**: hyperlinks, keyboard protocols, graphics protocols, etc.
- **queries/reports**: device reports or protocol round-trips that need special handling

Treating all of that as “screen bytes” is wrong.
Treating all of it as “pass-through” is also wrong.

The correct model is:

- parse terminal controls,
- classify by semantic effect,
- route according to explicit policy.

---

## Current confirmed lesson

The confirmed bug class was:

- `OSC 52` clipboard passthrough already existed,
- bracketed paste mode passthrough did not,
- `nvim` emitted `CSI ? 2004 h/l`,
- `vpty` swallowed those controls into the virtual path,
- the real terminal never wrapped pasted text with `CSI 200~` / `CSI 201~`,
- `nvim` received ordinary typed input instead of a bracketed paste block.

That means the existing “side effects = OSC 52 only” model is too narrow.

---

## Design goals

- Keep PTY transport independent from control classification.
- Keep terminal-model/render code independent from outer-terminal side effects.
- Make routing policy explicit and testable.
- Avoid one-off ad hoc fixes for each newly discovered control sequence.
- Support a staged implementation, starting with the controls we already know matter.
- Prefer a strict allowlist for side effects instead of broad family-level passthrough.

---

## Routing model

Each complete control unit should be assigned one of these dispositions:

```text
virtual_only
passthrough
passthrough_and_virtual
ignore
policy_error
```

### Meaning

- **virtual_only**: feed only to the terminal model / renderer
- **passthrough**: forward only to the real outer terminal
- **passthrough_and_virtual**: both sides should observe it
- **ignore**: intentionally suppress it
- **policy_error**: recognized but disallowed by configuration/policy

In practice today, `vpty` mostly needs `virtual_only` and `passthrough`.

---

## First-pass routing table

This is the practical routing table `vpty` should grow toward first.

### Virtual-only by default

These belong to the internal virtual terminal model and renderer:

- printable text / UTF-8 text output
- C0 text-flow controls used as screen data (`LF`, `CR`, `BS`, `TAB`, etc.)
- SGR (`CSI ... m`)
- cursor movement (`CSI A/B/C/D`, `CSI H`, `CSI f`, etc.)
- erases (`CSI J`, `CSI K`)
- insert/delete/scroll controls
- alt-screen ownership when virtualized by the renderer (`CSI ? 1049 h/l` and related variants)

### Pass-through by default

These affect the *real outer terminal device*, not the virtual screen model:

- bracketed paste mode
  - `CSI ? 2004 h`
  - `CSI ? 2004 l`
- focus reporting
  - `CSI ? 1004 h/l`
- mouse reporting modes
  - `CSI ? 1000 h/l`
  - `CSI ? 1002 h/l`
  - `CSI ? 1003 h/l`
  - `CSI ? 1005 h/l`
  - `CSI ? 1006 h/l`
  - `CSI ? 1015 h/l`
- paste-adjacent xterm input modes
  - `CSI ? 2005 h/l`
  - `CSI ? 2006 h/l`
- clipboard
  - `OSC 52`

### Policy-controlled

These should eventually be routed by explicit policy, not hardcoded forever:

- titles / icon titles
  - `OSC 0`
  - `OSC 1`
  - `OSC 2`
- hyperlinks
  - `OSC 8`
- cursor style / blinking cursor mode
  - `DECSCUSR` (`CSI Ps SP q`)
- modern extension protocols
  - kitty keyboard protocol
  - graphics protocols
  - other advanced OSC/DCS variants

### Ignore or deny by default

Until explicitly supported:

- unknown OSC
- unknown DCS
- unknown APC / PM / SOS
- advanced extension protocols not yet designed into `vpty`

---

## Key rule

Do **not** route by protocol family alone.

Bad rules:

- “all OSC passthrough”
- “all CSI virtual”
- “all DCS ignore”

Those are too coarse.

Instead:

- parse by family,
- classify by semantic meaning,
- route by explicit policy.

Examples:

- `OSC 52` -> passthrough
- `CSI ? 2004 h` -> passthrough
- `CSI J` -> virtual-only
- `CSI ? 1049 h` -> virtual-only when alt-screen is intentionally virtualized

---

## Proposed staged architecture

This should be implemented incrementally.

### Stage 0, current state

Current code has a small control splitter in `side_effects.zig` that now handles:

- `OSC 52`
- bracketed paste mode toggles (`CSI ? 2004 h/l`)

That is enough to fix the concrete `nvim` paste bug.

### Stage 1, near-term cleanup

Refactor `side_effects.zig` into a slightly more explicit local control router inside `vpty`.

Suggested local responsibilities:

- incremental parsing of `ESC`, `CSI`, `OSC`
- allowlisted passthrough for known outer-terminal controls
- screen-byte output for virtual-only controls
- conservative fallback for unsupported control-string families

Keep this local to `vpty` first.
Do **not** split into many files prematurely.

### Stage 2, structured routing split

Once the local model is stable, split it into clearer pieces such as:

- `control_parser`
- `control_classifier`
- `control_policy`
- `control_router`

At that point the code can become a reusable helper instead of a `vpty`-local utility.

### Stage 3, broader compatibility

Add more explicit support for:

- focus reporting
- mouse reporting
- title controls
- hyperlinks
- cursor style
- query/report classes
- optional extension protocols behind feature flags

---

## Proposed internal concepts

If/when the code is split more formally, these concepts are useful:

```zig
pub const ControlDisposition = enum {
    virtual_only,
    passthrough,
    passthrough_and_virtual,
    ignore,
    policy_error,
};

pub const ControlKind = enum {
    text,
    sgr,
    cursor_motion,
    erase,
    scroll,
    alt_screen,
    bracketed_paste_mode,
    focus_reporting,
    mouse_reporting,
    clipboard,
    title,
    hyperlink,
    cursor_style,
    query_or_report,
    unknown,
};
```

This is mainly a design aid today, not a requirement to implement immediately.

---

## Testing plan

Tests should be organized around semantic routing behavior, not only parser families.

### Unit tests

- `OSC 52` terminated by BEL -> passthrough
- `OSC 52` terminated by ST -> passthrough
- `CSI ? 2004 h` -> passthrough
- `CSI ? 2004 l` -> passthrough
- split-chunk CSI parsing for `?2004h/l`
- ordinary screen CSI such as `CSI J` stays virtual-only
- unknown CSI remains virtual-only unless explicitly allowlisted

### Integration tests

- `nvim` bracketed paste end-to-end
- OSC 52 clipboard copy end-to-end
- focus-reporting enable/disable once added
- mouse-reporting setup once added

---

## Recommended next implementation steps

1. Add a short comment/doc reference near `side_effects.zig` explaining that it is doing semantic control routing, not just OSC handling.
2. Add focused tests for:
   - `OSC 52`
   - `CSI ? 2004 h/l`
   - chunk-split control parsing
3. Extend the allowlist to likely outer-terminal controls next:
   - focus reporting
   - common mouse-reporting modes
4. Only then consider a fuller parser/classifier/policy/router split.

---

## Recommendation

Use this bug fix as the architectural pivot:

- keep the current narrow fix,
- document the routing table,
- grow the control router deliberately,
- avoid another round of one-off invisible terminal-control bugs.

The guiding principle is:

> route terminal controls by **semantic effect**, not only by protocol family.
