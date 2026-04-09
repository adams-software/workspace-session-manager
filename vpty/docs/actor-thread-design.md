## vpty actorized redesign, tightened

### Core invariants

These are the non-negotiables:

* PTY output must always be drained.
* PTY input progress must not depend on rendering progress.
* Control output is durable and ordered.
* Render output is replaceable and coalescible.
* TerminalModel is the authoritative screen state.
* Visual assumptions advance only on **committed stdout progress**, not on render generation.

That last one is the new piece we should make first-class.

---

## Components

### 1. InputPump

Responsibility:

* read stdin
* queue/write bytes to PTY input
* handle PTY write backpressure

It does not know about:

* libvterm
* rendering
* stdout
* committed frame state

### 2. PtyOutputPump

Responsibility:

* always drain PTY master
* split output into:

  * durable control side effects
  * screen bytes
* send control to `StdoutActor`
* feed screen bytes into `TerminalModel`

It must never pause PTY drainage just because stdout or rendering is behind.

That is the architectural protection against the class of lockups you’ve been hitting.

### 3. TerminalModel

This should be explicitly non-rendering.

Responsibility:

* own libvterm
* own terminal state
* own dirty markers / version counter
* expose read access to current model state
* accept resize and screen-byte updates

It should not know anything about:

* diffs
* output bytes
* stdout
* queueing policy
* committed render state
* pending render frames

Suggested shape:

```zig id="8ar2b3"
const TerminalModel = struct {
    version: u64,
    dirty: bool,
    full_redraw_needed: bool,

    pub fn feedScreenBytes(self: *TerminalModel, bytes: []const u8) ModelUpdate { ... }
    pub fn resize(self: *TerminalModel, rows: u16, cols: u16) ModelUpdate { ... }
    pub fn snapshot(self: *const TerminalModel, allocator: Allocator) !ScreenSnapshot { ... }
    pub fn currentVersion(self: *const TerminalModel) u64 { ... }
};
```

Where:

```zig id="b1azk2"
const ModelUpdate = struct {
    version: u64,
    dirty: bool,
    full_redraw_needed: bool,
};
```

### 4. RenderActor

Responsibility:

* observe newest model version
* compare against **committed render version**
* produce a frame candidate for the newest useful version
* publish that candidate to `StdoutActor`

Important wording change:
it publishes **frame candidates**, not authoritative frames.

Those candidates are disposable until committed by stdout.

### 5. StdoutActor

Single owner of stdout.

Responsibilities:

* serialize durable control output
* manage one replaceable render candidate
* flush bytes to stdout
* track what render version has actually been committed

This actor needs explicit committed-state tracking.

Suggested shape:

```zig id="7vh2kt"
const StdoutActor = struct {
    control_queue: ByteQueue,
    pending_render: ?RenderCandidate,
    committed_render_version: u64,
};
```

And:

```zig id="q4n1xf"
const RenderCandidate = struct {
    version: u64,
    bytes: []u8,
    offset: usize,
};
```

Semantics:

* `control_queue` is FIFO and durable.
* `pending_render` is replaceable.
* `committed_render_version` advances only when the full render candidate has actually been written.

That prevents the old bug where internal visual assumptions get ahead of physical stdout.

---

## The key distinction: pending vs committed

We should name these explicitly.

### Pending render candidate

A possible future screen state that has been synthesized but not fully written.

### Committed render version

The newest render version known to be fully emitted to stdout.

The renderer should diff from committed state, not from merely generated state.

That means the system now has three distinct notions:

* **model version**: what TerminalModel currently knows
* **pending render version**: what StdoutActor may be in the middle of flushing
* **committed render version**: what the real outer terminal has definitely received

That separation is the conceptual fix.

---

## Dataflow

Tightened pipeline:

```text id="ngk1s0"
stdin -> InputPump -> PTY child input

PTY child output -> PtyOutputPump
  -> control messages -> StdoutActor.control_queue
  -> screen bytes -> TerminalModel(version++)
                   -> RenderActor notified

RenderActor
  -> reads TerminalModel snapshot/version
  -> compares against StdoutActor.committed_render_version
  -> publishes latest RenderCandidate

StdoutActor
  -> flush control FIFO in order
  -> flush current RenderCandidate
  -> on full candidate completion:
       committed_render_version = candidate.version
```

