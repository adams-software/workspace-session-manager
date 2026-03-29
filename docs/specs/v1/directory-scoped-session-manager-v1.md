# Directory-Scoped Session Manager v1

Status: draft

## 1) Purpose

Define the first multi-session management layer above the single-session runtime core.

This layer is **library-first**. Its primary purpose is to lift the core single-session API into a directory-scoped namespace containing many sessions.

The intended model is deliberately simple:
- the manager owns a directory
- sockets in that directory are the session world
- the manager API is mostly the core session API with an added `(state_dir, name)` namespace layer
- only a small number of additional functions are introduced where multi-session concerns require them

This spec does **not** define a rich human-facing CLI yet.

## 2) Design principles

- **Library first.** CLI, if any, should be a thin passthrough to the library.
- **Maximum explicitness.** No convenience verbs that combine behaviors implicitly.
- **Filesystem as source of truth.** No registry or metadata persistence required for v1.
- **Manager owns the directory.** Any sockets in the directory are considered part of the manager's world.
- **Mirror core semantics where possible.** The manager should feel like the core session API lifted into a namespace.
- **No implicit current session.** v1 is entirely explicit-name based.

## 3) Non-goals (v1)

- Rich human ergonomics (`current`, `next`, `prev`, aliases, fuzzy selection)
- Persistent registry or metadata database
- Logging, replay, scrollback, or virtual terminal rendering
- TUI
- Multi-client collaborative attach
- Cross-directory/global session discovery

## 4) Conceptual model

There are two layers:

### 4.1 Core session runtime
A single-session runtime primitive with operations like:
- `exists(path)`
- `create(path, opts)`
- `attach(path, mode)`
- `resize(path, cols, rows)`
- `terminate(path, signal?)`
- `wait(path)`

### 4.2 Directory-scoped session manager
The manager is conceptually:
- the core session API
- plus directory/name resolution
- plus a very small amount of additional multi-session functionality

Put bluntly:

> manager ~= union(session_api, namespace_api, discovery_api)

The manager should not introduce new policy-heavy concepts unless directory-scoped multi-session behavior requires them.

## 5) Namespace model

### 5.1 State directory
Every manager operation is scoped to a **state directory**.

The state directory is:
- owned by the manager
- the namespace boundary for sessions
- the source of truth for discovery

### 5.2 Session identity
A session is identified by:
- `state_dir`
- `name`

The manager resolves `(state_dir, name)` into a concrete socket path inside `state_dir`.

### 5.3 Naming policy
v1 intentionally adds **no extra naming convention layer** beyond filesystem rules.

That means:
- the manager respects the filesystem namespace directly
- if a name maps to a socket path in the state dir, that is the session identity
- the manager assumes sockets in the directory belong to its world

The manager should not add naming policy of its own. Any invalidity arising from path resolution or core path constraints should bubble up as underlying errors rather than manager-specific interpretation.

## 6) Library API surface

The manager API should mirror the core single-session API names/signatures/semantics as strictly as possible, with `(state_dir, name, ...)` lifting replacing direct path arguments.

## 6.1 Namespace / discovery functions

### `resolve(state_dir, name) -> path`
Resolve a directory-scoped session name to its concrete socket path.

This is a pure namespace helper.

### `list(state_dir) -> []Name`
Return discoverable session names in the state directory.

This is one of the small number of manager-specific functions not present in the core single-session API.

## 6.2 Lifted core session operations

These should mirror the core single-session API names/signatures/semantics as closely as possible:

### `exists(state_dir, name) -> bool`
Resolve `(state_dir, name)` and delegate to core `exists(path)`.

### `create(state_dir, name, spawn_opts) -> void`
Resolve `(state_dir, name)` and delegate to core `create(path, spawn_opts)`.

### `attach(state_dir, name, mode) -> ...`
Resolve `(state_dir, name)` and delegate to core `attach(path, mode)` semantics.

### `resize(state_dir, name, cols, rows) -> void`
Resolve `(state_dir, name)` and delegate to core `resize(path, cols, rows)`.

### `terminate(state_dir, name, signal?) -> void`
Resolve `(state_dir, name)` and delegate to core `terminate(path, signal?)`.

### `wait(state_dir, name) -> ExitStatus`
Resolve `(state_dir, name)` and delegate to core `wait(path)`.

### `status(state_dir, name) -> Status`
Resolve `(state_dir, name)` and delegate to core `status(path)`.

Minimal v1 `Status` set mirrored from core:
- `not_found`
- `running`
- `exited_pending_wait`
- `stale`

## 7) Discovery model

`list(state_dir)` returns discoverable session names only.

Status inspection is a separate explicit operation via:
- `status(state_dir, name)`

This keeps discovery and inspection separate in v1.

## 8) Semantics by operation

## 8.1 resolve
- joins `state_dir` + `name`
- returns the concrete socket path
- does not imply existence

## 8.2 list
- scans the manager-owned directory
- treats sockets found there as part of the manager namespace
- returns names only
- should not invent ordering semantics in v1

## 8.3 exists
- resolves `(state_dir, name)` to path
- delegates to core `exists(path)` semantics

## 8.4 create
- resolves `(state_dir, name)` to path
- delegates to core `create(path, opts)` semantics
- fails if a live session already exists at the resolved path

## 8.5 attach
- resolves `(state_dir, name)` to path
- delegates to core attach semantics:
  - one owner by default
  - explicit takeover
  - stdin optional
  - same host-lifetime behavior as core runtime

## 8.6 resize
- resolves `(state_dir, name)` to path
- delegates to core resize semantics
- fails if session is not running

## 8.7 terminate
- resolves `(state_dir, name)` to path
- delegates to core terminate semantics
- fails if session is not running

## 8.8 wait
- resolves `(state_dir, name)` to path
- delegates to core wait semantics
- uses the same v0 host-lifetime/no-disk model:
  - valid while host/session still exists in manager world
  - exit status retained only in live host memory until consumed
  - no durable post-cleanup retrieval guarantee

## 9) Relationship to richer future layers

This manager is intentionally **not** the final human UX layer.

Expected future layering:
- core single-session runtime
- explicit directory-scoped session manager (this spec)
- richer human-oriented manager UX on top
- optional logging/replay layer
- optional TUI

The goal of this manager is to be the factual, composable base.

## 10) Why this shape is desirable

- Very small conceptual delta from the core runtime
- Easy to compose in code
- Easy to reason about for both humans and agents/tools
- Avoids premature policy around current-session semantics
- Avoids persistence while still enabling multi-session operation
- Lets richer UX be added later without contaminating the foundational library

## 11) Open questions

These should be answered before implementation, but they are intentionally narrow:

1. **Path resolution mechanics:** what minimum joining/normalization behavior is required to map `(state_dir, name)` to a concrete path without introducing manager naming policy?

## 12) Recommendation

Implement this as a separate library/module in the same repo as the core runtime.

The first implementation target should be:
- explicit library API only
- no sugar (`ensure`, `current`, `next`, `prev`)
- no persistence
- no CLI-first design

CLI should come later as a thin adapter once the library semantics are validated.
