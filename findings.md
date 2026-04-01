# Findings

## Runtime / protocol
- The lane pivot was the right move for nested owner control. The old ad hoc forwarded-control approach got muddy as soon as the server needed to initiate owner-side work.
- Extracting the owner attach/bridge loop into `src/attach_runtime.zig` was a major improvement. It immediately exposed a test harness gap: the routed detach test originally forwarded a lane to an owner fd that had no consumer loop running.
- Routed `owner_control.detach` is now functionally proven through the real runtime path: requester -> server -> owner runtime -> server -> requester.
- `SessionAttachment` lifecycle was too sharp. Making `close()` idempotent and having `detach()` invalidate/close the fd is the right direction.

## Testing / harness
- We hit a real friction point with the Zig build/test harness in this environment: long-lived stuck `zig build` sessions accumulate easily, and the wrapper often hides useful output when a test blocks or aborts.
- This means the product code should become more testable on its own. We should not rely on full opaque end-to-end runs as the primary debugging tool for lifecycle-heavy features.
- The best response is architectural, not just operational:
  - smaller runtime helpers
  - fewer giant live-loop tests
  - clearer ownership/cleanup semantics
  - layered testing strategy (protocol/unit -> runtime logic -> integration)
- The latest routed-attach hang reinforced the feedback from `server-implementation-feedback.md`: the interesting correctness questions are still too entangled with sockets, poll loops, and teardown timing. We should move more of the owner/routed-request lifecycle into a model-first transition layer before spending more time on heavy end-to-end debugging.

## Recommended testing strategy
1. **Protocol/unit tests**
   - framing
   - lane encode/decode
   - message validation
2. **Runtime logic tests**
   - lane method dispatch
   - attach/detach execution helpers
   - ownership/lifecycle transitions
   - avoid full PTY/server orchestration where possible
3. **Integration tests**
   - keep only a few focused vertical slices:
     - routed detach success
     - routed attach success
     - one or two failure modes
4. **Operational guardrails**
   - bounded reads
   - bounded server stepping helpers
   - deterministic teardown ordering in tests
   - aggressive cleanup of stale build/test sessions during debugging

## Architectural lesson
- This feature is genuinely hard (PTY + sockets + ownership transfer + switching), but the current pain level is not purely inevitable. Some of it comes from too much logic being trapped inside one monolithic live runtime loop and too much trust placed in opaque integration runs.
- The right move is to keep refactoring toward smaller, composable runtime helpers and a clearer layered test strategy.

## Current checkpoint state
- **Do not keep:** generic lanes as the v0 direction
- **Keep:** one explicit owner, PTY stream for attached owner, short-lived control RPC, and narrow routed owner-control for nested `attach(path)` / `detach`
- **Do not keep doing:** heavy live integration runs as the main debugging loop
- **Proven:** routed `owner_control.detach` through the real runtime path (under the current prototype path)
- **Partially implemented / unstable:** routed `owner_control.attach` (current prototype path)
- **Refactors in progress:**
  - extracted `attach_runtime`
  - public owner-control handler seam
  - decision/execution split (`decideOwnerControlLaneReq`, `executeOwnerControlDecision`)
  - narrow runtime test target (`test-attach-runtime`)
- **Main remaining uncertainty:** switched attachment ownership / cleanup lifecycle after attach, and how to reset the server/runtime around a smaller explicit owner-control RPC model

## Reset decision
For v0, prefer:
- one explicit attached owner at a time
- PTY stream on the owner connection
- one-shot control calls for ordinary control RPC
- narrow routed owner-control RPC only for nested `attach(target)` and `detach`

Do not continue growing the generic lane abstraction for v0.

## Routed attach/detach status
The routed v0 path now works end-to-end under the simplified architecture:
- requester sends `control_req { op: "owner_forward", request_id, action }`
- server forwards `owner_control_req`
- owner bridge handles the request and replies `owner_control_res`
- server relays final `control_res` to the requester

This is now proven for both routed `detach` and routed `attach(target)` in the focused integration path.

## Docs cleanup status
The key v2 docs now reflect the working routed owner-control path:
- `control-rpc.md`
- `session-nested-client.md` (intro/current-state sections)
- `routed-owner-control-v0.md`

The old dedicated lane spec has been removed from this repo.
There are still stale lane-heavy sections deeper in `session-nested-client.md`; those should be pruned or rewritten in a dedicated doc rewrite pass rather than mixed into implementation debugging.

## Binary usability status
The routed nested attach/detach path now works underneath and is wired through the top-level `msr` binary.

Current binary direction:
- one `msr` binary
- resolve current-session context from `--session=/path` first, then `MSR_SESSION`
- nested `attach <target>` and nested `detach` route through explicit `NestedClient`
- no silent fallback to direct nested attach when passthrough fails

