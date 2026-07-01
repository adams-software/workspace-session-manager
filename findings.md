# Findings & Decisions

## 2026-07-01 Package Audit Kickoff

### Scope Decision
- The product is considered largely finalized feature-wise.
- This audit should bias toward simplification, architectural cleanup, correctness issues, shared-logic extraction, and stale layering instead of new feature work.

### Package Inventory
- Core product-facing packages:
  - `wsm`
  - `vpty`
  - `ptylog`
  - `scroll`
- Runtime / transport / protocol packages:
  - `msr`
  - `ptyio`
  - `ctlwire`
  - `term_engine`
- Peripheral packages:
  - `attach`
  - `alt`
  - `shared`

### Initial Review Order Decision
- Audit `wsm`, `vpty`, `ptylog`, and `scroll` first.
- Rationale:
  - they carry most user-visible behavior
  - they are where recent bugs/fixes clustered
  - they are the most likely places to find duplicated policy/runtime boundaries and refactor wins

### Existing Cleanup Baseline
- Recent `wsm` cleanup already removed several dead APIs and some duplicated helper logic.
- A quick build-graph sweep did not show an obvious dead top-level package/module still hanging off the main build.
- Remaining likely wins are now more architectural/package-internal than obvious dead dependency removal.

## 2026-07-01 WSM Package First-Pass Notes

### Package Shape
- `wsm` is still the largest/highest-churn package in the repo:
  - `main.zig` 573 lines
  - `policy.zig` 560 lines
  - `ui_state.zig` 494 lines
  - `cli_main.zig` 387 lines
  - `service.zig` 367 lines
  - `executor.zig` 350 lines
- That split is much healthier than before the command-layer refactor, but it still suggests multiple boundaries worth pressure-testing:
  - UI/input loop
  - command planning/orchestration
  - workspace/index policy
  - transport/session attachment
  - low-level service/runtime spawning

### Initial Architectural Smells To Audit Next
- `main.zig` is still very large for a UI loop/orchestrator and probably still owns more policy than ideal.
- `policy.zig` is carrying both cache/index responsibilities and attach/nav/query behavior; worth checking whether that remains too broad even after `commands.zig`.
- `executor.zig` is much cleaner now, but still contains a lot of message formatting / adapter logic that may or may not belong there long-term.
- `cli_main.zig` is still a fairly large mixed parser/runner/help surface, so there may be opportunities to separate parsing/help from execution concerns.

## 2026-07-01 WSM First Real Findings

### Finding 1: Initial interactive attach appears to double-pump output
- `wsm/src/main.zig:App.init()` currently does:
  1. `applyExecResult(bootstrapInteractive(...))`
  2. then an immediate extra `executor.pumpAttachedOutput(...)`
- But `applyExecResult(.attached)` already performs a post-attach resize + output pump.
- The second startup pump is effectively ignored and looks redundant.
- This is the strongest first concrete candidate for a real leftover bug/smell:
  - duplicated startup churn
  - possible startup-only visual oddities
  - avoidable complexity in the interactive bootstrap path

### Finding 2: `main.zig` still owns too much lifecycle choreography
- `main.zig` is not just a UI/input loop. It also owns:
  - interactive bootstrap semantics
  - alt-screen entry/exit
  - log-viewer mode switching
  - post-log restore/sync
  - post-attach sync behavior
  - runtime exit/error translation
- The command-layer refactor improved business-logic boundaries, but a lifecycle boundary is still missing.
- Long-term cleanup direction:
  - keep `main.zig` focused on tty loop + rendering
  - move interactive lifecycle transitions into a thinner dedicated coordinator/helper

### Finding 3: `policy.zig` still mixes structural state with UI-facing summary construction
- `Provider` currently owns:
  - workspace index/cache creation
  - nav/query resolution
  - attach candidate generation
  - passive label string construction
  - active summary string construction
- The last two are UI-facing summary/view-model behavior, not core workspace policy.
- That suggests `policy.zig` is still carrying both:
  - structural workspace truth
  - bar/presentation-prep concerns

### Finding 4: log-viewer launch duplication is higher-value than generic polish
- The CLI log path in `cli_main.zig` and the interactive log path via `main.zig -> executor.viewLogsLocal()` are still duplicated.
- Since log viewing has already had tty/lifecycle-specific bugs, this duplication is riskier than it sounds:
  - behavior can drift across surfaces
  - terminal-mode handling can diverge
  - fixes have to be remembered in 2 places
- This is still optional, but it is a more meaningful consolidation target than cosmetic cleanup.

### Finding 5: `executor.zig` still acts as both transport adapter and interactive message formatter
- `executor.zig` now has much less business logic, but it still owns a cluster of formatter helpers:
  - `attachOutcomeMessage`
  - `createInvalidIdMessage`
  - `killOutcomeMessage`
  - `backOutcomeMessage`
  - `navOutcomeMessage`
- That is acceptable for now, but it means `executor` is still slightly over-scoped:
  - transport/runtime adapter
  - plus user-facing outcome translation
- Not a bug, but worth noting as a likely future cleanup seam.

## 2026-07-01 WSM Follow-Through Implemented

