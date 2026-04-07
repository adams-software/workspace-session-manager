# alt

`alt` is an experimental alt-screen / launcher-oriented tool in this repository.

It is currently a spike-level package: useful enough to keep in-repo, but not yet presented as a stable surface.

## What lives here

- `src/` — the Zig implementation for the `alt` binary
- `docs/` — package-local notes as the tool matures

## Role in the repo

`alt` is intentionally separate from the main `msr` and `vpty` paths so it can evolve without forcing premature structure on the more established packages.

## Current status

This package is early.

Expect:

- behavior changes
- code movement
- possible redesign as its role becomes clearer

## Developer notes

Build from the repo root:

```bash
zig build
```

The `alt` binary is emitted to:

```text
zig-out/bin/alt
```

## Open-source posture

If this repo is published soon, `alt` should be described as experimental.

That keeps expectations honest while still making the work visible.
