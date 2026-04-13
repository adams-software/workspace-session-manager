# msr

`msr` is a small family of tools for creating, naming, navigating, and rendering interactive session-backed processes.

The repo is intentionally split into vertical packages that can evolve at different speeds without hiding how the stack fits together.

## Package map

### `msr/`
Core session runtime.

Responsible for:
- creating sessions
- attaching and detaching
- status / wait / terminate operations
- the core Zig runtime and CLI surface

### `dsm/`
Directory session manager.

Adds directory-local naming and lexical navigation on top of `msr`.

### `wsm/`
Workspace session manager.

Adds workspace-wide naming, lookup, and navigation across a directory tree.

### `vpty/`
Terminal integration and rendering layer.

Holds the PTY / terminal-state / rendering work needed for interactive interactive sessions.

### `alt/`
Experimental PTY switcher.

Runs a primary side and an alternate side on separate PTYs behind a local hotkey.

### `shared/`
Small cross-cutting package for truly shared code and scripts.

### `ptyio/`
Low-level PTY / stream / tty helpers shared by runtime-facing packages.

## How the pieces fit together

A practical mental model is:

- `msr` is the core session runtime
- `dsm` adds local naming and navigation
- `wsm` adds workspace-wide naming and navigation
- `vpty` makes interactive terminal sessions render well
- `alt` is an experimental operator-facing switcher layered on top

If you are trying to understand the repo quickly, start with:

1. this root README
2. `msr/README.md`
3. `dsm/README.md`
4. `wsm/README.md`
5. `vpty/README.md`
6. `alt/README.md`

## Current maturity

This repo is active engineering work, not a frozen product surface.

A practical current read is:

- `msr` — core runtime / conceptual center
- `dsm` and `wsm` — operator convenience layers
- `vpty` — implementation-heavy terminal subsystem under active refinement
- `alt` — experimental but usable

Expect some churn while the public surface settles.

## Build

Build from the repo root:

```bash
zig build
```

Run tests from the repo root:

```bash
zig build test
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

That adds repo-local binaries and scripts to `PATH` for the current shell only.

## Open-source posture

The repo is being prepared for a cleaner public GitHub release.

The current approach should be:

- publish the real structure honestly
- keep experimental areas clearly labeled
- provide practical build/test/docs first
- harden distribution and release automation later
