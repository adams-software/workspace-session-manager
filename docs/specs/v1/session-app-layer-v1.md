# Session App Layer v1

Status: draft

## 1) Purpose

Define the first thin application layer above the context-bound directory-scoped session manager v2.

This layer is responsible for:
- acquiring execution context
- constructing manager v2
- exposing a direct command surface
- supporting a small amount of CLI-only aliasing

It is **not** the final product shell and does not introduce deep new semantics.

## 2) Relationship to lower layers

### Core runtime
Owns single-session lifecycle and host-routed attach semantics.

### Client library
Owns attach/control client behavior.

### Manager v1
Owns explicit `(state_dir, name)` operations.

### Manager v2
Owns constructor-bound local context:
- `cwd`
- optional `current`
- local `next` / `prev`
- lifted manager operations without repeated path args

### App layer (this spec)
Owns:
- context acquisition
- default-directory rules
- command dispatch
- aliases

## 3) Design principles

- **Thin wrapper.** The app should be little more than context acquisition + method dispatch.
- **Library semantics remain primary.** App aliases must not redefine library behavior.
- **Explicit overrides win.** User-specified directory/context flags override inferred defaults.
- **Context-aware by default.** The app should feel natural both outside and inside a session.

## 4) Context acquisition

The app determines two pieces of context before constructing manager v2:
- `working_dir`
- `current_session?`

## 4.1 Explicit override wins
If the user explicitly provides a directory/context override, that value takes precedence.

## 4.2 Outside a session
If no explicit directory is provided and the process is not inside a session:
- `working_dir = shell cwd`
- `current_session = null`

## 4.3 Inside a session
If no explicit directory is provided and the process is inside a session:
- `current_session = current session identity`
- `working_dir = directory containing the current session`

This makes local session navigation operate relative to the session’s containing directory by default.

## 5) Session detection

The app should detect whether it is inside a session via environment context.

Proposed source:
- `MSR_SESSION=<full-session-socket-path>`

If present:
- the process is considered to be inside a session
- the current session identity can be derived from the path basename
- the default working directory can be derived from the path dirname

The app layer should treat this as application/runtime context, not as hidden mutable state inside lower libraries.

## 6) Command surface

The app should expose direct commands that correspond closely to manager v2 methods.

## 6.1 Utility/context commands
- `cwd`
- `current`

## 6.2 Name-based local commands
- `ls` / `list`
- `exists <name>`
- `status <name>`
- `create <name> -- <cmd...>`
- `attach <name>`
- `terminate <name>`
- `wait <name>`

## 6.3 Current-context navigation commands
- `next`
- `prev`
- `go-next`
- `go-prev`

Semantics:
- `next` / `prev` wrap around within the local sibling ordering.
- `go-next` / `go-prev` perform takeover-style switching (attach with takeover semantics).
- if `current` cannot be resolved within the local directory listing, commands should error.

These map directly to manager v2 local navigation semantics.

## 7) Alias support

The app layer may support aliases for ergonomic purposes.

Examples:
- `ls` as alias for `list`
- `gn` as alias for `go-next`
- `gb` as alias for `go-prev`
- other short forms later if desired

Rules:
- canonical command names must still exist
- aliases are CLI-only sugar
- aliases must not change the underlying library semantics

## 8) Nested-session convention

This layer may choose to treat nested-session usage as unsupported or discouraged for now.

If a nested-session attempt is detected at this layer, the app should error.

At minimum, if `MSR_SESSION` is present, the app should use that as the authoritative current session context rather than attempting to infer more complex nested relationships.

## 9) Out of scope

- rich workspace semantics beyond manager v2 local context
- fuzzy search
- deep project graph navigation
- logging/replay/scrollback
- TUI
- final product shell semantics

## 10) Why this layer is useful

It makes the system feel coherent in real usage without overbuilding:
- outside a session, it behaves relative to shell cwd
- inside a session, it behaves relative to the session’s containing directory
- commands stay close to library operations
- aliases improve ergonomics without contaminating lower layers

## 11) Open questions

1. **Canonical command naming:** should human-facing names prefer `attach` or `open` for local session activation?
2. **Alias set:** which aliases are worth supporting initially beyond `ls -> list`?
3. **Explicit override interface:** what is the minimal explicit interface (flags/args/env) for overriding inferred `working_dir` and/or `current_session`?
4. **Nested-session detection:** what exact condition constitutes a nested-session attempt in v1?

## 12) Recommendation

Implement this only after manager v2 is solid enough to serve as the primary backing library.

Implementation order recommendation:
1. context acquisition helper
2. manager v2 construction from that context
3. direct command dispatch
4. aliases
5. only then consider richer UX additions
