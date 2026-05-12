# host runtime (`msr/`)

This package contains the generic session host runtime in this repository.

Most users will start with `wsm`, but this package is the lowest-level runtime layer that directly manages session-backed processes. During the current migration, it installs both `host` and `msr` entrypoints.

## Quick usage

See the full command surface:

```bash
host --help
```

The legacy `msr` entrypoint still works during migration:

```bash
msr --help
```

Or for an explicit current-session context:

```bash
MSR_SESSION=/tmp/demo.msr host --help
```

Create a session:

```bash
host create /tmp/demo.msr -- bash
```

Create a session that waits for first attach before starting the child:

```bash
host create --wait-attach /tmp/demo.msr -- nvim
```

Attach:

```bash
host attach /tmp/demo.msr
```

Inspect session status:

```bash
host status /tmp/demo.msr
```

## What lives here

- `src/` — the main Zig runtime and CLI implementation
- `docs/` — package-local reference material and specs when needed
- `scripts/` — smoke tests and local development helpers focused on the host runtime

## Role in the repo

This package is the foundation that the higher-level tools build on:

- `wsm` provides workspace-scoped naming and navigation on top of the host runtime
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

The main binaries are emitted to:

```text
zig-out/bin/host
zig-out/bin/msr
```

For a repo-local shell environment, source:

```bash
source shared/scripts/dev_env.sh
```
