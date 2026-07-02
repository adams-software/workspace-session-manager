# Workspace Session Manager

Workspace Session Manager is a Linux-first tool suite for creating, naming, navigating, and rendering interactive session-backed processes.

If you just want to start using it, start with `wsm help`.

## Install

### from GitHub release

Once release assets are published, the intended install path is:

```bash
curl -fsSL https://raw.githubusercontent.com/adams-software/workspace-session-manager/main/scripts/install-release.sh | sh
```

That downloads the latest Linux x86_64 release bundle and runs its installer.

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
cd dist/linux-x86_64
sh install.sh
```

By default this installs:
- `wsm` into `~/.local/bin`
- private runtime helpers into `~/.local/libexec/wsm`

So `wsm` is the only public command added to `PATH` by the standard install.

Release bundles for `linux-x86_64` are now built with an explicit portable target instead of inheriting CPU features from the release machine. That avoids `Illegal instruction` failures on older x86_64 hosts.

## Troubleshooting

### Repo build vs installed binary mismatch

It is possible to have a clean repo checkout while your installed `wsm` under
`~/.local/bin` is still from an older experiment build.

Check which binary you are actually running:

```bash
which wsm
ls -l ~/.local/bin/wsm ~/.local/libexec/wsm/{host,vpty,ptylog,wsm_logs_viewer}
ls -l zig-out/bin/{wsm,host,vpty,ptylog}
```

If behavior differs between the repo build and the installed command, rebuild
and reinstall the local dist bundle:

```bash
./scripts/build_dist.sh
cd dist/linux-x86_64
sh install.sh
```

A common symptom of an install mismatch is that `zig-out/bin/wsm` behaves
correctly while `~/.local/bin/wsm` shows stale behavior.

## Quick usage

Set up a workspace root in your shell environment:

### bash

```bash
mkdir -p ~/sessions
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
echo 'export WSM_ROOT="$HOME/sessions"' >> ~/.bashrc
source ~/.bashrc
```

### zsh

```bash
mkdir -p ~/sessions
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
echo 'export WSM_ROOT="$HOME/sessions"' >> ~/.zshrc
source ~/.zshrc
```

Then run `wsm help` to see the command surface:

```bash
wsm help
```

Create and attach to a workspace session:

```bash
wsm create test
```

Detached create:

```bash
wsm create -d api/dev
```

Alias forms mirror the in-session status bar where that makes sense:

```bash
wsm c test
wsm a test
wsm g test
wsm x test
wsm ls
wsm cd api/dev
```

Open the in-session action menu after attaching:

```bash
wsm attach test
# then press ctrl-g inside the session
```

Inside the UI:

- `a` opens attach prompt
- `c` opens create prompt
- `g` opens logs
- `x` force-kills the current session child
- `d` detaches from the current interactive session
- `h/j/k/l` or arrow keys navigate sibling/child/parent/next session targets
- `b` toggles back to the previously visited session target

To leave an attached session, use the in-session detach flow, then reattach later:

```bash
wsm attach test
```

The in-session action menu hotkey is currently fixed to `ctrl-g`.

From the top-level status menu, `Esc`, `Enter`, and `ctrl-g` all return to the
attached session view.

Interactive attach/create is intentionally blocked from inside an already-interactive nested `wsm` session. If you are already inside one attached session and want another, use detached create from the UI and then attach/switch.

If you want the lower-level tools directly, they still exist in the repo and build output, but the normal install keeps the runtime helpers private so `wsm` is the only public command on `PATH`.

## Package map

### `wsm/`
Workspace session manager.

The main user-facing entrypoint for workspace-wide naming, lookup, and navigation.

### `host/`
Generic session host runtime package (exports the internal `host` helper).

Responsible for the low-level host runtime: starting a single child, binding the session socket, and owning the core host status / control behavior. End users normally enter through `wsm`, which locates this helper privately at install time.

### `vpty/`
Terminal integration and rendering layer.

Holds the PTY / terminal-state / rendering work needed for interactive sessions.

### `alt/`
PTY switcher.

Runs a primary side and an alternate side on separate PTYs behind a local hotkey.

### `ptylog/`
Readable session log capture.

Promotes PTY output into bounded, human-readable `.log` files and owns the shared log rendering semantics used by that path.

### `shared/`
Small cross-cutting package for truly shared code and scripts.

### `ptyio/`
Low-level PTY / stream / tty helpers shared by runtime-facing packages.

## How the pieces fit together

A practical mental model is:

- `wsm` is the main workspace-facing command
- `host` is the generic session host runtime used behind `wsm`
- `vpty` handles terminal modeling and redraw behavior
- `alt` switches between PTY-backed sides with a configurable hotkey
- `ptylog` captures readable session logs for later viewing

If you are trying to understand the repo in more depth, continue with:

1. `wsm/README.md`
2. `host/README.md`
3. `vpty/README.md`
4. `alt/README.md`
5. `ptylog/src/log_core.zig`

## Current maturity

This repo is active engineering work, not a frozen product surface.

A practical current read is:

- `wsm` is the ergonomic operator-facing layer
- `host` is the runtime foundation behind `wsm`
- `vpty` is an implementation-heavy terminal subsystem under active refinement
- `alt` is part of the intended tool suite and still evolving
- release/install flow is usable, but still worth sanity-checking with a real installed-binary session before tagging

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

- `zig-out/bin/wsm`
- `zig-out/bin/host`
- `zig-out/bin/vpty`
- `zig-out/bin/alt`
- `zig-out/bin/ptylog`

## Development shell

To expose repo-local binaries and helper scripts in your shell:

```bash
source shared/scripts/dev_env.sh
```

That adds repo-local binaries and scripts to `PATH` for the current shell only.
