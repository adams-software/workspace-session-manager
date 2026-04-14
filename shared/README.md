# shared

`shared` contains cross-cutting assets that are used by more than one package in this repository.

## What lives here

- `src/` — shared source files that do not currently belong cleanly to a single vertical package
- `scripts/` — shared developer/operator helpers used across the repo

## Current contents

At the moment this package is intentionally small.

It currently exists to hold:

- `host.zig` in `src/`
- the shared development environment script in `scripts/`

## Design intent

This package should stay narrow.

Use it when something is truly cross-cutting, not just temporarily inconvenient to place elsewhere.

If a file has a natural package owner (`msr`, `vpty`, `wsm`, or `alt`), it should live there instead.

## Open-source posture

If this repo is published, `shared` should be understood as a support package, not a dumping ground.
