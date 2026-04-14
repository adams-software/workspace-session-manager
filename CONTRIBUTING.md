# Contributing

Thanks for taking a look at Workspace Session Manager.

## Current project posture

This project is still an actively evolving tool suite.

Please assume:

- the public surface is still settling
- terminal behavior is an active area of refinement
- small focused fixes are easier to review than broad rewrites

## Good contributions

High-value contributions right now include:

- build/test fixes
- docs and quickstart improvements
- packaging/install polish
- bug fixes with minimal repro steps
- narrow terminal-behavior fixes with clear before/after behavior

## Before opening a PR

Please:

1. build from the repo root
2. run the test suite
3. sanity-check any touched shell scripts with `bash -n`
4. keep the change as narrow as practical

Typical local checks:

```bash
zig build
zig build test
bash -n wsm/scripts/wsm
bash -n wsm/scripts/wsm_menu
bash -n scripts/build_dist.sh
```

## Style expectations

- prefer small, composable changes
- avoid introducing hidden control paths when ordinary PTY/runtime semantics are enough
- keep package boundaries honest
- extract shared utilities only when the shared part is truly generic
- prefer clear docs and examples over clever abstractions

## Bugs and repros

If you file a bug, the most helpful thing is a minimal repro.

Please include when possible:

- command(s) run
- expected behavior
- actual behavior
- whether the issue reproduces under `msr`, `vpty`, `alt`, or `wsm`
- terminal/environment details if they seem relevant

## Discussion

If you are unsure whether a cleanup or refactor is desirable, opening an issue first is totally fine.
