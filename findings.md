# findings.md — msr v2 rewrite

## Source of truth
- v2 specs under `docs/specs/v2/` are the design authority going forward.
- Backward compatibility is explicitly not required.
- Existing code is disposable and should be evaluated only for reusable mechanics, not for architectural preservation.

## Checkpoint / branch state
- Created checkpoint branch: `v1-checkpoint-2026-03-30`
- Stashed uncommitted spec work on that branch with message: `v2-spec-checkpoint-2026-03-30`
- Returned active development branch to: `master`

## Current code inventory

### Keep / mine for reusable mechanics
These areas contain implementation value even if the surrounding abstraction changes.

#### `src/lib.zig`
Keep for parts, not as-is.
Reusable mechanics:
- PTY creation / child spawn (`forkpty` path)
- socket bind/listen + stale socket reclaim logic
- resize via `TIOCSWINSZ`
- wait / pollExit patterns
- framing bridge ideas for attached mode
- concurrency lessons around detached attach worker lifecycle

But the current `Runtime` type is architecturally overloaded: it mixes host, server, registry, and lifecycle orchestration.

#### `src/rpc.zig`
Mostly adaptable.
Reusable:
- length-prefixed framing
- JSON envelope helpers
- basic control/data/event envelope shape

Needs likely redesign to match finalized v2 message semantics and clearer ownership of parsing/copying.

#### `src/client.zig`
Partially adaptable.
Reusable:
- Unix socket connect
- short-lived request/response helper shape
- attach handshake + stream bridge direction

Needs redesign because v2 client API is more explicit (`SessionClient` vs `SessionAttachment`) and current code leaks protocol details / lifecycle assumptions.

### Adapt, but demote from architecture center

#### `src/main.zig`
The current command surface is close to the intended low-level CLI, so the file is a useful reference.
But implementation should be rebuilt over real host/server/client boundaries instead of the current `Runtime` blob.

#### tests embedded in `lib.zig`
A lot of good behavioral coverage exists. Preserve the scenarios, not necessarily the exact structure.
Notable valuable scenarios:
- stale socket reclaim
- attach conflict / takeover
- host remains responsive during attached streaming
- wait / cleanup edge cases

### Likely discard / replace

#### `src/manager.zig`
Older directory-scoped manager-centric architecture. Deleted from the active repo surface during the v2 cleanup.

#### `src/manager_v2.zig`
Earlier bound-context Zig manager direction. Deleted from the active repo surface during the v2 cleanup.

#### `src/app.zig`
Old app-layer architecture above manager_v2. Deleted from the active repo surface during the v2 cleanup.

#### `src/nav.zig`
Older encoded-path/navigation layer incompatible with current DSM/WSM direction. Deleted from the active repo surface during the v2 cleanup.

#### `src/lib.zig` + `src/rpc.zig`
Now legacy/quarantined. They remain only as the old runtime/test surface and are no longer part of the active v2 module graph.

## Architectural diagnosis
The repo currently contains two conflicting designs:

1. **Older path**
- `Runtime`
- `manager`
- `manager_v2`
- `app`
- `nav`

2. **New v2 path**
- `SessionHost`
- `SessionServer`
- `SessionClient`
- `msr` low-level CLI
- DSM shell layer
- WSM shell layer

The main risk is incremental compromise: continuing to evolve the old architecture while verbally committing to the new one.
Recommendation: avoid that. Rewrite aggressively around the new boundaries.

## Recommended target layering

### Layer 1: SessionHost
Owns only:
- PTY
- child process
- host lifecycle
- exit status
- local cleanup

Must not know about:
- sockets
- clients
- attach arbitration
- workspace/manager concepts

### Layer 2: SessionServer
Owns only:
- Unix socket listener
- accepted connections
- protocol handling
- one attached owner arbitration
- PTY forwarding between host and owner
- server shutdown and socket cleanup

Must wrap one `SessionHost` and delegate host semantics.

### Layer 3: SessionClient
Owns only:
- connect to one endpoint
- one-shot control requests
- explicit attach upgrade
- local attachment handle semantics

Must remain thin and not become a manager.

### Layer 4: `msr` CLI
Low-level stable contract for:
- create
- attach
- status
- wait
- terminate
- maybe ping
- internal `_host` / `_serve` style mode

### Layer 5: DSM / WSM
Shell-first composition only.
No Zig-side “manager architecture” should be allowed to regrow here unless absolutely necessary.

## Rewrite sequencing recommendation
1. Define new module/file layout explicitly.
2. Rebuild SessionHost first and prove lifecycle correctness.
3. Rebuild SessionServer around SessionHost.
4. Rebuild SessionClient.
5. Rebuild `msr` CLI over those three layers.
6. Only then delete obsolete manager/app/nav paths and move on to DSM/WSM.

