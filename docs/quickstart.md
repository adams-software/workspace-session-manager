# Quickstart

This repo currently targets Linux first.

## Build from source

From the repo root:

```bash
zig build
zig build test
```

Built binaries land in:

```text
zig-out/bin/
```

Main binaries:

- `zig-out/bin/msr`
- `zig-out/bin/vpty`
- `zig-out/bin/alt`

User-facing scripts:

- `wsm/scripts/wsm`
- `wsm/scripts/wsm_menu`

## Build a distributable bundle

Generate the Linux dist layout and tarball:

```bash
./scripts/build_dist.sh
```

This produces:

```text
dist/linux-x86_64/
dist/workspace-session-manager-linux-x86_64.tar.gz
```

The staged dist bundle includes:

- `bin/` — commands
- `completions/` — bash completions
- `install.sh` — simple installer
- `README.txt` — dist note

## Install from the dist bundle

After unpacking the tarball:

```bash
sh install.sh
```

No separate `libvterm0` runtime package is required. `vpty` vendors libvterm as part of the project build and release bundle.

By default this installs to:

- `~/.local/bin`
- `~/.local/share/bash-completion/completions`

The installed completion files use command-name autoload filenames:

- `wsm`

You can override the install prefix:

```bash
PREFIX=/usr/local sh install.sh
```

## First session with msr

Create and attach to a session:

```bash
msr create -a /tmp/demo.msr -- bash
```

In another shell, you can inspect or reattach:

```bash
msr status /tmp/demo.msr
msr attach /tmp/demo.msr
```

## First session with wsm

Use workspace-wide naming:

```bash
wsm create -a api/dev -- bash
wsm status api/dev
wsm attach api/dev
```

## Terminal stack examples

Run `vpty` directly:

`vpty` uses the vendored libvterm build, so you should not need a separate system `libvterm.so.0` runtime library.

```bash
vpty -- bash
```

Run `alt` with a simple alternate side:

```bash
alt --run /bin/bash --signal-2 TERM -- vpty -- bash
```

## Current status

This is still an actively evolving tool suite.

A practical current read is:

- `msr` is the core runtime
- `wsm` is the operator-facing naming/navigation layer
- `vpty` and `alt` are still under active terminal UX refinement
