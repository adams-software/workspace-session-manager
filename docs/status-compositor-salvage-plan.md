# status-compositor salvage plan

This branch should be treated as an **experiment checkpoint**, not a merge candidate.

## Goal

Preserve the current `status-compositor` branch state as a coherent archive commit, then port only the worthwhile `vpty` improvements back onto a fresh branch from `main`.

## Recommended workflow

### 1. Checkpoint the experiment branch

On `status-compositor`, commit the currently staged changes as a single checkpoint commit.

Suggested commit message:

```text
status: checkpoint compositor experiment state
```

This commit is meant to:
- preserve the current branch state
- keep the recent bug fixes together with the experiment they belong to
- avoid losing work while abandoning or pausing the broader architecture

This branch should remain a reference/archive branch.

### 2. Do not merge `status-compositor` into `main`

The branch contains substantial experiment-specific machinery that should not be carried wholesale into `main`.

## What to leave on `status-compositor`

These are considered experiment-specific unless a later targeted extraction proves otherwise:

- `status/src/main.zig`
- `status/src/pane_runtime.zig`
- `status/src/status_cli.zig`
- `status/src/pane_child_adapter.zig`
- `status/src/status_layout.zig`
- deletion/replacement of `status/src/status_compose.zig`
- startup materialization rules
- compositor-specific focus/freeze policy
- synthetic pane composition/runtime behavior
- local-model transitional scaffolding in `status`

## Primary salvage candidates for `main`

These files are the best starting point for port-back work:

- `vpty/src/vpty_render.zig`
- `vpty/src/actor_mailboxes.zig`
- `vpty/src/stdout_actor.zig`
- `vpty/src/stdout_thread.zig`

### What to look for in those files

Port only hunks that improve one or more of:

- viewport/render batch invariants
- final cursor discipline / explicit final-frame behavior
- clearer ownership boundaries
- actor/stdout/render-thread correctness or simplification
- behavior that is independently valuable outside `status-compositor`

Do **not** port hunks that only exist to support the status experiment’s host policy.

## Recommended port-back procedure

### A. Create a fresh branch from main

Example:

```bash
git switch main
git pull
git switch -c vpty-salvage
```

### B. Diff file-by-file against `status-compositor`

Use either:

```bash
git diff main..status-compositor -- vpty/src/vpty_render.zig
git diff main..status-compositor -- vpty/src/actor_mailboxes.zig
git diff main..status-compositor -- vpty/src/stdout_actor.zig
git diff main..status-compositor -- vpty/src/stdout_thread.zig
```

or interactive checkout/cherry-pick approaches.

### C. Port in small commits

Suggested split:

1. mailbox / thread cleanup
2. render invariant hardening
3. cursor/final-frame cleanup (if it generalizes)

### D. Test after each commit

At minimum:

```bash
zig build test
```

## Branch intent summary

- `status-compositor`: archive/reference checkpoint of the experiment
- `main`: receives only distilled `vpty` improvements
- no wholesale merge from experiment branch into `main`

## Notes from the experiment

The main architectural lesson appears to be:
- host-side cleanup was productive
- producer-side replacement never fully happened
- the local terminal model / synthetic producer path remained and is likely the main performance bottleneck

That means the best code to salvage is probably the `vpty` invariant/ownership work, not the `status` host experiment itself.
