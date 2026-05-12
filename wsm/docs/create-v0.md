# wsm create v0

## Purpose

`wsm create` defines the canonical session-id model for `wsm`.

This means `create` is responsible for the initial conventions that later power:

- `attach <target-or-query>`
- session navigation (`prev`, `next`, `in`, `out`, `first`, `last`)
- detached boot UX
- router retargeting against canonical session references

## Runtime model

`wsm` may start detached.

Detached is a first-class runtime state:

- no session is currently attached
- no initial target is required on launch
- detached state must support at least `create` and `attach`
- navigation actions are unavailable until a current session exists

## Canonical session id

A canonical session id is a slash-separated logical path.

Examples:

- `api`
- `api/dev`
- `api/dev/server`

### Segment rules

Each segment must:

- be non-empty
- not equal `.` or `..`
- match `[a-z0-9._-]+`

The full id must:

- not start with `/`
- not end with `/`
- not contain `//`

No cwd-derived inference is part of v0.
Users provide explicit canonical ids.

## Backing path mapping

Given workspace root `ROOT` and canonical id `a/b/c`:

- session socket path: `ROOT/a/b/c.wsm`
- transcript path later: `ROOT/a/b/c.typescript`

Parent directories are created as needed.

The canonical id model is purely lexical. There is no metadata graph in v0.

## Create command

## Surface

`wsm create <id> [-- <cmd...>]`

### Behavior

1. Validate canonical id.
2. Map canonical id to backing socket path.
3. Reject if the backing session already exists.
4. Create parent directories as needed.
5. Create the backing `msr` session at the mapped socket path.
6. Use `$SHELL -i` when no explicit child command is provided.
7. Return or surface the canonical id that was created.

### Collision behavior

If `ROOT/<id>.wsm` already exists, `create` fails.

v0 does not support:

- implicit reuse
- auto-suffixing
- rename-on-collision

## Attach resolution

`attach <target-or-query>` resolves in this order:

1. exact canonical id match
2. exact basename match if unique
3. otherwise fail as ambiguous or not found

This resolution model consumes the same canonical ids defined by `create`.

## Navigation semantics

Navigation is lexical and directory-shaped.

- parent of `api/dev` is `api`
- direct children of `api` are `api/*` with exactly one more segment
- `prev` and `next` operate among lexical siblings in the same parent directory
- `first` and `last` operate among lexical siblings in the same parent directory
- `in` selects the first lexical direct child
- `out` selects the exact lexical parent if it exists

## Non-goals for v0

v0 does not define:

- inferred names from cwd
- metadata-backed hierarchy
- rename or move operations
- rich create presets
- logs UX
- multi-step picker flows
- broad router lifecycle behavior

## Implementation order

Recommended order:

1. detached-first `wsm` boot state
2. canonical id validation and mapping
3. real `create`
4. attach/query resolution against the same model
5. router child integration on top of that model
