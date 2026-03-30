# MSR Workspace Script v0 Spec

## Status

Draft RFC for review.

Implementation note (current decision set)

DSM operates only within the effective current directory.
It does not recurse, does not walk parents, and does not allow nested/session-stacking behavior.
Session files are identified by literal user-provided names with a `.msr` extension.

## Naming
Script called directory session manager or dsm as its application name.

## Purpose

Define a **single-directory shell UX layer** that composes on top of the low-level `msr` binary.

This layer treats one directory as a **workspace** containing session sockets. It provides:

* ergonomic session naming
* workspace-local session creation and attach
* current-session awareness
* lexical sibling navigation
* shell completion and small quality-of-life helpers

This layer is intentionally **just composition**. It does not redefine session semantics.

---

## Non-goals

This spec does **not** define:

* global multi-workspace discovery
* hierarchy/tree navigation across directories
* a central daemon or registry
* any change to `msr` host/server/client semantics
* terminal multiplexing
* logging/replay

Those are follow-on layers.

---

## Design principles

1. **Low-level binary remains authoritative**
   The script must delegate actual session behavior to `msr`.

2. **Filesystem is the registry**
   Session sockets in one directory define the workspace.

3. **Current session is explicit**
   `MSR_SESSION` is the source of truth for “where am I?”

4. **Workspace is stable while attached**
   When inside a session, workspace is derived from `MSR_SESSION`, not drifting shell cwd.

5. **Conventions over configuration**
   Session names map predictably to socket filenames.

6. **Shell-first composition**
   Implemented as sourced shell functions and completion, not a new daemon.

---

# 1. Core model

## Workspace

A **workspace** is a directory containing session socket files with a fixed extension.

Recommended extension:

```text
.msr
```

Examples:

* `shell.msr`
* `build.msr`
* `api.msr`

## Session name

A human-friendly name like:

* `shell`
* `build`
* `api`

Mapping rule:

```text
<name> -> <workspace>/<name>.msr
```

## Current session

When inside a hosted shell/session, the environment variable:

```text
MSR_SESSION=/full/path/to/workspace/name.msr
```

identifies the current session.

From this, the script can derive:

* current workspace: `dirname "$MSR_SESSION"`
* current session filename: `basename "$MSR_SESSION"`
* current session name: filename minus `.msr`

---

# 2. Workspace resolution

Workspace resolution order:

## Rule 1: explicit override

If command is given an explicit workspace option, use it.

Example:

```bash
ms --workspace /path/to/proj ls
```

## Rule 2: current session context

If `MSR_SESSION` is set, workspace is:

```bash
dirname "$MSR_SESSION"
```

This rule takes precedence over live shell cwd while inside a session.

## Rule 3: fallback

If no explicit workspace and no `MSR_SESSION`, workspace is current directory:

```bash
$PWD
```

---

## Rationale

This is critical because once attached, shell cwd may drift:

* attach to `/proj/shell.msr`
* inside session, `cd /tmp`
* `ms next` should still navigate `/proj/*.msr`, not `/tmp/*.msr`

So attached session identity, not live cwd, defines workspace context.

---

# 3. Naming and path rules

## Default filename convention

Socket file path for session name `foo` is:

```text
<workspace>/foo.msr
```

## Accepted user inputs

The script should accept:

### bare session name

```text
foo
```

Resolved as:

```text
<workspace>/foo.msr
```

### name with suffix

```text
foo.msr
```

Resolved as:

```text
<workspace>/foo.msr
```

### explicit relative path

```text
./foo.msr
../other/foo.msr
```

Used as provided.

### explicit absolute path

```text
/abs/path/foo.msr
```

Used as provided.

---

## Recommended helper behavior

Normalization helper should behave like:

* `foo` -> `<workspace>/foo.msr`
* `foo.msr` -> `<workspace>/foo.msr`
* `./foo.msr` -> `./foo.msr`
* `/x/y/foo.msr` -> `/x/y/foo.msr`

---

# 4. Environment contract

## Required env var inside hosted session

The hosted shell/process should receive:

```text
MSR_SESSION=/full/path/to/workspace/name.msr
```

This must be set when the session is **created**, not when attached.

## Why

If `msr attach` simply streams into an already-running shell, setting env locally at attach time does **not** retroactively set it inside the remote shell.

So the wrapper must ensure that `msr create` includes `MSR_SESSION` in the environment of the hosted shell/process.

---

## Optional future env vars

Not required for v0, but possible later:

* `MSR_WORKSPACE`
* `MSR_NAME`

For v0, `MSR_SESSION` alone is sufficient.

---

# 5. User-facing command surface

Recommended shell function name:

```bash
ms
```

This is the higher-level workspace UX wrapper over low-level `msr`.

## Commands

### `ms new <name> [-- cmd ...]`

Create a new session in the resolved workspace.

Behavior:

