# VPty Renderer Layer Spec

## Summary

The renderer is the layer between:

* **terminal core**: PTY input + libvterm state
* **outer terminal**: stdout / host PTY

Its job is to take the current virtual terminal state and produce a stable, correct visual representation on the outer terminal.

The renderer is **state-faithful, not byte-faithful**. It does not replay the child’s original escape stream. It renders the current terminal state maintained by libvterm.

This layer exists to make rendering principled, testable, and robust, instead of ad hoc.

---

## Goals

The renderer must:

* render the child’s current visible terminal state to the outer terminal
* preserve stable cursor behavior
* support repaint after normal output and resize
* support a full repaint path at any time
* be independent from session logic, control UI, and attach/detach semantics
* centralize terminal-domain mapping such as glyph output, cursor handling, and row clearing

---

## Non-goals

Phase 1 renderer does not aim to:

* preserve the child’s original byte stream
* perfectly emulate every native-terminal edge case
* support terminal title setting
* support clipboard / OSC features
* support bells, hyperlinks, or advanced terminal integration
* optimize for minimal output at all costs

Correctness and stability come before minimal repaint size.

---

## Layer boundaries

### Inputs to renderer

The renderer receives:

* current visible screen state
* current cursor state
* visible terminal modes relevant to presentation
* damage information
* target outer size

It does **not** receive raw PTY bytes directly.

### Outputs from renderer

The renderer produces:

* terminal bytes written to the outer terminal
* a deterministic final cursor position and visibility state

### Ownership

The renderer owns:

* repaint policy
* cursor-hide / repaint / cursor-restore sequence
* row clearing behavior
* glyph emission
* style/SGR emission
* full repaint fallback

The terminal core owns:

* feeding PTY bytes into libvterm
* collecting damage
* resizing libvterm
* child PTY management

The client/runtime owns:

* attach/detach
* session switching
* control UI
* transport lifecycle

---

## Core invariant

At the end of every render pass, the outer terminal must visually reflect the current libvterm screen state, and the outer cursor must match the virtual cursor state.

This is the most important invariant.

---

## Renderer model

The renderer should be structured in two stages:

1. **Plan**

   * inspect current state
   * determine what must be repainted
   * build a render plan

2. **Emit**

   * write terminal bytes to realize that plan
   * leave terminal in the correct final state

This separation is required.

It prevents rendering logic from becoming tightly coupled to byte emission and makes testing much easier.

---

## Render plan

A render plan is an internal representation of one render pass.

At minimum it contains:

* render kind:

  * no-op
  * dirty-row repaint
  * full repaint
* rows to repaint
* for each row:

  * row index
  * cell runs or text runs
  * whether clear-to-end-of-line is required
* final cursor row/col
* final cursor visibility
* any screen-wide preparation:

  * hide cursor
  * clear screen for full repaint

The plan is internal and not user-visible.

---

## Phase 1 rendering policy

Phase 1 must use a conservative repaint strategy.

### Triggering repaint

A render pass occurs:

* after draining available PTY output into libvterm
* after resize
* after an explicit internal full repaint request

Rendering must not happen directly from libvterm callback paths.

Callbacks only update state and mark damage.

### Minimum repaint granularity

Phase 1 repaint granularity is:

* **whole dirty rows**

Not per-cell patching.

### Full repaint fallback

A full repaint path must always exist.

It may be used:

* on startup
* after resize
* after terminal desync suspicion
* after explicit refresh
* when dirty tracking is uncertain

---

## Cursor policy

Cursor handling must be explicit and consistent.

### Render sequence

Every repaint pass must follow this pattern:

1. hide cursor
2. perform repaint operations
3. move cursor to final virtual cursor position
4. restore cursor visibility state

This is required even for row-based repaint.

### Cursor ownership

The renderer owns the outer terminal cursor during repaint.

It must not assume the outer cursor is already in any useful position.

Every row write must be preceded by explicit cursor positioning.

### Cursor visibility

The renderer must respect virtual cursor visibility.

If the virtual cursor is hidden, the outer cursor must be hidden at end of frame.

