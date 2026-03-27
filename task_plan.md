# task_plan.md — msr binary/interface spec

## Goal
Define a minimal single-binary design and user-facing CLI surface for `msr` that preserves the current runtime-core constraints (single-session primitive, minimal semantics, low complexity).

## Phases
| Phase | Status | Notes |
|---|---|---|
| Draft v0 CLI + process model spec | complete | Drafted in `docs/specs/msr-binary-interface-v0.md` |
| Review/adjust command surface | in_progress | Added first CLI skeleton in `src/main.zig`; validate names/flags |
| Define implementation slices | complete | Included slices A-E in spec |

## Success criteria
- A single markdown spec exists with:
  - explicit process model (single binary, host mode)
  - command surface + examples
  - lifecycle + ownership semantics
  - error/exit code policy
  - minimal implementation plan
- Spec is clear enough to implement without re-deciding fundamentals.
