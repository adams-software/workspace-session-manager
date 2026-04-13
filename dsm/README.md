# dsm

`dsm` is the directory session manager layer in this repository.

Use it when you want local session names and navigation within a single directory, without the full workspace-wide layer.

## Quick usage

See the full command surface:

```bash
dsm --help
```

Create and attach to a named local session:

```bash
dsm create -a demo -- bash
```

Reattach later:

```bash
dsm attach demo
```

Check the current local session:

```bash
dsm current
```

## What lives here

- `scripts/` — the `dsm` command, completion, and smoke coverage
- `docs/` — package-local docs as the command surface evolves

## Role in the repo

`dsm` sits between the raw runtime and the workspace-wide UX:

- `msr` manages raw session sockets/processes
- `dsm` turns those into directory-local named sessions
- `wsm` builds workspace-wide navigation on top of that

## Current status

This is a script-first package focused on operator ergonomics rather than core runtime implementation.

## Developer notes

The main entrypoint is:

- `dsm/scripts/dsm`

For local development, source:

```bash
source shared/scripts/dev_env.sh
```

That exposes repo-local binaries and helper scripts on `PATH`.
