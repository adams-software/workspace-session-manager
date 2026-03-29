# Directory-Scoped Session Manager v2

Status: draft

## 1) Purpose

Define a more ergonomic, context-bound library layer above the explicit directory-scoped session manager v1.

This v2 layer is still **library-first**, but unlike v1 it is intentionally designed so a CLI can be a very thin wrapper around it.

The key idea is:
- bind directory/session context at construction time
- remove the need to pass the directory path into every operation
- add a very small amount of local navigation ergonomics (`next`, `prev`)
- keep the underlying manager semantics explicit and low-opinion

## 2) Relationship to v1

### v1 manager
The v1 manager is explicit and factual:
- operations use `(state_dir, name)`
- no implicit context
- no `next`/`prev`
- no convenience behavior

### v2 manager
The v2 manager is a thin ergonomic layer above v1:
- directory context is bound once at construction time
- current session identity may also be bound
- operations are then expressed relative to that context

This should be understood as:

> manager v2 ~= manager v1 + bound context + a very small amount of local navigation

## 3) Design principles

- **Library first.** CLI should be a thin expression of this library.
- **Context-bound, not global.** Context is provided via constructor/init, not hidden mutable global state.
- **Explicit lower layer remains canonical.** v1 manager remains the factual substrate.
- **Minimal opinionation.** Only add ergonomics that are clearly useful in local session workflows.
- **Directory-scoped operation.** v2 stays focused on one working directory at a time.

## 4) Constructor-bound context

The v2 manager is initialized with:
- `working_dir` (required)
- `current_session` (optional; null if not currently in a session)

### 4.1 `working_dir`
This is the directory scope in which the manager operates.

All name-based operations are interpreted relative to this directory.

### 4.2 `current_session`
This is the current active session identity within the working directory, if known.

This is required only for operations that depend on a current sibling position, such as:
- `next()`
- `prev()`

If no current session is known, those operations should fail explicitly.

## 5) Utility/introspection API

The v2 manager should expose utility functions that reflect its bound context.

Suggested shape:
- `cwd() -> path`
- `current() -> ?name`

These are intentionally simple mirrors of constructor state.

## 6) Lifted manager operations

All core manager operations should remain available, but operate relative to the bound `working_dir`.

Conceptually:
- v1: `exists(state_dir, name)`
- v2: `exists(name)`

Suggested surface:
- `list() -> []name`
- `exists(name) -> bool`
- `status(name) -> Status`
- `create(name, spawn_opts) -> void`
- `attach(name, mode) -> void`
- `terminate(name, signal?) -> void`
- `wait(name) -> ExitStatus`

These should be understood as thin lifts over v1 manager operations using the constructor-bound directory context.

This layer now has two categories of operations:

### Name-based operations
These operate on an explicit session name in the bound working directory:
- `exists(name)`
- `status(name)`
- `create(name, ...)`
- `attach(name, ...)`
- `terminate(name, ...)`
- `wait(name)`

### Current-context operations
These operate on the bound context rather than an explicit target name:
- `cwd()`
- `current()`
- `next()`
- `prev()`
- possibly future `detach()`

## 7) New v2-only operations

The v2 manager should add only a very small amount of directory-local navigation.

### 7.1 `next()`
Attach/open the next session name in sorted order within the current working directory.

Behavior:
- requires `current_session != null`
- enumerates session names in `working_dir`
- finds the current session among siblings
- moves to the next session in order
- ordering should match the agreed local sibling ordering semantics

### 7.2 `prev()`
Attach/open the previous session name in sorted order within the current working directory.

Behavior mirrors `next()`.

### 7.3 `detach()` (future/current-context only)
If introduced, `detach()` should be treated as a current-context operation, not a name-based one.

It should not be modeled as equivalent to `terminate(name)`.

Conceptually:
- `terminate(name)` ends the named session process
- `detach()` stops being attached to the current session while leaving that session running

This distinction should remain explicit.

## 8) Ordering semantics

Session names in the working directory should be ordered using the same local ordering rule as earlier navigation discussions:
- numeric comparison when both names are all digits
- otherwise lexicographic comparison

This applies to `next()` / `prev()`.

## 9) Scope boundaries

## 9.1 In scope
- bound working directory context
- optional bound current session identity
- relative local operations within one directory
- `next` / `prev` among siblings in that directory
- thin library surface suitable for a thin CLI wrapper

## 9.2 Out of scope
- multi-directory/global project navigation
- virtual filesystem/path semantics
- richer workspace graph semantics
- logging/replay/scrollback
- TUI
- fuzzy selection/search
- hidden global current-session state

## 10) Why this layer exists

This layer exists to cover the high-value ergonomic gap between:
- explicit manager primitives
and
- the actual local workflow of using sessions from inside and outside a session.

It aims to get most of the usefulness of a richer session navigator while avoiding a large abstraction jump too early.

## 11) Relationship to CLI

The intended CLI relationship is:
- application/CLI determines constructor context
- library is initialized with that context
- commands are thin wrappers over library methods

This means the CLI may infer:
- working directory
- current session identity

but the library itself remains explicit once constructed.

## 12) Suggested context acquisition model

This spec does not require one specific source for constructor context, but assumes an application can provide:
- `working_dir`
- `current_session?`

For example, a future CLI may use:
- shell cwd when outside a session
- session-derived directory when inside a session
- explicit overrides when provided by the user

Those are application concerns, not core v2 manager library concerns.

## 13) Open questions

1. **Current-session identity format:** should `current_session` be stored as a name relative to `working_dir`, or as a full path resolved down to a name at construction?
2. **Behavior when current session is missing from the directory listing:** should `next()` / `prev()` fail, or attempt recovery/re-resolution?
3. **Wraparound semantics:** should `next()` from the last sibling wrap to the first, and vice versa?
4. **Attach vs open naming:** should `next()` / `prev()` conceptually attach, or return the chosen next/prev name and let the caller decide what to do?

## 14) Recommendation

Implement this as a separate library/module above the explicit v1 manager.

Implementation order recommendation:
1. context type / constructor
2. utility reflection methods (`cwd`, `current`)
3. lifted v1 manager methods without path arg
4. ordering helper for sibling names
5. `next` / `prev`

The goal is to make the future CLI thin without prematurely taking on broader workspace/navigation concerns.
