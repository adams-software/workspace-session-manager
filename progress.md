# progress.md — msr binary/interface spec

- Initialized planning artifacts: `task_plan.md`, `findings.md`, `progress.md`.
- Drafted `docs/specs/msr-binary-interface-v0.md` with minimal single-binary + hidden host-mode design.
- Included: goals/non-goals, command surface, lifecycle semantics, exit codes, and 5 implementation slices.
- Updated spec with explicit layering principle: library semantics, host transport, CLI passthrough.
- Implemented Slice A skeleton in `src/main.zig`:
  - command parser/dispatch for `create|attach|resize|terminate|wait|exists|_host`
  - help/usage output
  - placeholder create/_host wiring to current in-process runtime
- Implemented first Slice B step:
  - `create` now spawns detached same-binary `_host` process (`fork` + `execvp`) and waits for socket readiness.
  - `_host` still owns runtime lifecycle (`create` + `wait`).
- Verified with `zig build test` and `zig build run -- --help`.
- Note: remote control forwarding for `resize/terminate/wait` to host is not wired yet.
