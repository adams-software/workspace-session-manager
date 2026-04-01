# CLI refinement v0

## Goal

Keep the current command-first CLI shape, but simplify and standardize naming and flags before introducing a generalized parser layer.

This is a refinement spec, not a grammar redesign.

---

## Decisions

## 1. Keep command-first grammar

The CLI remains command-first for now.

Examples:

```text
msr c <path>
msr a <path>
msr d
msr current
msr status <path>
msr wait <path>
msr terminate <path>
msr resize <path> <cols> <rows>
msr exists <path>
```

No path-first redesign is part of this spec.

---

## 2. Command and flag aliases are first-class

The parser should treat command names and flags as alias sets, not as one-off special cases.

### Command aliases

Canonical commands may have additional accepted names.

Examples:
- `c`, `create`
- `a`, `attach`
- `d`, `detach`

The help/docs may present one canonical form, but the parser should support all names listed for a command.

### Flag aliases

Flags should also be defined as alias sets.

Examples:
- create attach flag: `-a`, `--attach`
- force flag: `-f`, `--force`

This should be implemented through parser data/specs, not repeated ad hoc string comparisons throughout the CLI code.

---

## 3. Short command names become canonical

Use short command names as the canonical user-facing surface where chosen.

### Canonical commands

- `c` — create
- `a` — attach
- `d` — detach
- `current`
- `status`
- `wait`
- `terminate`
- `resize`
- `exists`
- `help`

### Notes
- Long-form `create`, `attach`, and `detach` may remain accepted via aliases.
- This spec separates **canonical display names** from **accepted parser aliases**.

---

## 4. Force semantics become consistent

Use `-f` / `--force` for command-local force semantics.

### Attach

```text
msr a <path>
msr a -f <path>
msr a <path> -f
msr a --force <path>
msr a <path> --force
```

Meaning:
- plain attach requests normal ownership
- `-f|--force` requests ownership takeover

`--takeover` should be removed from the intended public surface.

### Terminate

```text
msr terminate <path>
msr terminate -f <path>
msr terminate <path> -f
msr terminate <path> TERM
msr terminate <path> INT
msr terminate <path> KILL
```

Meaning:
- default is `TERM`
- explicit signal names remain supported
- `-f|--force` means immediate `KILL`

This keeps “force” semantics consistent without introducing a second command like `kill`.

### Resize

```text
msr resize <path> <cols> <rows>
msr resize -f <path> <cols> <rows>
msr resize <path> <cols> <rows> -f
```

Meaning:
- plain resize requires current ownership
- `-f|--force` requests takeover before resize

---

## 5. Create keeps explicit attach flag

```text
msr c <path>
msr c -a <path>
msr c <path> -a
msr c --attach <path>
msr c <path> --attach
msr c <path> -- <cmd...>
msr c -a <path> -- <cmd...>
msr c <path> -a -- <cmd...>
```

Meaning:
- `c <path>` creates detached
- `c -a|--attach <path>` creates and immediately attaches

`-a|--attach` remains acceptable here because it expresses a create-mode decision, not a force/takeover decision.

---

## 6. Flag ordering rule

For command-local flags:

- flags may appear either before or after the required positional arguments
- flags must appear before `--`
- `--` ends `msr` argument parsing
- all tokens after `--` are passed literally to the created child command

### Examples

Valid:

```text
msr c -a /tmp/test
msr c /tmp/test -a
msr a -f /tmp/test
msr a /tmp/test -f
msr terminate -f /tmp/test
msr terminate /tmp/test -f
msr c /tmp/test -a -- /bin/sh -i
```

Not parsed as `msr` flags:

```text
msr c /tmp/test -- /bin/sh -i -a
```

In that example, `-a` belongs to `/bin/sh`, not to `msr`.

---

## 7. Global current-session option forms

The parser should accept both:

```text
--session=<path>
--session <path>
```

Rules:
- both forms are equivalent
- both override `MSR_SESSION`
- both are handled at the global parsing layer before command-local parsing

---

## 8. Nested/current-session behavior stays as-is

Current-session context is still selected by:

1. `--session=<path>`
2. `--session <path>`
3. `MSR_SESSION`

Nested/current-session context changes only:
- `a <target>` — routed attach through current session owner
- `d` — detach current session
- `current` — print current session path

All other commands keep their normal explicit-argument behavior.

---

## Proposed help text

### USAGE

```text
USAGE
  msr c [-a|--attach] <path> [-- <cmd...>]
  msr a [-f|--force] <path>
  msr d
  msr current
  msr resize [-f|--force] <path> <cols> <rows>
  msr terminate [-f|--force] <path> [TERM|INT|KILL]
  msr wait <path>
  msr status <path>
  msr exists <path>
```

### COMMANDS

```text
COMMANDS
  c          create a session; use -a to attach immediately
  a          attach directly, or route through current session in nested mode
  d          detach the current session
  current    print the current session path
  resize     resize a session PTY; use -f to force takeover
  terminate  send TERM by default; use -f for KILL or pass TERM|INT|KILL
  wait       wait for session exit and print its status
  status     print session state
  exists     test whether a session socket is reachable
```

---

## Canonical command summary

```text
msr c [-a|--attach] <path> [-- <cmd...>]
msr a [-f|--force] <path>
msr d
msr current
msr resize [-f|--force] <path> <cols> <rows>
msr terminate [-f|--force] <path> [TERM|INT|KILL]
msr wait <path>
msr status <path>
msr exists <path>
```

### Nested forms

```text
msr a <target>
msr d
msr current
```

when current-session context is present.

---

## Non-goals

This spec does not yet address:
- path-first grammar
- compatibility/migration strategy for old names
- parser implementation details
- global option redesign beyond current-session handling

Those belong to the parser-layer design/spec that follows.
