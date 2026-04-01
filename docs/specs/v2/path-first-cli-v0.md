# Path-first CLI v0 proposal

## Goal

Make `msr` command parsing more explicit, predictable, and less brittle by moving from the current command-first shape to a path-first grammar for session-scoped operations.

This proposal is intentionally conservative:
- one socket path identifies one session
- commands that operate on a specific session should put that path first
- current-session context remains useful, but should not obscure which commands are implicitly current-session-based
- avoid parser magic beyond a small number of clearly documented shorthand forms

---

## Design principles

1. **Path-first for session-scoped operations**
   - If a command targets a specific session, the session path comes first.

2. **Current-session commands are explicit**
   - Commands that operate on the current session without an explicit path should be limited and obvious.

3. **One stable grammar**
   - Prefer a single obvious parse over multiple ambiguous spellings.

4. **Nested mode changes behavior only where necessary**
   - Nested mode should mainly affect `attach` and `detach`, not invent a separate CLI.

5. **Keep `create` special**
   - `create` naturally introduces a new path, so command-first still makes sense there.

This makes the proposal a **hybrid with path-first as the default for session-scoped commands**.

---

## Proposed top-level grammar

## Global form

```text
msr <command> ...
msr <path> <command> ...
```

### Command-first forms retained only for:
- `create`
- `current`
- `help`

### Path-first forms used for session-scoped operations:
- `attach`
- `status`
- `wait`
- `terminate`
- `resize`
- `exists`

---

## Command grammar

## 1. Create

```text
msr create <path> [-- <cmd...>]
msr create -a <path> [-- <cmd...>]
msr create --attach <path> [-- <cmd...>]
```

### Semantics
- `create <path>` creates detached
- `create -a|--attach <path>` creates and immediately attaches
- if no explicit command is provided, the default interactive shell is used

### Notes
- `create` remains command-first because it defines a new session path
- no path-first alias is proposed for v0

---

## 2. Current

```text
msr current
```

### Semantics
- prints current session path
- requires current-session context (`--session` or `MSR_SESSION`)

---

## 3. Attach

### Direct attach

```text
msr <path> attach
msr <path> attach --takeover
```

### Nested attach

```text
msr attach <target>
```

### Semantics
- path-first direct form attaches to the specified session
- nested form without leading path routes through the current session owner
- nested form does **not** support `--takeover`
- self-attach should fail explicitly

### Rationale
- direct attach is path-first
- nested attach is the one intentional exception, because it is semantically “attach from the current session to another target”

---

## 4. Detach

```text
msr detach
```

### Semantics
- detaches the current session
- requires current-session context
- no explicit-path detach form in v0

### Rationale
- detach is inherently owner/current-session scoped in the current model

---

## 5. Status

```text
msr <path> status
```

### Semantics
- prints the status of the specified session

---

## 6. Wait

```text
msr <path> wait
```

### Semantics
- waits for the specified session to exit
- prints exit status/signal

---

## 7. Terminate

```text
msr <path> terminate
msr <path> terminate TERM
msr <path> terminate INT
msr <path> terminate KILL
```

### Semantics
- default signal is `TERM`

---

## 8. Resize

```text
msr <path> resize <cols> <rows>
msr <path> resize <cols> <rows> --takeover
```

### Semantics
- owner-scoped operation on the specified session
- `--takeover` keeps its current meaning

---

## 9. Exists

```text
msr <path> exists
```

### Semantics
- prints whether the specified session socket is reachable

---

## 10. Help

```text
msr help
msr --help
msr -h
```

---

## Current-session selection

Current-session context is selected by:

1. `--session=<path>`
2. `MSR_SESSION`

`--session=<path>` overrides `MSR_SESSION`.

---

## Nested-mode behavior

Nested/current-session context does **not** create a separate CLI.

It only affects these commands:

### `msr attach <target>`
- nested routed attach through the current session owner

### `msr detach`
- detach current session

### `msr current`
- print current session path

All other path-first commands keep their normal explicit session-path behavior.

Examples:

```text
msr attach /tmp/other.sock      # nested attach through current session
msr detach                      # detach current session
msr current                     # print current session path
msr /tmp/other.sock status      # normal explicit session command
msr /tmp/other.sock wait        # normal explicit session command
```

---

## Summary table

| Intent | Proposed form |
|---|---|
| Create detached | `msr create <path>` |
| Create and attach | `msr create -a <path>` |
| Direct attach | `msr <path> attach` |
| Direct attach takeover | `msr <path> attach --takeover` |
| Nested attach | `msr attach <target>` |
| Detach current session | `msr detach` |
| Print current session | `msr current` |
| Status | `msr <path> status` |
| Wait | `msr <path> wait` |
| Terminate | `msr <path> terminate [TERM\|INT\|KILL]` |
| Resize | `msr <path> resize <cols> <rows> [--takeover]` |
| Exists | `msr <path> exists` |

---

## Why this proposal

This hybrid path-first shape keeps the grammar explicit and predictable without forcing awkward spellings for current-session operations.

### Benefits
- repeated work on the same socket becomes easier from shell history
- session-scoped commands have one obvious argument order
- nested mode remains small and explicit
- parser logic can become much simpler and more typed

### Intentional non-goals for v0
- no aggressive alias surface
- no support for many equivalent spellings
- no implicit fallback from malformed path-first forms into command-first forms
- no attempt to redesign nested attach/detach semantics beyond the current owner-routed model

---

## Open questions for review

1. Should `msr <path> detach` exist as a direct explicit detach form, or should detach remain current-session-only?
2. Should `msr status <path>` legacy command-first forms remain temporarily accepted for compatibility, or should the CLI switch hard to path-first?
3. Should `exists` remain user-facing, or only be kept as a scripting/testing primitive?
4. Should `create` gain a future path-first alias, or stay command-first permanently because it is conceptually different?
