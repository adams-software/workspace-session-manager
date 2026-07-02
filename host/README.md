# host runtime package (`host/`)

This package contains the generic session host runtime in this repository.

Most users will start with `wsm`, but this package is the lowest-level runtime layer that directly manages session-backed processes. In the normal install layout, `wsm` finds `host` as a private helper instead of exposing it as a public command on `PATH`.

## Quick usage

See the full command surface from a repo checkout:

```bash
zig-out/bin/host --help
```

Run the host directly against a socket path:

```bash
zig-out/bin/host /tmp/demo.sock -- /bin/bash -i
```

Run a headless host:

```bash
zig-out/bin/host /tmp/demo.sock --headless -- /bin/bash -i
```

This package is the low-level runtime layer. For workspace-scoped session naming, creation, logs, and navigation, use `wsm`.

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
- ongoing polish of the host runtime surface

## Developer notes

Build from the repo root:

```bash
zig build
```

The main binaries are emitted to:

```text
zig-out/bin/host
```

For a repo-local shell environment, source:

```bash
source shared/scripts/dev_env.sh
```