## Proposed v2 file/module layout

Target Zig layout should make the architecture visible in the filesystem:

```text
src/
  main.zig                 # low-level msr CLI only
  root.zig                 # top-level exports if needed
  host.zig                 # SessionHost
  server.zig               # SessionServer
  client.zig               # SessionClient + SessionAttachment
  protocol.zig             # wire framing + message types
  os/                      # optional low-level PTY/process/socket helpers if needed
    pty.zig
    unix_socket.zig
```

And explicitly demote/remove the older architecture files:

```text
src/lib.zig         -> split apart or replaced by root.zig + host/server
src/rpc.zig         -> rename/evolve into protocol.zig
src/manager.zig     -> remove after replacement
src/manager_v2.zig  -> remove after replacement
src/app.zig         -> remove after replacement
src/nav.zig         -> remove after replacement
```

### Module responsibilities

#### `host.zig`
Exports the v2 SessionHost boundary only.
- start
- resize
- terminate
- wait
- close
- PTY IO callbacks/stream
- host state inspection

#### `server.zig`
Wraps one SessionHost.
- listener lifecycle
- control request handling
- attach arbitration
- attached owner stream bridging
- post-exit server behavior
- socket cleanup

#### `client.zig`
Client-side endpoint binding.
- one-shot control calls (`status`, `wait`, `terminate`)
- `attach()` upgrade
- `SessionAttachment` handle
- close-reason mapping

#### `protocol.zig`
Protocol-only code.
- frame read/write
- message structs/enums
- encode/decode helpers
- no lifecycle logic

#### `main.zig`
Thin CLI only.
- parse args
- construct host/server/client flows
- provide hidden internal mode (`_host` or `_serve`)
- no manager/workspace semantics

## First implementation slice recommendation

### Slice 1 — Host extraction
Goal: extract a real `SessionHost` from the current `Runtime`/`lib.zig` blob without carrying socket/client concerns along.

Deliverables:
- `src/host.zig`
- dedicated host tests
- clear state machine matching `session-host.md`

Status:
- initial extraction is now in place
- `zig build test-host` passes
- current host supports spawn/resize/terminate/wait/close with explicit lifecycle state
- PTY streaming/event callbacks are still missing and should be the next hardening step

What to reuse from current code:
- `forkpty` child spawn path
- resize (`TIOCSWINSZ`)
- wait/pollExit logic
- exit status caching patterns

What not to carry forward:
- session hashmap
- listener/socket ownership
- attached client state
- RPC handling

### Slice 2 — Server extraction
Goal: one SessionServer wrapping one SessionHost, exposing one Unix socket.

Deliverables:
- `src/server.zig`
- `src/protocol.zig`
- server tests for control/attach/takeover/exit behavior

Status:
- initial listener/control/attach work is in place
- takeover work exposed the limit of the current implicit per-connection-thread approach
- v2 server should now pivot toward a serialized coordinator model, per `docs/specs/v2/integration-guide.md`

What to reuse from current code:
- one-socket framing approach
- accept/connect patterns
- stale-socket reclaim logic
- the v1 revocation insight: bridge workers should not compete with takeover path for final connection cleanup

New architectural direction:
- one authority loop should own mutable server state
- accepted connections, current owner, shutdown state, and host-exit reactions should be serialized through that coordinator
- takeover should become a state transition handled by the coordinator, not ad hoc cross-thread fd manipulation

### Slice 3 — Client rebuild
Goal: align to `session-client.md` instead of current attach helper shape.

Deliverables:
- rebuilt `src/client.zig`
- explicit `SessionClient` / `SessionAttachment` surfaces
- client tests for control calls + attach close semantics

### Slice 4 — CLI cutover
Goal: keep CLI low-level and stable.

Deliverables:
- rebuilt `src/main.zig`
- hidden host/server mode
- command semantics fixed enough for DSM/WSM

## Important red flags to keep in mind
- The current `Runtime` struct is too central and should not survive as the core abstraction.
- The current CLI is closer to the future than the current library architecture is.
- DSM/WSM should not be re-imported into Zig as a rich manager stack out of convenience.
- Stable CLI contract matters before shell tooling begins.
- Lifecycle correctness bugs are more dangerous here than missing UX features.
- Protocol response shape needs a real success payload model (`value` or equivalent); ad hoc per-field success structs become awkward immediately for ops like `status`.
- Takeover should be specified first as reliable disconnect-and-replace semantics. A courtesy `taken_over` event is nice, but should not be required until delivery ordering and connection teardown are race-safe.
- Default build/test surfaces should reflect the v2 architecture. Legacy `Runtime` tests can remain available, but they should not define whether the active v2 path is considered green.
