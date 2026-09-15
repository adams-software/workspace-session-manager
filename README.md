# Workspace Session Manager

Workspace Session Manager is a Linux-first tool suite for creating, naming, navigating, and rendering interactive session-backed processes.

If you just want to start using it, start with `wsm help`.

## Install

### from GitHub release

Install the latest release without sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/adams-software/workspace-session-manager/main/scripts/install-release.sh | sh
```

That downloads the latest Linux x86_64 release bundle and runs its installer.

Requirements:

- **Linux x86_64 with glibc 2.28 or newer.** The release bundle does not support
  ARM, macOS, or musl-based systems such as Alpine.
- A POSIX shell and `curl` for the command above (the downloaded script also
  accepts `wget`), plus `tar`, `gzip`, `mktemp`, `mkdir`, `rm`, `install`, `env`, `id`, `uname`, and `getconf`.
  These normally come with the system's core utilities.
- A usable PTY (`/dev/ptmx` and `/dev/pts`), `/proc`, and a writable session
  directory, plus the standard `env` command for launching the shell. Interactive
  sessions need a terminal; detached commands can run
  without one. WSM uses `$SHELL`, falling back to `/bin/sh`.
- **Bash and `less` for `wsm log`**; they are not needed for creating sessions.
  Bash completion is optional and uses your shell's bash-completion setup.

No Zig, Git, tmux, Python, or separate libvterm package is required at runtime.
Do not run the installer with sudo for the default per-user installation.

The installer cannot update the calling shell's PATH. After installation:

```sh
export PATH="$HOME/.local/bin:$PATH"
wsm help
```

Add the PATH export once to `~/.bashrc` (Bash) or `~/.zshrc` (Zsh) for future
shells. `wsm help` identifies the installed version and session directory.
To install elsewhere, put `PREFIX` on the **sh side** of the pipe:

```sh
curl -fsSL https://raw.githubusercontent.com/adams-software/workspace-session-manager/main/scripts/install-release.sh | PREFIX="$HOME/apps/wsm" sh
```

Then add `$HOME/apps/wsm/bin` to PATH instead. To select an older release, use
`VERSION=v0.1.0-beta.27 sh` on that side of the pipe.

### from a local checkout

Building from source requires Zig **0.16.0**, Bash, and the standard build/install
utilities. Git is optional but supplies the embedded build version. Build a local
distribution bundle:

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

Release bundles use `ReleaseSafe` optimization, retaining runtime safety checks. Local `zig build` still defaults to Debug.

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

Session directory selection in beta28 and newer is:

1. `--workspace=<path>` for that command.
2. A nonempty `WSM_ROOT` environment variable.
3. `/tmp/wsm-<uid>` (for example `/tmp/wsm-1000`), created automatically with
   owner-only permissions. `wsm help` shows the resolved `WORKSPACE` path.

**Release compatibility:** beta27 and earlier require `WSM_ROOT` for CLI
commands; the automatic default is available in beta28 and newer. If your installed `wsm help` shows no `WORKSPACE`, configure it below.

For a persistent directory, choose an existing directory you own:

```sh
mkdir -p "$HOME/sessions"
export WSM_ROOT="$HOME/sessions"
```

Add that export once to `~/.bashrc` or `~/.zshrc` if desired. To use a different
directory for one command:

```sh
mkdir -p "$HOME/project-sessions"
wsm --workspace="$HOME/project-sessions" create test
```

`/tmp` may be cleared on reboot or by system cleanup. Use a persistent directory
if you want to retain logs; live processes do not survive reboot either way.
Changing the directory changes which sessions WSM discovers—it does not move or
terminate existing sessions. If an older interactive build created sessions in
the current directory without `WSM_ROOT`, select that directory explicitly to
find them again.

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
- `Ctrl+C` dismisses the menu or prompt and returns focus to the child session
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

The main user-facing entrypoint for workspace-wide naming, lookup, and navigation. While attached, WSM queues at most 256 KiB in each direction. It pauses socket reads when session output fills its queue and pauses terminal input reads when pending input fills its queue. Reads resume as the receiving side accepts data.

### `host/`
Generic session host runtime package (exports the internal `host` helper).

Responsible for the low-level host runtime: starting a single child, binding the session socket, and owning the core host status / control behavior. End users normally enter through `wsm`, which locates this helper privately at install time.

### `vpty/`
Terminal integration and rendering layer.

Holds the PTY / terminal-state / rendering work needed for interactive sessions. Pending input is capped at 256 KiB; vpty pauses reading stdin until the child accepts queued bytes, preserving input order without dropping data.

After child exit, vpty gives remaining PTY output a 250 ms drain window, including when descendants retain the PTY. At shutdown, vpty then gives stdout a 250 ms window to drain pending output before abandoning any remainder, so a stalled terminal cannot keep an exited session alive.

When pending terminal controls reach 2 MiB, vpty pauses PTY reads and parsing until stdout drains below that threshold. The current parser chunk can cross the threshold, including completion of a buffered OSC sequence.

Hyperlink metadata is cached up to 1,024 records and 1 MiB of URL/parameter text. Older entries expire when either limit is reached, so older text can lose clickability; expired link IDs never resolve to a different URL. Existing snapshots retain their own metadata copies.

The terminal control parser limits complete OSC sequences to 1 MiB and CSI sequences to 4 KiB, including delimiters. Oversized sequences are discarded through their terminator so their payload does not appear as screen text. This includes OSC 52 clipboard transfers whose encoded sequence exceeds 1 MiB.

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
- `ptylog` captures readable session logs for later viewing

If you are trying to understand the repo in more depth, continue with:

1. `wsm/README.md`
2. `host/README.md`
3. `vpty/README.md`
4. `ptylog/src/log_core.zig`

## Current maturity

This repo is active engineering work, not a frozen product surface.

A practical current read is:

- `wsm` is the ergonomic operator-facing layer
- `host` is the runtime foundation behind `wsm`
- `vpty` is an implementation-heavy terminal subsystem under active refinement
- release/install flow is usable, but still worth sanity-checking with a real installed-binary session before tagging

Expect some churn while the public surface settles.

## Build from source

From the repo root:

```bash
zig build
zig build test
```

On Linux with Valgrind installed, check libvterm's C allocations as well:

```bash
zig build test-c-leaks -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
```

CI runs this check for adapter and history ownership tests, including hyperlink
cache eviction. It fails on memory errors or leaks that Zig's testing allocator
cannot detect. It covers these test workloads; it does not measure long-running
session CPU usage or overall memory growth.

To record CPU, memory, and descriptor counts for an existing session, see
[resource diagnostics](docs/resource-diagnostics.md).

Artifacts are emitted to:

```text
zig-out/bin/
```

Current binaries include:

- `zig-out/bin/wsm`
- `zig-out/bin/host`
- `zig-out/bin/vpty`
- `zig-out/bin/ptylog`

## Development shell

To expose repo-local binaries and helper scripts in your shell:

```bash
source shared/scripts/dev_env.sh
```

That adds repo-local binaries and scripts to `PATH` for the current shell only.
