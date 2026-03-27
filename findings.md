# findings.md — msr binary/interface spec

## Context carried forward
- Runtime core now supports: create (listener + forkpty), wait, terminate, resize, socket-backed attach loop.
- Current gap to usability: no stable user-facing CLI contract and no explicit host-mode lifecycle glue.
- Product direction is minimal core first; avoid expanding feature scope.

## Design constraints
- Single binary distribution.
- Hidden/internal host mode is acceptable (atch-like model).
- Single-attacher semantics remain default.
- No replay/multiplexing/logging features in v0.

## Design preference
- `msr` should have a small public command set.
- Internals may use a non-public subcommand (`_host`) so `create` can spawn detached host process with same binary.