If visible, the outer cursor must be visible at the correct final position.

---

## Row repaint policy

For each dirty row:

1. explicitly move cursor to start of the row
2. emit row contents
3. clear to end of line if needed

The renderer must never assume trailing characters from a previous frame are harmless.

If the logical row has become shorter, stale visible content must be removed with clear-to-end-of-line or equivalent.

---

## Cell and glyph policy

The renderer renders from libvterm cell state, not from raw PTY text slices.

### Rule

The renderer must emit the **final visible glyphs** for each cell.

It must not assume the outer terminal is carrying forward the same charset state or source escape semantics as the child.

This is especially important for:

* line drawing
* ACS / special graphics
* wide characters
* combining characters

### Phase 1 expectation

Phase 1 should aim for correct rendering of:

* normal text
* spaces
* wide characters as represented by libvterm
* combining characters as represented by libvterm
* common border / line-drawing glyphs

If additional mapping is needed for special graphics, that belongs in the renderer as normal glyph mapping logic, not as application-specific hacks.

---

## Style policy

Phase 1 style support should be explicitly limited.

Recommended minimum:

* reset
* bold if easy
* underline if easy
* foreground/background colors if practical
* inverse if practical

If style support is incomplete in phase 1, the renderer must still preserve usable text and layout.

Layout correctness is higher priority than full styling fidelity.

---

## Alt-screen policy

Phase 1 should support visible behavior that remains usable when applications use alternate screen mode.

Minimum requirement:

* whatever is currently visible in libvterm should be what gets rendered

The renderer does not need separate complex policy for alt-screen beyond faithfully rendering current visible state.

If libvterm exposes alt-screen state in a useful way, it may be tracked, but phase 1 does not need special UI behavior around it.

---

## Resize policy

On resize:

1. outer terminal size change is detected
2. terminal core updates child PTY size
3. terminal core updates libvterm size
4. renderer performs a full repaint

Resize must always trigger a full repaint in phase 1.

Do not attempt partial repaint after resize.

---

## Refresh policy

Phase 1 refresh is event-driven.

The renderer repaints on:

* PTY output
* resize
* explicit internal full repaint request

Manual user-triggered refresh is optional and may be deferred.

The renderer must still expose an internal full repaint entry point.

---

## Damage policy

libvterm callbacks may report damage, cursor movement, scrolling, or other updates.

In phase 1:

* callbacks update internal state
* callbacks mark dirty rows or full repaint
* callbacks do not write to the outer terminal

The renderer consumes accumulated damage only when a render pass begins.

This is required to prevent callback-driven interleaving and cursor instability.

---

## Output batching policy

The renderer should emit a frame after ingesting a batch of available PTY data, not after every tiny read fragment if avoidable.

The goal is to avoid visible churn from partial intermediate terminal states.

A reasonable phase 1 policy is:

* read and ingest available PTY bytes
* then render once

Not:

* read tiny chunk
* render
* read tiny chunk
* render
* repeat excessively

---

## Terminal mode assumptions

The renderer assumes it owns the outer terminal presentation while VPty is active.

It may use standard terminal control sequences for:

* cursor movement
* cursor visibility
* erase in line
* screen clear for full repaint
* SGR styling

The renderer must not depend on the outer terminal preserving opaque prior state that VPty did not explicitly establish during the current frame.

---

## Failure model

If the renderer becomes uncertain that its dirty-state model is still correct, it must choose full repaint.

Correctness beats micro-optimization.

Examples of when full repaint is acceptable:

* after resize
* after internal error in damage tracking
* after unknown terminal-state transition
* after manual refresh
* during early implementation phases

---

## Testing requirements

The renderer should be testable separately from the PTY host.

At minimum, tests should cover:

* whole-row repaint correctness
* stale trailing content removal
* final cursor position
* final cursor visibility
* full repaint correctness
* resize triggers full repaint
* line-drawing / border glyph rendering
* wide-character row behavior
* combining-character row behavior
* basic style reset behavior

The key thing to test is not just emitted bytes, but final expected visible state and cursor state.

---

## Debugging hooks

