# msr repo

This repository contains a small family of tools for creating, naming, navigating, and rendering interactive session-backed processes.

It is organized as a set of vertical packages that live in one repo.

## Package map

### `msr/`
Core session runtime.

Responsible for:
- creating sessions
- attaching/detaching
- status / wait / terminate operations
- core Zig implementation and CLI surface

### `dsm/`
Directory session manager.

Adds directory-local naming and lexical navigation on top of `msr`.

### `wsm/`
Workspace session manager.

Adds workspace-wide naming, lookup, and navigation across a directory tree.

### `vpty/`
Terminal integration and rendering layer.

Holds the PTY / terminal-state / rendering work needed for interactive sessions.

### `alt/`
Experimental alt-screen / launcher-oriented binary.

This package is intentionally more experimental than the main runtime path.

### `shared/`
Small cross-cutting package for truly shared code and scripts.

Currently this is intentionally narrow.

## Repo layout

Each package owns its own local structure where relevant:

- `src/` — implementation
- `scripts/` — operator/dev/smoke scripts
- `docs/` — package-local docs and specs

The repo uses a **vertical slice** layout rather than grouping everything by file type at the top level.

## Build

Build from the repo root:

```bash
zig build
```

Artifacts are emitted to:

```text
zig-out/bin/
```

Current binaries include:

- `zig-out/bin/msr`
- `zig-out/bin/vpty`
- `zig-out/bin/alt`

## Development shell

To expose repo-local binaries and helper scripts in your shell:

```bash
source shared/scripts/dev_env.sh
```

That adds the repo-local binary/script paths to `PATH` for the current shell only.

## Current maturity

This repo is still under active development.

A practical way to think about current maturity is:

- `msr` — core runtime / conceptual center
- `dsm`, `wsm` — operator convenience layers
- `vpty` — active terminal/rendering subsystem
- `alt` — experimental

Expect some churn while the public surface settles.

## Notes for open source

This repo is being groomed toward a cleaner public GitHub release, but some areas are still closer to active engineering workspace than polished product docs.

If you are exploring the repo for the first time, start with:

- this root README
- `msr/README.md`
- `dsm/README.md`
- `wsm/README.md`
- `vpty/README.md`
