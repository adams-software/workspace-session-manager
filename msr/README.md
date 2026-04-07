# msr

`msr` is the core session runtime in this repository.

It is responsible for creating, attaching to, detaching from, inspecting, and terminating session-backed processes.

## What lives here

- `src/` — the main Zig runtime and CLI implementation
- `scripts/` — smoke tests and local development helpers that are primarily about the `msr` runtime
- `docs/` — package-local reference material and specs when needed

## Role in the repo

This package is the foundation that the higher-level tools build on:

- `dsm` provides directory-scoped naming and navigation on top of `msr`
- `wsm` provides workspace-scoped naming and navigation on top of `dsm` + `msr`
- `vpty` provides the terminal-side machinery used for interactive sessions

## Current status

This is still an active development package, not a polished public API surface yet.

Expect:

- interface changes
- script churn
- internal refactors as the repo structure settles

## Developer notes

Build from the repo root:

```bash
zig build
```

The main binary is emitted to:

```text
zig-out/bin/msr
```

For a repo-local shell environment, source:

```bash
source shared/scripts/dev_env.sh
```

## Open-source posture

If this repo is published, `msr` should be presented as:

- the core runtime package
- the most stable conceptual center of the repo
- the place to start when explaining how sessions work
