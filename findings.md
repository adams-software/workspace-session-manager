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

## Important bug we fixed
The decisive post-switch bug was on the switched-to destination server:
- after target/session shutdown, `session_host.getMasterFd()` became null
- the server still had an attached owner
- `pumpOwnerIo()` treated `no master fd` as a benign early return
- so it never dropped the owner / closed the switched attachment socket
- the owner bridge then waited forever after target shutdown

Fix: if an owner is attached but `getMasterFd()` is gone, treat that as `pty_closed` and drop the owner.