---

## Writer policy

This is where the bug class gets removed.

### Control policy

For OSC 52 and similar:

* durable
* ordered
* never dropped

### Render policy

For screen redraw:

* latest wins
* stale candidates may be replaced before commit
* old render history is irrelevant

If versions `101`, `102`, `103` are generated while stdout is behind, it is fine to drop `101` and `102` and eventually commit `103`.

That is not data loss in the meaningful sense. It is correct coalescing of view state.

---

## Single-threaded first implementation

I agree with your recommendation: do not jump to threads immediately.

The first implementation should be actor-shaped but still single-threaded.

That means:

* explicit components
* explicit inbox/queue boundaries
* explicit pending vs committed state
* still one scheduler loop

So the first loop becomes something like:

```text id="7x6n79"
step stdin actor
step pty output actor
step render actor
step stdout actor
step lifecycle/resize actor
```

But each step uses strict local state and explicit handoff, not shared ad hoc behavior.

This validates the architecture before concurrency is introduced.

---

## Concrete Phase 1 plan

### Step 1: extract TerminalModel

Move libvterm ownership and version/dirty tracking behind one boundary.

Remove all render-policy concerns from it.

### Step 2: replace OutputSink with StdoutActor state

Instead of append-only segment history, introduce:

* `control_queue`
* `pending_render`
* `committed_render_version`

### Step 3: change renderer contract

Renderer no longer “appends bytes.”
It returns a `RenderCandidate { version, bytes }`.

### Step 4: make stdout actor authoritative for commit

Only stdout actor updates `committed_render_version`.

### Step 5: keep PTY drain unconditional

No stdout/render condition should ever suppress PTY drainage.

### Step 6: make render generation opportunistic

If stdout is behind, renderer may skip intermediate model versions and generate only the newest candidate.

---

## Suggested local file structure

Keep it local to `vpty` for now.

```text id="bj8hc5"
vpty/
  main.zig

  input_pump.zig
  pty_output_pump.zig
  terminal_model.zig
  render_actor.zig
  stdout_actor.zig
  osc_splitter.zig
  renderer.zig
  terminal_mode.zig
```

No generic runtime package yet.

If the pattern proves itself later, then you can extract something reusable.

---

## Pseudocode skeleton

### PtyOutputPump

```zig id="2qdkji"
fn stepPtyOutput(self: *PtyOutputPump, model: *TerminalModel, stdout: *StdoutActor) !void {
    while (pty readable) {
        const chunk = try readPty(...);
        const split = try splitter.feed(chunk);

        if (split.control.len > 0) {
            try stdout.enqueueControl(split.control);
        }

        if (split.screen.len > 0) {
            _ = model.feedScreenBytes(split.screen);
        }
    }
}
```

### RenderActor

```zig id="9qjiyl"
fn stepRender(self: *RenderActor, model: *TerminalModel, stdout: *StdoutActor) !void {
    const model_version = model.currentVersion();
    const committed = stdout.committedRenderVersion();

    if (model_version <= committed) return;
    if (!model.isDirty()) return;

    const snapshot = try model.snapshot(...);
    const candidate = try renderer.buildCandidate(snapshot, committed);
    try stdout.publishRenderCandidate(candidate);
}
```

### StdoutActor

```zig id="im7tb4"
fn stepStdout(self: *StdoutActor) !void {
    try self.flushControlQueue();

    if (self.pending_render) |*r| {
        try self.flushRenderCandidate(r);
        if (r.offset == r.bytes.len) {
            self.committed_render_version = r.version;
            self.pending_render = null;
        }
    }
}
```

---

## Decision rule

I’d use this as the practical rule for every design question going forward:

**If a choice risks coupling PTY drainage to render/stdout progress, it is wrong.
If a choice treats historical redraw bytes as durable state, it is wrong.**

That rule should keep you out of this bug family.

---

## Bottom line

I think the right immediate target is not “fix paste in current monolith.”
It is:

* extract `TerminalModel`
* replace `OutputSink` with `StdoutActor`
* add `committed_render_version`
* change render from append-only history to replaceable candidate
* keep the first version single-threaded

That gives you the architecture you were intuitively reaching for, without overcommitting to generic infrastructure too early.
