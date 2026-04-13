# vpty

`vpty` is the virtual-terminal and rendering layer in this repository.

Use it when you want a terminal-aware wrapper around an interactive command.

## Quick usage

See the full command surface:

```bash
vpty --help
```

Run an interactive shell through `vpty`:

```bash
vpty -- bash
```

Run a TUI directly:

```bash
vpty -- nvim
```

## What lives here

- `src/` — terminal-state integration, rendering, and PTY-facing runtime code
- `scripts/` — package-local smoke/debug helpers
- `docs/` — specs and implementation notes related to terminal behavior

## Role in the repo

`vpty` is the terminal-heavy support package for interactive session UX.

It is where terminal-specific complexity lives, including:

- PTY process wiring built on the shared `ptyio` host
- terminal state capture
- libvterm integration
- screen snapshotting and rendering

## Current status

This package is still under active refinement, especially around terminal redraw and interaction behavior.

## Developer notes

Build from the repo root:

```bash
zig build
```

The `vpty` binary is emitted to:

```text
zig-out/bin/vpty
```

A number of the docs in `docs/` are still closer to working notes than polished public docs.