* resolve workspace
* resolve socket path as `<workspace>/<name>.msr`
* call low-level `msr create <socket> -- <cmd...>`
* inject `MSR_SESSION=<socket>` into hosted process environment

Default command if omitted:

* `$SHELL`

Examples:

```bash
ms new shell
ms new build -- bash
ms new api -- npm run dev
```

---

### `ms a <name>`

Attach to a named session in the resolved workspace.

Behavior:

* resolve name -> socket path
* delegate to `msr attach <socket>`
* may `exec` into low-level attach flow for clean terminal ownership

Examples:

```bash
ms a shell
ms a build
```

Optional alias:

```bash
ms attach shell
```

---

### `ms ls`

List sessions in the resolved workspace.

Behavior:

* enumerate `*.msr` in workspace
* sort lexically
* display session names
* optionally mark current session if `MSR_SESSION` is set

Example output:

```text
api
build
* shell
```

Possible richer output later:

* full path
* low-level status
* exited/dead marker

But v0 should stay simple.

---

### `ms status <name>`

Show low-level status for a named session.

Behavior:

* resolve socket path
* delegate to `msr status <socket>`

---

### `ms kill <name>`

Terminate the named session.

Behavior:

* resolve socket path
* delegate to `msr terminate <socket>`

---

### `ms wait <name>`

Wait for named session exit.

Behavior:

* resolve socket path
* delegate to `msr wait <socket>`

---

### `ms current`

Print current session information derived from `MSR_SESSION`.

Behavior:

* if `MSR_SESSION` unset: error/non-zero
* else print current session name or full path

Recommended default:

* print full path

Optional flags later:

* `--name`
* `--workspace`

---

### `ms next`

Attach to next session in lexical order within current workspace.

Behavior:

* requires current session context (`MSR_SESSION`)
* enumerate `*.msr`
* sort lexically
* find current session
* choose next sibling
* wrap around at end
* attach to selected target

---

### `ms prev`

Attach to previous session in lexical order within current workspace.

Behavior:

* requires current session context (`MSR_SESSION`)
* enumerate `*.msr`
* sort lexically
* find current session
* choose previous sibling
* wrap around at beginning
* attach to selected target

---

# 6. Navigation semantics

## Current-session requirement

`next` and `prev` should only operate when `MSR_SESSION` is set.

Reason:
they are defined relative to the current attached session.

If called outside a session:

* return error
* suggest `ms ls` or explicit `ms a <name>`

## Ordering

Sibling order is lexical filename order over `*.msr`.

Example:

```text
api.msr
build.msr
shell.msr
```

Navigation:

* from `api` -> `build`
* from `build` -> `shell`
* from `shell` -> `api` (wraparound)

## Wraparound

Wraparound is recommended for v0. It feels natural and avoids edge dead-ends.

---

# 7. Error behavior

The script should be explicit and simple.

## Recommended cases

### session not found

Example:

```bash
ms a nope
```

Behavior:

* print clear error
* exit non-zero

### no workspace sessions

Example:

```bash
ms ls
```

Behavior:

* print nothing or friendly message
* exit zero is acceptable

### next/prev with no current session

Behavior:

* print error like “not currently inside an MSR session”
* exit non-zero

### duplicate session creation

Let low-level `msr create` remain authoritative for conflict detection.

---

# 8. Implementation guidance

## Implementation form

Use a **sourced shell script** that defines:

* one public dispatcher function
* several private helpers
* completion functions
* optional aliases

Recommended file:

```text
msr-workspace.sh
```

Users add to shell startup:

```bash
source /path/to/msr-workspace.sh
```

---

## Recommended internal helper functions

### `_ms_workspace`

Resolve current workspace path.

Responsibilities:

* explicit override support
* respect `MSR_SESSION`
* fallback to `$PWD`

### `_ms_sock_for_name`

Map name/path input to socket path.

### `_ms_list_sockets`

List workspace socket files.

Recommended output:

* absolute or normalized full paths

### `_ms_current_socket`

Return current socket path from `MSR_SESSION`.

### `_ms_current_name`

Return current name from `MSR_SESSION`.

### `_ms_next_socket`

Return next sibling socket path in lexical order.

### `_ms_prev_socket`

Return previous sibling socket path in lexical order.

### `_ms_require_current_session`

Fail fast if `MSR_SESSION` is not set.

### `_ms_exec_attach`

Helper that delegates to low-level `msr attach`.

---

## Dispatcher pattern

Public function `ms()` should:

* parse optional global flags first
* parse subcommand
* delegate to subcommand-specific helpers

Keep subcommand bodies small.

---

# 9. Suggested file organization

A simple organization that stays maintainable:

```text
shell/
  msr-workspace.sh
  completion.bash
  README.md
```

Or combined in one file initially:

```text
shell/
  msr-workspace.sh
```

With sections:

