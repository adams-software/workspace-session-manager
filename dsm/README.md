# dsm

`dsm` is the directory session manager layer in this repository.

It provides ergonomic local naming and lexical navigation for `msr` sessions within a single directory.

## What lives here

- `scripts/` — the `dsm` command, completion, and smoke coverage
- `docs/` — package-local docs as the command surface evolves

## Role in the repo

`dsm` sits between the raw runtime and the workspace-wide UX:

- `msr` manages raw session sockets/processes
- `dsm` turns those into directory-local named sessions
- `wsm` builds workspace-wide navigation on top of that

## Current status

This is a script-first package.

That is fine for now: the package is primarily about operator ergonomics and command composition rather than core runtime implementation.

## Developer notes

The main entrypoint is:

- `dsm/scripts/dsm`

For local development, source:

```bash
source shared/scripts/dev_env.sh
```

That exposes the repo-local binaries and helper scripts on `PATH`.

## Open-source posture

If this repo is published, `dsm` should be framed as a convenience/operator layer rather than the core runtime itself.