The renderer should support internal debugging helpers such as:

* force full repaint
* dump render plan
* dump dirty rows
* dump final cursor state
* dump row cell contents before emission

These are implementation aids, not product features.

---

## Phase 1 implementation guidance

Recommended first implementation:

* row-based renderer
* full repaint fallback always available
* hide cursor during repaint
* explicit cursor positioning before each row
* clear-to-end-of-line where needed
* restore final cursor state
* batch PTY input before rendering
* basic styles only
* no title/OSC support
* no hyper-optimized patch renderer

This is the safest path to stable behavior.

---

## Future phases

Possible later improvements:

* finer-grained dirty regions
* better style fidelity
* improved glyph/ACS handling
* smarter diffing between previous and current rendered rows
* output minimization
* terminal capability abstraction
* renderer backends for different output targets

These are future optimizations, not phase 1 requirements.

---

## Engineering acceptance criteria

The renderer is acceptable when:

* interactive apps no longer show obvious cursor thrash during normal use
* row updates do not leave stale visible content behind
* full-screen apps remain visually coherent under normal interaction
* common bordered UI elements render as borders, not raw source glyph letters
* resize causes stable repaint
* final cursor placement is consistent and predictable

---

## One-sentence contract

The renderer is a deterministic layer that converts libvterm’s current virtual terminal state into a stable outer-terminal presentation, with explicit cursor ownership, row-based repaint semantics, and full repaint fallback.


# Update plan
You’re not wildly off. The core shape is there, but the rendering path is still too snapshot-centric and too lossy in a few key places.

The biggest good sign is that you already have the right high-level loop:

* drain PTY bytes
* feed them into the host/vterm side with `observePtyOutput`
* ask for a screen snapshot
* render from previous snapshot to current snapshot 

That is the correct architectural direction.

Where it is still weak is mostly in the renderer contract and the fidelity of the shim data you are feeding into it.

## What looks good already

Your current renderer already does a few important things right:

* hides the cursor during repaint
* row-diffs against the previous snapshot
* repaints whole rows, not ad hoc cell fragments
* restores cursor position/visibility at the end of frame 

That is not a bad MVP at all. It means you are past the “totally wrong architecture” stage.

## The main problems I see

### 1. `alt_screen` is effectively broken right now

Your renderer toggles `?1049h` / `?1049l` based on `snapshot.alt_screen`, but your shim currently returns `0` unconditionally from `msr_vterm_get_alt_screen`. So the render layer is trying to honor alt-screen, but the shim never reports it correctly. 

That means one whole part of the renderer contract is fake right now.

### 2. Cursor visibility is effectively fake too

`msr_vterm_get_cursor` always sets `visible = 1`. So your final cursor restore logic is operating on incomplete state. 

This can absolutely contribute to weird interactive behavior.

### 3. Cell extraction is too text-oriented

You have both:

* `msr_vterm_get_cell_codepoint`
* `msr_vterm_get_cell_text`
* `msr_vterm_get_cell_style`

but the text path uses `vterm_screen_get_text` over a 1-cell rect. That is a red flag for a renderer that wants cell-faithful output, especially around ACS, wide chars, combining chars, and continuation cells. 

That lines up with the “bbbb borders” symptom you saw.

### 4. The renderer is stateless in the wrong place

Right now `renderFrame` only compares `prev` and `snapshot`, then directly emits terminal bytes. There is no explicit render-plan layer, no target terminal model, and no place to centralize normalization logic. 

That is why fixes are starting to feel ad hoc: there is nowhere principled to put them.

### 5. Style emission is correct-ish but expensive and coarse

`emitStyle` always starts with `\x1b[0m` and then reapplies everything. That is okay for correctness-first, but it means every style transition is a hard reset. It is probably not your main bug, but it does make the renderer more brute-force than it needs to be. 

### 6. You are still missing a true renderer-owned terminal state model

Right now the output side assumes the outer terminal will tolerate:

* cursor hide
* row rewrites
* `K`
* cursor restore

and that is fine for a first pass, but there is no explicit notion of:

