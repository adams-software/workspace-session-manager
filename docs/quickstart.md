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

- `zig-out/bin/host`
- `zig-out/bin/vpty`
- `zig-out/bin/alt`
- `zig-out/bin/ptylog`

Primary user-facing entrypoint:

- `zig-out/bin/wsm`

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

- `bin/` — public commands
- `libexec/wsm/` — private runtime helpers used by `wsm`
- `completions/` — bash completions
- `install.sh` — simple installer
- `README.txt` — dist note

## Install from the dist bundle

After unpacking the tarball:

```bash
sh install.sh
```

No separate `libvterm0` runtime package is required. The private runtime helpers vendor libvterm as part of the project build and release bundle.

By default this installs to:

- `~/.local/bin` (`wsm`)
- `~/.local/libexec/wsm` (private runtime helpers)
- `~/.local/share/bash-completion/completions`

The installed completion files use command-name autoload filenames:

- `wsm`

## Log viewing

`wsm log` opens the readable `.log` output directly through the bundled
viewer helper. Single-file logs are opened directly in `less`; segmented logs
are stitched into a temporary file first so they still behave like one log.

You can override the install prefix:

```bash
PREFIX=/usr/local sh install.sh
```

## Troubleshooting installed-vs-repo behavior

If `zig-out/bin/wsm` and your installed `wsm` behave differently, verify which
binary your shell is actually resolving:

```bash
which wsm
ls -l ~/.local/bin/wsm ~/.local/libexec/wsm/{host,vpty,ptylog,wsm_logs_viewer}
ls -l zig-out/bin/{wsm,host,vpty,ptylog}
```

When in doubt, rebuild the local distribution bundle and reinstall it:

```bash
./scripts/build_dist.sh
cd dist/linux-x86_64
sh install.sh
```

## First session with host

If you are developing from a repo checkout, you can run the low-level host runtime directly:

```bash
zig-out/bin/host /tmp/demo.sock -- /bin/bash -i
```

This is the generic single-child host process. Most users should prefer `wsm`, which handles workspace naming and session discovery on top. The normal installer does not expose `host` on `PATH`.

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

- `host` is the core runtime behind `wsm`
- `wsm` is the operator-facing naming/navigation layer
- `vpty` and `alt` are still under active terminal UX refinement
