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
- **Keep:** lane-based nested owner-control architecture
- **Do not keep doing:** heavy live integration runs as the main debugging loop
- **Proven:** routed `owner_control.detach` through the real runtime path
- **Partially implemented / unstable:** routed `owner_control.attach`
- **Refactors in progress:**
  - extracted `attach_runtime`
  - public owner-control handler seam
  - decision/execution split (`decideOwnerControlLaneReq`, `executeOwnerControlDecision`)
  - narrow runtime test target (`test-attach-runtime`)
- **Main remaining uncertainty:** switched attachment ownership / cleanup lifecycle after attach, and how best to model the attach runtime state machine explicitly
