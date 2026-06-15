# Findings & Decisions

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
