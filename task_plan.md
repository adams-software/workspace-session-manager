# Task Plan

## Active Task: Package-By-Package Static Audit

### Goal
Run a package-by-package static audit across `workspace-session-manager` to identify:
- correctness bugs
- architectural smells
- duplicated/shared logic that should be consolidated
- dead code or stale layering
- refactors that simplify the finalized product without adding feature churn

### Current Phase
Phase A1

### Audit Phases

#### Phase A1: Inventory And Review Order
- [ ] Confirm package/build graph and choose audit order
- [ ] Identify highest-leverage packages for first pass
- **Status:** in progress

#### Phase A2: Core Product Surface Audit
- [ ] Audit `wsm`
- [ ] Audit `vpty`
- [ ] Audit `ptylog`
- [ ] Audit `scroll`
- **Status:** todo

#### Phase A3: Runtime / Transport Audit
- [ ] Audit `msr`
- [ ] Audit `ptyio`
- [ ] Audit `ctlwire`
- [ ] Audit `term_engine`
- **Status:** todo

#### Phase A4: Peripheral / Legacy Surface Audit
- [ ] Audit `attach`
- [ ] Audit `alt`
- [ ] Audit `shared`
- **Status:** todo

#### Phase A5: Consolidation Pass
- [ ] Group findings by severity and leverage
- [ ] Identify cross-package refactor themes
- [ ] Separate “worth doing” from “pure churn”
- **Status:** todo

#### Phase A6: Delivery
- [ ] Summarize findings for David
- [ ] Propose next implementation candidates
- **Status:** todo

## Prior Task: Zig 0.16 Migration For WSM

## Goal
Make `projects/wsm/workspace-session-manager` build and pass its test suite on Zig `0.16.0`, and update repo tooling/docs so local dev, CI, and release builds all target the same Zig version.

## Current Phase
Phase 6

## Phases

### Phase 1: Discovery
- [x] Confirm current local Zig version
- [x] Run `zig build` and `zig build test`
- [x] Identify first-wave compiler breakages
- **Status:** complete

### Phase 2: Migration Plan
- [x] Group failures by API change
- [x] Check repo toolchain pins and workflow config
- [x] Write a concrete migration sequence
- **Status:** complete

### Phase 3: Toolchain Alignment
- [x] Update CI/release/docs/tooling pins from `0.15.2` to `0.16.0`
- [ ] Add one canonical place to declare the expected Zig version if the repo lacks one
- [x] Re-run workflows locally enough to validate the version bump before deeper code edits
- **Status:** complete

### Phase 4: Source Migration
- [x] Replace removed allocator and argv APIs
- [x] Replace removed/renamed `std.mem` helpers
- [x] Fix `std.ArrayList` initialization patterns across runtime code and tests
- [x] Rebuild until compile is green
- **Status:** complete

### Phase 5: Verification
- [x] Run `zig build`
- [x] Run `zig build test`
- [ ] Run focused smoke scripts for `wsm` / `ptylog` / installed-dist sanity if compile passes
- **Status:** mostly complete

### Phase 6: Delivery
- [x] Update project state and memory
- [ ] Summarize the migration diff and residual risks
- **Status:** in progress

## Key Questions
1. Is the intent to standardize on stable Zig `0.16.0` everywhere, not a `0.16-dev` snapshot?
2. Do we want the migration as one sweep, or staged as toolchain pin first and code fixes second?

## Decisions Made
| Decision | Rationale |
|----------|-----------|
| Start with real compiler runs before editing code | The breakages are mechanical and the compiler gives a better migration inventory than guessing |
| Treat this as a grouped API migration, not isolated bugs | The same 3-4 Zig changes recur across many packages |
| Plan to align CI/release pins before or with source changes | The repo still pins `0.15.2`, so local and CI behavior would diverge otherwise |

## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|
| `std.process.argsAlloc` missing on Zig `0.16.0` | 1 | Cataloged all call sites; migrate to `std.process.Args` iterator-based parsing |
| `std.heap.GeneralPurposeAllocator` missing on Zig `0.16.0` | 1 | Cataloged entrypoints; migrate to `std.heap.DebugAllocator` or the new `main` init style |
| `std.ArrayList` default initialization no longer accepted in some contexts | 1 | Cataloged representative failures; replace `.{} / ArrayList(T){}` with `.empty` or `initCapacity`/managed patterns as appropriate |

## Notes
- Repo CI and release workflows are now pinned to Zig `0.16.0`.
- This repo had prior history of moving toward newer Zig and then reverting back to `0.15.2`, which likely explains some of the partial migration patterns encountered during this pass.
