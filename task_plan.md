# task_plan.md — msr v2 rewrite

## Goal
Realign `msr` implementation to the v2 specs, treating `docs/specs/v2/*` as source of truth and all current code as disposable. Produce a clean low-level runtime (`SessionHost`, `SessionServer`, `SessionClient`), then stabilize the `msr` CLI contract, then layer DSM/WSM shell tooling on top.

## Phases
| Phase | Status | Notes |
|---|---|---|
| 0. Checkpoint v1 state | complete | Created branch `v1-checkpoint-2026-03-30`; stashed uncommitted v2 spec work; returned to `master` |
| 1. Architectural inventory | complete | Keep/adapt/discard map captured in `findings.md` |
| 2. Define v2 code skeleton | complete | Explicit host/server/client/protocol module boundaries now exist in Zig |
| 3. Rebuild SessionHost | complete | PTY + child lifecycle extracted with tests |
| 4. Rebuild SessionServer | complete | Coordinator/event-loop model in place with attach/takeover/detach/resize coverage |
| 5. Rebuild SessionClient | complete | Thin endpoint client + attachment handle rebuilt with integration tests |
| 6. Stabilize `msr` CLI | in_progress | Most user-facing commands are on v2 path; create/_host path has viable v2 serve-mode and needs final cleanup/polish |
| 7. Remove obsolete manager/app/nav architecture | in_progress | Dead legacy cluster deleted; `lib.zig`/`rpc.zig` remain quarantined legacy runtime/test surface |
| 8. Implement DSM shell layer | todo | Shell-first single-directory workflow on top of `msr` |
| 9. Implement WSM shell layer | todo | Recursive discovery and deterministic jump over DSM-style nodes |

## Success criteria
- Code structure matches v2 docs rather than the older runtime/manager/app split.
- `msr` low-level CLI is stable enough for DSM/WSM to depend on.
- Old abstractions (`Runtime`-as-blob, manager_v2/app/nav as architecture center) are either removed or clearly demoted.
- Tests are aligned to v2 boundaries: host, server, client, CLI.
- DSM/WSM remain shell composition layers, not second runtimes.

## Immediate next actions
1. Write explicit keep/adapt/discard inventory.
2. Draft target module/package layout for v2 Zig code.
3. Decide rewrite sequencing at file level (`lib.zig` split, new host/server/client files, test strategy).
4. Start with SessionHost correctness before any higher layer work.

## File-level cutover plan
- Introduce new v2 files (`host.zig`, `server.zig`, `protocol.zig`) alongside existing code first.
- Rebuild `client.zig` in place once protocol/server contracts are clearer.
- Keep `main.zig` compiling during transition, but point it progressively at new modules.
- Do **not** add new features to `manager.zig`, `manager_v2.zig`, `app.zig`, or `nav.zig`.
- Once the new CLI path is viable, remove obsolete files in one cleanup phase rather than letting both architectures linger.
