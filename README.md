# Workspace Session Manager

Workspace Session Manager is a Linux-first tool suite for creating, naming, navigating, and rendering interactive session-backed processes.

If you just want to start using it, start with `wsm`.

## Install

### from GitHub release

Once release assets are published, the intended install path is:

```bash
curl -fsSL https://raw.githubusercontent.com/adams-software/workspace-session-manager/main/scripts/install-release.sh | sh
```

That downloads the latest Linux x86_64 release bundle and runs its installer.

On Debian/Ubuntu/WSL, `vpty` needs the `libvterm0` runtime package. If it is missing, the installer will stop and tell you exactly what to install before retrying.

### from a local checkout

Build a local distribution bundle:

```bash
./scripts/build_dist.sh
```

That produces:

```text
dist/linux-x86_64/
dist/workspace-session-manager-linux-x86_64.tar.gz
```

Install from the unpacked bundle:

```bash
sh install.sh
```

By default this installs commands into `~/.local/bin`.

Runtime note: `vpty` needs the system libvterm runtime library. On Debian/Ubuntu/WSL that package is usually `libvterm0`.

## Quick usage

Set up a workspace root first:

```bash
mkdir -p ~/sessions
export WSM_ROOT=~/sessions
```

Then run `wsm` by itself to see the command surface:

```bash
wsm
```

Create and attach to a workspace session:

```bash
wsm create test
```

If you want a specific command instead of your default shell:

```bash
wsm create api/dev -- npm run dev
```

Open the workspace menu:

```bash
wsm menu or hotkey ctrl-g
```

Detach from the current session:

```bash
wsm detach
```

Reattach later:

```bash
wsm attach test
```

The menu hotkey uses the same key-spec format as `alt`. The default is `ctrl-g`.
Override it per command with `--menu-key <spec>` or via `WSM_MENU_KEY`.

```bash
wsm --menu-key ctrl-g create test
WSM_MENU_KEY=ctrl-g wsm create test
```

If you want the lower-level tools directly:

```bash
msr
vpty
alt
```

## Package map

### `wsm/`
Workspace session manager.

The main user-facing entrypoint for workspace-wide naming, lookup, and navigation.

### `msr/`
Core session runtime.

Responsible for creating sessions, attaching and detaching, and core status / wait / terminate operations.

### `vpty/`
Terminal integration and rendering layer.

Holds the PTY / terminal-state / rendering work needed for interactive sessions.

### `alt/`
PTY switcher.

Runs a primary side and an alternate side on separate PTYs behind a local hotkey.

### `shared/`
Small cross-cutting package for truly shared code and scripts.

### `ptyio/`
Low-level PTY / stream / tty helpers shared by runtime-facing packages.

## How the pieces fit together

A practical mental model is:

- `wsm` is the main workspace-facing command
- `msr` is the core session runtime
- `vpty` handles terminal modeling and redraw behavior
- `alt` switches between PTY-backed sides with a configurable hotkey

If you are trying to understand the repo in more depth, continue with:

1. `wsm/README.md`
2. `msr/README.md`
3. `vpty/README.md`
4. `alt/README.md`

## Current maturity

This repo is active engineering work, not a frozen product surface.

A practical current read is:

- `wsm` is the ergonomic operator-facing layer
- `msr` is the runtime foundation
- `vpty` is an implementation-heavy terminal subsystem under active refinement
- `alt` is part of the intended tool suite and still evolving

Expect some churn while the public surface settles.

## Build from source

From the repo root:

```bash
zig build
zig build test
```

Artifacts are emitted to:

```text
zig-out/bin/
```

Current binaries include:

- `zig-out/bin/msr`
- `zig-out/bin/vpty`
- `zig-out/bin/alt`

## Development shell

To expose repo-local binaries and helper scripts in your shell:

```bash
source shared/scripts/dev_env.sh
```

That adds repo-local binaries and scripts to `PATH` for the current shell only.
