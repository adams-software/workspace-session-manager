# wsm

`wsm` is the workspace session manager layer in this repository.

If you are using the suite as an operator, this is the best place to start.

## Quick usage

See the full command surface:

```bash
wsm --help
```

Create and attach to a workspace session:

```bash
wsm create -a api/dev -- bash
```

Reattach later:

```bash
wsm attach api/dev
```

Open the interactive menu:

```bash
wsm menu
```

## What lives here

- `scripts/` — the `wsm` command, interactive menu flow, completion, and smoke coverage
- `docs/` — package-local documentation as the command surface matures

## Role in the repo

`wsm` sits above `dsm` and `msr`.

Conceptually:

- `msr` manages raw session sockets/processes
- `dsm` manages session names within a directory
- `wsm` manages canonical session ids across a workspace tree

## Current status

This is a script-first package.

Today, most of its behavior lives in shell scripts rather than Zig code. That is intentional.

## Developer notes

The main entrypoints are:

- `wsm/scripts/wsm`
- `wsm/scripts/wsm_menu`

For local development, source:

```bash
source shared/scripts/dev_env.sh
```

That puts repo-local binaries and scripts on `PATH`.
