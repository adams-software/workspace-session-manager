# vpty

`vpty` is the virtual-terminal and rendering side of the repository.

It exists to make interactive session processes render and behave correctly when driven through the `msr` runtime.

## What lives here

- `src/` — terminal-state integration, rendering, and PTY-facing runtime code
- `scripts/` — package-local smoke/debug helpers
- `docs/` — specs and implementation notes related to terminal behavior

## Role in the repo

`vpty` is a support package for interactive session UX.

It is where terminal-specific complexity lives, including:

- PTY process wiring built on the shared `ptyio` host
- terminal state capture
- libvterm integration
- screen snapshotting and rendering

## Current status

This package is actively evolving and is more experimental than the core `msr` runtime.

In particular, terminal rendering behavior is still under active investigation and refinement.

## Developer notes

Build from the repo root:

```bash
zig build
```

The `vpty` binary is emitted to:

```text
zig-out/bin/vpty
```

A number of the docs in `docs/specs/` are working specs and design notes rather than finished public docs.

## Open-source posture

If this repo is published, `vpty` should be framed as:

- the terminal integration layer
- an implementation-heavy package
- an area where some rough edges and ongoing design work are expected
