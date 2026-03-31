# V0 Reset Plan — Narrow Routed Owner-Control RPC

## Status

Working reset plan.

This note replaces the earlier assumption that generic lane messaging should be the primary v0 direction.

## Core decision

For v0, prefer a smaller architecture built around:

- one explicit attached owner at a time
- PTY stream on the attached owner connection
- one-shot control RPC for ordinary control operations
- narrow routed owner-control RPC only for nested:
  - `attach(target)`
  - `detach`

## What we are not doing for v0

- no generic lane protocol as the main architecture
- no broad bidirectional sub-conversation system
- no generic multiplexed routing model beyond what nested attach/detach actually require

## Why

The lane prototype helped expose the shape of the problem, but it also added more abstraction than the current behavior needs.

The simpler model is easier to reason about, easier to test, and matches the main invariant more directly:

> one explicit attached owner at a time.

## v0 command surface

Nested mode supports only:

- `attach <target>`
- `detach`

If `MSR_SESSION` is set and passthrough fails, do not silently fall back to a direct nested attach.

## Immediate implementation order

1. Freeze v0 command surface (`attach`, `detach` only in nested mode)
2. Define minimal routed owner-control message model in `protocol.zig`
3. Add unified Message parse/encode/free layer
4. Replace top-level `owner_fd` + `pending_lane` with an explicit owner session state model
5. Centralize owner cleanup and pending-routed-request resolution
6. Rework server handling into:
   - short-lived control connections
   - owner-stream messages
   - PTY events
7. Update outer attached owner stream to process routed owner-control messages
8. Implement routed owner-control behavior for:
   - `attach(path)`
   - `detach`
9. Add tiny `NestedClient` internal library
10. Add CLI mode selection based on `MSR_SESSION`
11. Add model-first tests, protocol tests, and one focused nested integration path
12. Remove dead lane abstractions and duplicated message parsing branches

## Testing strategy

### Layer 1 — protocol/unit
- message roundtrips
- parse/encode/free
- routed owner-control message validation

### Layer 2 — runtime/state-model
- owner state transitions
- attach conflict
- takeover
- no owner
- owner busy
- pending request cleanup on disconnect/failure

### Layer 3 — focused integration
- nested routed detach success
- nested routed attach success
- one or two failure paths

Avoid using heavy opaque integration runs as the primary debugging surface.

## Architectural note

The most important structural invariant for v0 is not “messages can route flexibly.”
It is:

> exactly one attached owner exists at a time, and switching/detach semantics are defined explicitly around that fact.

That should drive the runtime and server design more than protocol generality.
