# msr

`msr` is the core session runtime in this repository.

Most users will start with `wsm`, but `msr` is the lowest-level command in the suite that directly manages session-backed processes.

## Quick usage

See the full command surface:

```bash
msr --help
```

Or for an explicit current-session context:

```bash
MSR_SESSION=/tmp/demo.msr msr --help
```

Create a session:

```bash
msr create /tmp/demo.msr -- bash
```

Create a session that waits for first attach before starting the child:

```bash
msr create --wait-attach /tmp/demo.msr -- nvim
```

Attach:

```bash
msr attach /tmp/demo.msr
```

Inspect session status:

```bash
msr status /tmp/demo.msr
```

## What lives here

- `src/` — the main Zig runtime and CLI implementation
- `docs/` — package-local reference material and specs when needed
- `scripts/` — smoke tests and local development helpers focused on the runtime

## Role in the repo

This package is the foundation that the higher-level tools build on:

- `wsm` provides workspace-scoped naming and navigation on top of `msr`
- `vpty` provides terminal-side machinery used for interactive sessions

## Current status

This is the conceptual center of the repo, but it is still under active development.

Expect:

- interface changes
- internal refactors
- ongoing polish of the public CLI surface

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
