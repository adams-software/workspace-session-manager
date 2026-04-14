# alt

`alt` is a PTY switcher in this repository.

Use it when you want to switch between a primary side and an alternate side behind a local hotkey.

## Quick usage

See the full command surface:

```bash
alt --help
```

Run a primary shell with a secondary shell behind the hotkey:

```bash
alt --run /bin/bash --signal-2 TERM -- vpty -- bash
```

The hotkey spec is controlled by `--key <spec>` or `ALT_KEY=<spec>`. The default is `ctrl-g`.

```bash
alt --key ctrl-g --run /bin/bash --signal-2 TERM -- vpty -- bash
ALT_KEY=ctrl-g alt --run /bin/bash --signal-2 TERM -- vpty -- bash
```

## What lives here

- `src/` — the Zig implementation for the `alt` binary
- `docs/` — package-local notes as the tool matures

## Role in the repo

`alt` is an operator-facing PTY switcher layered on top of the main runtime and terminal stack.

## Current status

This package is part of the intended tool suite and is still receiving UX and behavior refinement.

## Developer notes

Build from the repo root:

```bash
zig build
```

The `alt` binary is emitted to:

```text
zig-out/bin/alt
```
