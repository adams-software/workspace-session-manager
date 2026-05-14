# wsm

`wsm` is the workspace session manager layer in this repository.

If you are using the suite as an operator, this is the best place to start.

## Quick usage

Set a workspace root first, then see the command surface:

```bash
export WSM_ROOT=~/code
wsm --help
```

Create and attach to a workspace session:

```bash
wsm create api/dev -- bash
```

Reattach later:

```bash
wsm attach api/dev
```

View logs for a session:

```bash
wsm log api/dev
```

Inside an attached session, press `ctrl-g` to open the in-session action menu. Log viewing uses paired temporary sessions like `<session>.scroll` rather than the older `alt`-based prototype.

The paired logs path is backed by `scroll`, which can replay a transcript from a
path or stdin:

```bash
scroll /path/to/session.typescript
scroll --ansi /path/to/session.typescript
cat /path/to/session.typescript | scroll
```

When run with no input target from an interactive terminal, `scroll` shows its
help instead of waiting on stdin.

`wsm` now expects an explicit workspace root via `WSM_ROOT` or `--workspace`.
It should not silently treat the current directory as the workspace root.

## What lives here

- `scripts/` — shell helpers like log viewing, completion, and smoke coverage
- `docs/` — package-local documentation as the command surface matures

## Role in the repo

`wsm` sits above `msr`.

Conceptually:

- `msr` manages raw session sockets/processes
- `wsm` manages canonical session ids across a workspace tree

## Current status

This is now primarily a Zig package with a few supporting shell helpers.

## Developer notes

The main entrypoint is `zig-out/bin/wsm`.

For local development, source:

```bash
source shared/scripts/dev_env.sh
```

That puts repo-local binaries and scripts on `PATH`.