### Addressed Finding 1
- Removed the extra startup `pumpAttachedOutput(...)` from `App.init()`.
- Interactive bootstrap now relies on the existing post-attach sync path inside `applyExecResult(.attached)` instead of double-pumping and discarding the second result.

### Partial Cleanup For Finding 2
- Extracted common attached-session viewport resync into `App.syncAttachedViewport(...)`.
- Both post-attach sync and post-log-viewer restore now use the same helper instead of duplicating resize/pump/error-handling choreography.
- This does not fully solve `main.zig` lifecycle overreach, but it reduces one obvious pocket of duplication.

### Partial Cleanup For Finding 3
- Moved bar/presentation string building out of `policy.zig` into new `wsm/src/bar_model.zig`.
- `policy.Provider` still owns the cached buffers, but the formatting logic is now separated from structural workspace/index logic.

### Addressed Finding 4
- Extracted shared log-viewer process launch into new `wsm/src/logs_viewer.zig`.
- Both CLI and interactive log viewing now go through the same helper.

### Addressed Finding 5
- Moved user-facing outcome/message formatting out of `executor.zig` and `cli_main.zig` into new `wsm/src/messages.zig`.
- This reduced drift risk between surfaces and makes `executor` read more like a transport/runtime adapter again.

## Requirements
- Verify whether `wsm` is already configured for Zig `0.16`.
- Identify what currently breaks on Zig `0.16.0`.
- Produce a concrete migration plan before changing source.

## Research Findings
- Local machine Zig is `0.16.0`.
- Repo-level CI and release workflows still install Zig `0.15.2`:
  - `.github/workflows/ci.yml`
  - `.github/workflows/release.yml`
- `zig build` fails immediately on Zig `0.16.0`; first-wave failures are mechanical stdlib/API changes rather than product logic regressions.
- Confirmed build blockers:
  - `std.process.argsAlloc` removed from `std.process`
  - `std.heap.GeneralPurposeAllocator` no longer available under that name
  - `std.mem.trimRight` renamed/removed in favor of `std.mem.trimEnd`
  - `std.ArrayList` default initialization patterns like `.{}`
    and `std.ArrayList(T){}` are no longer accepted in some contexts
- Representative compile failures:
  - `alt/src/main.zig:579`
  - `scroll/src/main.zig:31`
  - `vpty/src/vpty_main.zig:680`
  - `msr/src/main.zig:216`
  - `ptylog/src/main.zig:223`
  - `wsm/src/ui_state.zig:87`
  - `msr/src/host_runtime.zig:224`
  - `msr/src/host_client.zig:375`
  - `ctlwire/src/line.zig:4`
- Rough migration scope from repo grep:
  - `std.process.argsAlloc`: 7 call sites
  - `GeneralPurposeAllocator`: 4 call sites
  - `trimRight`: 2 call sites
  - `ArrayList` initialization/default-literal patterns: widespread across runtime code and tests
- Repo history shows prior Zig churn:
  - `45d60b6` `update zig in build`
  - `669ec4f` `migrating to zig 15.2`
  - `b77163b` `chore: revert to zig 15.2`
  This suggests some code may already have been partially adapted and later rolled back.

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| Use compiler-driven migration buckets | Fastest way to separate real Zig 0.16 incompatibilities from unrelated app bugs |
| Fix toolchain metadata and code in the same migration branch | Avoids a split-brain state where local dev uses 0.16 but CI still validates 0.15.2 |
| Prioritize entrypoint/runtime files first | They unblock `zig build` fastest and expose the next layer of breakages |
| Use `std.Io.Threaded.global_single_threaded.io()` for remaining absolute-path helpers | Least invasive way to satisfy Zig 0.16 `std.Io` APIs in runtime code that does not already plumb an `io` handle |
| Use libc fallbacks selectively for monotonic-clock polling and a few tty/path helpers | Quicker and lower-risk than threading `std.Io` through every runtime helper during this migration |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| Project workflow file was not at `projects/wsm/workflow.md` | Used global workflow plus project `STATE.md`; repo appears not to have a separate project workflow file |
| `zig build test` kept emitting additional failures after the first compile error set | Captured enough representative failures to build a migration plan rather than waiting for a full clean run |
| `zig build` and `zig build test` diverged late in the migration | Used `zig build` repeatedly to flush out runtime-only branches not exercised by the test target |

## Final Status
- `zig build` passes on Zig `0.16.0`.
- `zig build test` passes on Zig `0.16.0`.
- CI and release workflows are now pinned to Zig `0.16.0`.
- The repo still has a large uncommitted migration diff; no release or smoke-script verification has been done in this pass beyond build/test.

## Resources
- Repo root: `projects/wsm/workspace-session-manager/`
- Build file: `projects/wsm/workspace-session-manager/build.zig`
- CI pin: `projects/wsm/workspace-session-manager/.github/workflows/ci.yml`
- Release pin: `projects/wsm/workspace-session-manager/.github/workflows/release.yml`
- Zig stdlib references used for the migration inventory:
  - `/opt/zig/lib/std/process.zig`
  - `/opt/zig/lib/std/process/Args.zig`
  - `/opt/zig/lib/std/heap.zig`
  - `/opt/zig/lib/std/array_list.zig`

## Visual/Browser Findings
- None.