* helpers
* commands
* completion
* aliases

Recommended progression:

* start with one file
* split completion later only if it grows

---

# 10. Low-level delegation contract

The workspace script must not reimplement session semantics.

It should delegate to low-level `msr` for:

* create
* attach
* status
* terminate
* wait

This means:

* attach ownership rules remain in `msr`
* host/server lifecycle remains in `msr`
* protocol semantics remain in `msr`

The script only adds:

* naming
* path resolution
* workspace conventions
* current-session navigation

---

# 11. Creation behavior details

`ms new <name>` should do more than a naive pass-through.

Recommended behavior:

1. resolve workspace
2. resolve target socket path
3. determine command:

   * explicit `-- cmd ...`
   * else `$SHELL`
4. ensure hosted env includes:

   * `MSR_SESSION=<socket>`
5. call low-level create

This is essential because `MSR_SESSION` inside the hosted shell is what enables later workspace navigation from within attached sessions.

---

# 12. Attach behavior details

`ms a <name>` should:

1. resolve workspace
2. resolve target socket path
3. delegate to `msr attach <socket>`

Recommended implementation:

* use `exec` when appropriate so terminal control passes cleanly to low-level attach command

This avoids leaving an extra wrapper shell process in the middle.

---

# 13. Listing behavior details

`ms ls` should:

* resolve workspace
* enumerate `*.msr`
* sort lexically
* strip `.msr` for user-facing names
* optionally mark current session with `*`

Do not overcomplicate v0 with health checks unless needed.

A simple lexical list is enough.

Possible later extension:

* `ms ls --status` to call low-level `msr status` for each socket

But not required for v0.

---

# 14. Completion / QoL

## Bash completion

Provide completion for:

* subcommand names
* session names for commands like:

  * `a`
  * `attach`
  * `status`
  * `kill`
  * `wait`

Completion source:

* list `*.msr` in resolved workspace
* strip `.msr`
* return names only

## Prompt integration

Optional, not required by spec.

Possible prompt indicator:

```text
[msr:shell]
```

derived from `MSR_SESSION`.

Useful, but should remain optional.

## Aliases

Optional convenience aliases:

```bash
alias msa='ms a'
alias msn='ms next'
alias msp='ms prev'
```

Do not require them in v0.

---

# 15. Installation plan

## Initial installation

The workspace layer should be installable by sourcing a shell file.

Example:

```bash
source ~/.local/share/msr/msr-workspace.sh
```

Or copy into dotfiles:

```bash
source ~/dotfiles/msr-workspace.sh
```

This is the simplest path and ideal for quick iteration.

---

## Recommended install layout

For a packaged binary + shell integration:

```text
~/.local/bin/msr
~/.local/share/msr/msr-workspace.sh
~/.local/share/msr/completion.bash
```

Then user shell init:

```bash
source ~/.local/share/msr/msr-workspace.sh
source ~/.local/share/msr/completion.bash
```

If completion is embedded in the main file, only the first line is needed.

---

## Future packaging

Later, you can package:

* the `msr` binary
* the shell integration script
* completion scripts

through:

* tarball release
* Homebrew formula
* distro package

But for v0, “source this script” is sufficient and preferred.

---

# 16. Example usage

## Outside a session

```bash
cd ~/proj
ms new shell
ms new build -- npm run watch
ms ls
ms a shell
```

## Inside `shell`

Given:

```bash
MSR_SESSION=/home/me/proj/shell.msr
```

Then:

```bash
ms ls
ms next
ms prev
ms current
```

all operate against `/home/me/proj`, regardless of current shell cwd.

---

# 17. Acceptance criteria

The workspace script is successful if:

1. A directory can act as a workspace with no extra metadata.
2. Session names map predictably to socket filenames.
3. `MSR_SESSION` inside the hosted shell enables current-session-aware navigation.
4. `ms next` and `ms prev` work over lexical sibling sockets.
5. `ms ls`, `ms a`, `ms status`, `ms kill`, and `ms wait` correctly delegate to low-level `msr`.
6. The script can be installed by sourcing a shell file.
7. Tab completion can suggest session names from the current workspace.

---

# 18. Follow-on evolution

This v0 workspace layer is intended to become the foundation for a future global manager.

Likely next step:

* a higher-level wrapper that operates across many workspace directories

That future layer should reuse the same core ideas:

* current session path
* workspace resolution
* filesystem discovery
* name/path mapping

So this v0 spec should remain intentionally local, small, and composable.

---

# 19. Recommended implementation posture

The biggest recommendation is:

## Build this as a clean shell composition layer, not as a second session system.

That means:

* no duplicated lifecycle logic
* no hidden daemon
* no shadow registry
* no deviation from low-level `msr` authority

This keeps the architecture clean and makes later global composition much easier.

If you want, next I can turn this into an actual Bash implementation skeleton.