There is now a repeatable real-binary smoke path:
- `python3 -u scripts/smoke_msr_binary.py`

That smoke currently validates:
- direct attach
- nested detach via `--session`
- nested attach via `--session`
- nested attach via `MSR_SESSION`

## Important bug we fixed
The decisive post-switch bug was on the switched-to destination server:
- after target/session shutdown, `session_host.getMasterFd()` became null
- the server still had an attached owner
- `pumpOwnerIo()` treated `no master fd` as a benign early return
- so it never dropped the owner / closed the switched attachment socket
- the owner bridge then waited forever after target shutdown

Fix: if an owner is attached but `getMasterFd()` is gone, treat that as `pty_closed` and drop the owner.

## Terminal UX / attach lifecycle lessons
- The bash/readline corruption (tab completion redraw weirdness, cursor/edit-region desync, backspacing into what should have been stable prompt/output) was not fixed by output write-all alone. The decisive missing piece was **correct PTY size at initial attach time**.
- A later `SIGWINCH`-only strategy was insufficient because the session could spend its whole initial interactive period with stale/default dimensions until the user manually resized the outer terminal.
- We first tried attach-time size sync through the old `attachment.resize(...)` request/response RPC. That transport shape was wrong for attach bootstrap and caused intermittent `attach stream failed` regressions.
- The better model, borrowed from `atch`, is: **client-driven attach metadata over the live attach stream; host applies it**.
- In `msr`, this became `owner_resize` on the attachment stream, consumed directly by the server owner loop and applied to the PTY host.
- Initial attach-time `owner_resize` + host-side `SIGWINCH` after applying the new size fixed the remaining readline/tab-completion problem.
- Raw local tty mode during attach, restore-on-exit, and `writeAll(...)` to stdout are all still necessary and justified. They are not speculative hacks.
- The attach-start `tcflush(...)` experiment was not required once initial size sync was correct, so it was removed to keep the final path minimal.

## CLI / docs lessons
- Nested mode should not pretend to be a different reduced CLI if most commands still work. The clean rule is: **all commands remain available; only `attach` and `detach` change behavior under current-session context**.
- For recognized commands with missing args, dumping full global help is poor UX. Command-specific error + one-line command usage is much better.
- Compact help was better than the earlier verbose version, but a pure manpage skeleton was still too context-light. The current best shape is a hybrid: `NAME`, `DESCRIPTION`, `USAGE`, `COMMANDS`, `CURRENT SESSION`, `NESTED MODE`.
- `msr current` is a useful nested/current-session introspection primitive and matches the detach/current-session mental model cleanly.

## Current checkpoint status (post-terminal UX fixes)
- `create -a` works and no longer crashes.
- Session child env correctly receives `MSR_SESSION`.
- Nested/current-session context is functional enough for `current`, `attach`, and `detach` UX.
- Attach terminal behavior is now substantially improved and usable for interactive bash/readline work.
- Remaining deferred topic: whether to redesign the CLI into a path-first form is still an open product question, not part of this checkpoint.


## Parser architecture lessons
- The most robust CLI structure here is a two-layer design:
  1. generic argv grammar parser (`argv_parse`) that handles command token selection, options, positionals, and `--`
  2. app-specific matcher/validator (`cli_parse`) that maps alias sets and command semantics into typed `msr` commands
- The generic parser should parse the slice it is actually given; it should not assume `argv[0]` is always the executable name. That assumption caused a real executable/parser contract mismatch during integration.
- Short options should be treated as flags by default at the generic layer. Long options may support `--opt=value` / `--opt value`, but boolean long flags still need app-layer validation so they do not silently consume following positionals.
- Parser-owned allocations (for example duplicated literal tails after `--`) need an explicit ownership/deinit path once the parse result becomes a typed command object.

## Nested detach / owner-forward hang lessons
- The nested detach hang is not primarily a parser bug and likely not a `nested_client` bug. The core symptom is: client waits indefinitely in synchronous `rpcCall()` when the server never produces a terminal response frame.
- `server_model` already covered many logical owner states, but there was still an operational hole around stale/broken owner-forward delivery in `server.zig`.
- The dangerous path was: pending requester installed, delivery of `owner_control_req` to stale owner fails, server step error gets swallowed, requester never receives a final reply.
- Hardening the forwarding path to drop the owner on failed owner-control delivery materially improved this.
- Swallowing `session_server.step()` errors in `_host` was also a real operational hazard. Failing closed there is safer than continuing after a fatal server-side error.
- Even with server-side fixes, a bounded client-side timeout on blocking RPC waits is worth keeping as a safety net so this class of bug cannot reappear as an infinite hang.
