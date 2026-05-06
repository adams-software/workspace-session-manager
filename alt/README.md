# alt

`alt` is a minimal control-driven PTY switcher in this repository.

It runs a primary command and an alternate command on separate PTYs. One side is active at a time. A small control socket drives switching.

## Quick usage

See the full command surface:

```bash
alt --help
```

Run a primary shell with a secondary shell as the alternate side:

```bash
alt --control /tmp/test.alt --run /bin/bash -- bash
```

Control it from another terminal:

```bash
python3 alt/scripts/control_client.py /tmp/test.alt help state
python3 alt/scripts/control_client.py /tmp/test.alt "switch 1"
python3 alt/scripts/control_client.py /tmp/test.alt cycle exit
```

## Control commands

- `help`
- `state`
- `switch <index>`
- `cycle`
- `exit`

`state` reports the active side and basic runtime state for both screens.

## What lives here

- `src/` — the Zig implementation for the `alt` binary
- `scripts/` — temporary/manual control helpers used during iteration
- `docs/` — package-local notes as the tool matures

## Role in the repo

`alt` is a small PTY-side switcher. It is not intended to be the mandatory backbone for normal `wsm attach` flow.

## Current status

This package now has a working control-socket-driven checkpoint and is still being simplified and hardened.

## Developer notes

Build from the repo root:

```bash
zig build
```

The `alt` binary is emitted to:

```text
zig-out/bin/alt
```