* what outer mode we believe is active
* whether alt-screen is currently entered
* what cursor visibility we think we left it in
* whether a full repaint is needed because state trust was lost

So the renderer has no “trust boundary.”

## How far off are you?

I’d say:

* **architecture**: 70% right
* **renderer discipline**: 40% right
* **shim fidelity**: 30% right
* **terminal correctness for interactive TUIs**: still early

That is actually pretty decent progress. The main issue is not that the whole thing is wrong. It is that you now need to promote the renderer from “helper functions” into “a real subsystem.”

## The plan I’d recommend

## Phase 1: fix the shim contract first

Before doing fancy renderer work, make the shim truthful.

### A. Stop lying about alt-screen

Implement real alt-screen reporting instead of always returning `0`. Right now your renderer is wired for a feature it cannot actually observe. 

### B. Stop lying about cursor visibility

Return actual visibility if libvterm exposes it; if not, explicitly mark it unsupported in the host snapshot model rather than forcing `1`. 

### C. Add a richer cell API

Do not build the renderer primarily around `get_cell_text` with `vterm_screen_get_text` on a 1-cell rect. That is too lossy. Prefer a single shim call that returns a full normalized cell description from `VTermScreenCell`, including:

* primary chars/codepoints
* width
* style attrs
* maybe a small enum for special/continuation states

That will give the renderer a much sounder input surface.

## Phase 2: split rendering into plan + emit

Right now `renderFrame` does diffing and byte emission inline. Split it into:

### `buildRenderPlan(prev, snapshot) -> RenderPlan`

Contains:

* full repaint vs dirty rows
* which rows to paint
* final cursor row/col
* final cursor visibility
* screen mode transition info like alt-screen change

### `emitRenderPlan(plan)`

Contains:

* hide cursor
* mode transitions
* row writes
* clear EOL
* restore cursor
* restore visibility

That gives you one place for terminal-output policy and one place for state reasoning.

## Phase 3: normalize row rendering around cells, not strings

Today `paintRow` just writes `cell.text` cell by cell. 

I would change the renderer’s conceptual unit from “text blobs” to “display cells.” Then add a row encoder that converts cells into output runs.

That row encoder should own:

* glyph choice
* continuation-cell skipping rules
* wide-char handling
* ACS/box-drawing mapping if needed
* style run grouping

This is where your “true rendering layer” really starts existing.

## Phase 4: add a minimal output-state tracker

Do not go overboard, but track at least:

* whether we believe outer alt-screen is active
* whether cursor is visible
* last known cursor position if useful
* whether we trust incremental repaint or must full-repaint next frame

This lets you avoid implicit assumptions.

## Phase 5: tighten the main loop batching a bit

Your loop already drains available PTY bytes before snapshot/render, which is good. 

I’d keep that, but make one explicit invariant:

> one render pass per drained PTY batch, never render from callback paths, never mix partial render output with ongoing input ingestion

That should stay as a hard rule.

## Concrete changes I would make first

In order:

1. **Implement real `alt_screen` reporting**
2. **Implement real cursor visibility reporting**
3. **Replace per-cell `get_text` usage with a richer cell-struct path**
4. **Introduce `RenderPlan`**
5. **Keep row-based repaint, but make row encoding cell-aware**
6. **Add a renderer-owned “full repaint required” flag**
7. **Only after that, optimize style diffs/output size**

## What I would not do yet

* fine-grained cell patching
* terminal capability abstraction
* special case Neovim directly
* try to emulate the original escape stream
* add app-specific hacks in `paintRow`

If you do that now, you will just accumulate renderer debt.

## My read of the current code in one sentence

You already have the right outer control loop and a usable row-diff repaint core, but the renderer is still operating on incomplete terminal state and a lossy cell interface, which is why interactive apps are exposing correctness gaps. 

## Suggested next engineering milestone

I’d define the next milestone as:

> “Make the snapshot/shim/render boundary truthful and explicit.”

That means:

* truthful snapshot fields
* truthful cell model
* render plan abstraction
* row encoder abstraction

Once that exists, the weird bugs become renderer bugs instead of “mysterious terminal behavior.”
