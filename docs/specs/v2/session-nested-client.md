# Nested MSR Passthrough v0 Spec

## Status

Current working v0 direction.

This document now reflects the simplified routed owner-control path that matches the implementation:

- short-lived requester RPC via `control_req { op: "owner_forward", request_id, action }`
- routed owner-stream request via `owner_control_req`
- owner reply via `owner_control_res`
- final requester completion via `control_res`

---

## Purpose

Define the **nested passthrough client** used when `msr` is invoked **from inside an already attached MSR-managed session**.

This layer exists to solve one specific problem:

- a command run inside the remote shell must not create a second nested terminal-owning attachment
- instead, it must ask the **current outer attached client** to perform the action

Nested passthrough is therefore a small control-routing extension over the existing session socket protocol.

For v0, do not use generic lanes. Keep the protocol narrow and explicit around routed owner control.

---

## Scope

### In scope

- defining when `msr` is considered nested
- passthrough semantics for `attach <target>`
- passthrough semantics for `detach`
- routing through the current session server to the current outer attached client
- routed owner-control over the existing transport
- implementation guidance for server and outer attached client behavior

### Out of scope

- general nested administration of sessions
- `wait`
- `terminate`
- `create`
- history/back/forward
- broad multiparty routing abstractions
- workspace/global discovery beyond already-resolved target sockets

---

## Design goals

1. Prevent accidental nested attachments
2. Keep the outer attached client as the sole terminal owner
3. Reuse the existing session socket and framed JSON protocol
4. Add structure only where routed control genuinely needs it
5. Keep nested mode explicit and narrow
6. Fail clearly when passthrough is unavailable

---

# 1. Mental model

There are three relevant actors.

## 1. Current session server

The server for the **current session** identified by `MSR_SESSION`.

## 2. Outer attached client

The long-lived local `msr attach` process that currently owns:

- the real terminal
- the attached connection to the current session server

## 3. Nested client

A new `msr` invocation running **inside the shell/process hosted by the current session**.

The nested client must not become a new terminal owner.
Instead, it sends a routed request to the current session server, which forwards it to the outer attached client.

The outer attached client then performs the top-level action.

---

# 2. When nested mode applies

A CLI invocation is considered **nested** when:

```text
MSR_SESSION=/absolute/path/to/current-session.msr
```

is present in the environment.

This is the primary nested-context signal.

## Important note

`MSR_SESSION` is not proof that a reachable outer attached client exists.

Therefore:

- nested passthrough commands must attempt passthrough
- if no outer attached client is reachable, they must fail explicitly
- they must not silently fall back to creating a new direct top-level attachment

---

# 3. Nested mode surface

Nested mode is intentionally minimal.

## Supported passthrough commands

- `attach <target>`
- `detach`

## Optional informational behavior

- `help`
- very lightweight nested-context-aware `status` output if desired later

## Explicitly out of scope for v0

- `wait`
- `terminate`
- `create`
- arbitrary remote exec
- broader routing mechanisms

---

# 4. Behavior summary

## `attach <target>` in direct mode

Normal behavior:

- this process connects directly to the target session server
- this process becomes the attached client for that session

## `attach <target>` in nested mode

Passthrough behavior:

1. connect to the current session server from `MSR_SESSION`
2. send `control_req { op: "owner_forward", request_id, action: { op: "attach", path: target } }`
3. current session server forwards `owner_control_req` to the current outer attached client
4. outer attached client detaches from current session and attaches to target session
5. outer attached client replies with `owner_control_res`
6. server returns final `control_res` to the nested requester

This is effectively a switch, but the visible command remains `attach`.

## `detach` in nested mode

Passthrough behavior:

1. connect to current session server
2. send `control_req { op: "owner_forward", request_id, action: { op: "detach" } }`
3. current session server forwards `owner_control_req` to the current outer attached client
4. outer attached client detaches its current top-level attachment
5. outer attached client replies with `owner_control_res`
6. server returns final `control_res` to the nested requester

---

# 5. Safety rule

## No silent fallback

In nested mode, if passthrough is unavailable:

- `attach` must fail
- `detach` must fail

It must not silently degrade to:

- a new direct attach
- a nested interactive attach inside the PTY

That would recreate the nested-stack behavior this feature is meant to prevent.

---

# 6. Relationship to existing protocol

The current session socket already carries a framed protocol with:

- `control_req`
- `control_res`
- `data`
- `event` (defined, though not yet actively emitted by server)

The current attached-owner connection already supports:

- PTY `data` traffic
- owner-scoped `control_req` / `control_res`

This nested passthrough spec **reuses that protocol foundation**.

## Design choice

Do **not** introduce a separate nested-only transport or a second protocol stack.

Prefer:

- existing transport
- existing framing
- existing PTY `data` messages
- existing one-shot `control_req` / `control_res`
- a narrow explicit routed owner-control message flow

---

# 7. Routed owner-control protocol

## 7.1 Transport

Same Unix socket endpoint identified by:

```text
MSR_SESSION
```

## 7.2 Framing

Same framing as the main session protocol:

- 4-byte little-endian length prefix
- UTF-8 JSON payload

## 7.3 Recommendation

Use a narrow routed owner-control request/response flow.

This keeps:

- PTY stream traffic separate from routed control traffic
- directionality explicit
- request/response correlation lane-local
- server routing logic simpler and less brittle

Lane behavior should follow `lane-messaging-protocol.md`.

## 7.4 First lane kind

Recommended first lane kind:

- `owner_control`

This lane kind exists specifically for nested passthrough and server->owner routed control.

## 7.5 Recommended owner_control methods

### `attach`

Lane request:

```json
{
  "type": "call",
  "seq": 1,
  "method": "attach",
  "args": {
    "path": "/abs/path/to/target.msr"
  }
}
```

Meaning:

- ask the current outer attached client to attach to `path`

### `detach`

Lane request:

```json
{
  "type": "call",
  "seq": 1,
  "method": "detach"
}
```

Meaning:

- ask the current outer attached client to detach from the current session

## 7.6 Expected first response shapes

For v0 owner_control usage, these should be unary calls:

- `call -> return`
- or `call -> error`

Recommended successful response:

```json
{
  "type": "return",
  "seq": 1,
  "value": {}
}
```

Recommended failure response:

```json
{
  "type": "error",
  "seq": 1,
  "error": {
    "code": "no_owner_client"
  }
}
```

## 7.7 Server routing semantics

When the current session server receives a nested passthrough request:

1. verify that a current owner connection exists
2. open or bind a corresponding `owner_control` lane toward the owner client
3. route lane turns between nested client and owner client
4. return the routed terminal result to the nested caller

If no owner exists:

- return lane error

If owner passthrough is unsupported:

- return lane error

If owner action fails:

- return lane error

---

# 8. Owner-side protocol adaptation

The current recommendation is now to use explicit lane messaging for routed owner control.

## Recommendation

Do not continue growing ad hoc forwarded control ops on the attached stream.

Instead:

- keep owner-local controls like `detach` and `resize` on the existing attached control path
- add explicit lane handling for routed owner-control traffic
- keep PTY `data` outside the lane system for now

## Why

The attached owner connection already multiplexes:

- PTY stream traffic
- direct owner-local control
- future server-initiated routed control

Minimal explicit lanes are the cleanest way to separate those responsibilities without replacing the rest of the protocol.

## Owner-side behavior

The outer attached client must become a state machine that can process:

- PTY `data`
- direct owner-local control responses
- lane opens / lane requests for `owner_control`

Recommended behavior on routed lane `call(method="attach")`:

1. validate payload
2. detach/close current attachment cleanly
3. attempt top-level attach to target session
4. if success, continue as terminal owner on the new target
5. answer the lane request with `return` or `error`

Recommended behavior on routed lane `call(method="detach")`:

1. detach current attachment cleanly
2. release current attachment ownership
3. answer the lane request with `return` or `error`

---

# 9. Error model

Recommended routed owner-control error codes:

- `not_nested`
- `no_owner_client`
- `owner_control_unsupported`
- `invalid_args`
- `attach_conflict`
- `permission_denied`
- `transport_error`
- `internal`

## Notes

- `attach_conflict` should be reused if the requested target attach fails due to exclusive ownership conflict
- `permission_denied` should be reused where the current ownership model naturally implies it
- prefer reusing existing error code vocabulary where meaningful rather than inventing a second naming scheme

---

# 10. Nested client library

## Purpose

Provide a tiny internal client library for nested passthrough behavior.

This should be an internal module inside `msr`, not a separate top-level product.

## Proposed shape

```ts
type NestedClientOptions = {
  currentSocketPath: string;
};

interface NestedClient {
  attach(targetSocketPath: string): Promise<void>;
  detach(): Promise<void>;
}
```

### Semantics

#### `attach(targetSocketPath)`

- connects to `currentSocketPath`
- sends `control_req { op: "owner_forward", request_id, action: { op: "attach", path: targetSocketPath } }`
- waits for `control_res`
- resolves on success
- rejects on failure

#### `detach()`

- connects to `currentSocketPath`
- sends `control_req { op: "owner_forward", request_id, action: { op: "detach" } }`
- waits for `control_res`
- resolves on success
- rejects on failure

This library is intentionally tiny.

It is not:

- a full `SessionClient`
- a general multi-session manager
- a new terminal owner

---

# 11. CLI behavior

## Same CLI, different mode

The visible CLI remains `msr`.

The CLI chooses between:

- direct mode
- nested passthrough mode

based on:

- command
- `MSR_SESSION`
- command support

## `msr attach <target>`

### If `MSR_SESSION` is unset

Use normal direct attach behavior.

### If `MSR_SESSION` is set

Use nested passthrough behavior:

1. resolve target socket path
2. create nested client using `MSR_SESSION`
3. send `owner_forward(attach(target))`
4. do not attempt direct nested attach if passthrough fails

## `msr detach`

### If `MSR_SESSION` is unset

Use direct/non-nested detach semantics if supported by the CLI surface.

### If `MSR_SESSION` is set

Use nested passthrough behavior:

1. create nested client using `MSR_SESSION`
2. send `owner_forward(detach)`
3. do not fall back to anything that creates a nested interactive bridge

---

# 12. Recommended CLI UX text

Examples:

### No nested context

```text
msr attach: nested passthrough unavailable (MSR_SESSION not set)
```

### No owner client

```text
msr attach: current session has no reachable outer attached client
```

### Unsupported owner control

```text
msr attach: current outer client does not support owner-control passthrough
```

### No fallback

Do not print misleading text implying a direct nested attach was attempted.

---

# 13. Implementation guidance

## 13.1 Server changes

The session server currently knows:

- the current owner connection fd
- how to accept one-shot control connections
- how to read/write on the owner connection

To support nested passthrough, extend it to:

- recognize `control_req { op: "owner_forward", request_id, action }` on non-owner control connections
- reject with `no_owner_client` if no owner exists
- forward `owner_control_req` to the attached owner connection
- wait for `owner_control_res`
- return a final `control_res` to the nested requester

## 13.2 Correlation strategy

For v0, use a narrow routed owner-control request id on the short-lived requester RPC:

- requester sends `request_id`
- server forwards that `request_id` inside `owner_control_req`
- owner replies with matching `owner_control_res.request_id`
- server resolves the pending routed request and returns final `control_res`

Do not use generic lane sequencing for v0.

This gives us explicit correlation without overbuilding the first implementation.

## 13.3 Outer attached client changes

The outer attached client currently behaves mostly like a stdio bridge.

It must become a slightly smarter attached-state machine that can process:

- PTY data
- owner-local control responses
- lane traffic for routed owner-control

Recommended first lane methods:

- `attach`
- `detach`

Recommended behavior on routed owner_control `attach`:

1. validate payload
2. detach/close current attachment cleanly
3. attempt top-level attach to target session
4. if success, continue as terminal owner on the new target
5. return lane `return` or `error`

Recommended behavior on routed owner_control `detach`:

1. detach current attachment cleanly
2. release current attachment ownership
3. return lane `return` or `error`

## 13.4 Serialization

Keep this owner-client switching logic serialized with the rest of the attached connection state.

Do not handle routed switching in a side thread that mutates attachment state independently.

The same reason the server moved toward a coordinator model applies here:

- attach/detach/switch races are lifecycle bugs, not throughput problems

## 13.5 Capability discovery

Do not overdesign capability negotiation in v0.

Acceptable first implementation:

- server attempts routing only if current owner implementation is known to support it
- otherwise return `owner_control_unsupported`

Capability discovery can be formalized later if needed.

---

# 14. DSM / WSM integration

This nested passthrough exists primarily to unlock DSM / WSM traversal and switching.

## DSM

Commands like:

- `dsm attach <name>`
- `dsm next`
- `dsm prev`
- `dsm first`
- `dsm last`

can resolve a target socket path and then invoke:

```bash
msr attach <resolved-target>
```

When run inside an attached session, this becomes nested passthrough and cleanly switches the outer top-level client.

## WSM

Commands like:

- `wsm j ...`
- `wsm next`
- `wsm prev`

can do the same at a broader scope.

This is the main product reason nested passthrough exists.

---

# 15. Security / trust assumptions

This is a local-only system.

Assumptions:

- communication is local
- access is constrained by filesystem/socket permissions
- nested passthrough trusts the current session server to route only to the current owner client for that session

This spec does not introduce remote/network trust assumptions.

---

# 16. Acceptance criteria

This spec is successful if:

1. `msr attach <target>` inside an attached session does not create a nested terminal-owning attachment.
2. Instead, it routes a request to the current outer attached client.
3. The outer client can cleanly detach from the current session and attach to the target.
4. `msr detach` inside an attached session can detach the current outer attached client.
5. If no owner client is reachable, nested passthrough fails explicitly.
6. No silent fallback to nested direct attach occurs.
7. The implementation largely reuses the existing framed JSON transport and PTY/data model.
8. Routed owner-control uses a minimal explicit lane layer instead of ad hoc forwarded control ops.

---

# 17. Summary

Nested MSR passthrough should be understood as:

> a tiny routing extension over the existing MSR control protocol that reinterprets `attach` and `detach` inside an attached session as requests to the current outer attached client.

The key recommendation is:

- reuse existing transport and framing
- reuse `control_req` / `control_res` where possible
- keep the new routed operation surface tiny
- only introduce a new attached-stream command envelope later if the owner-side state machine truly needs it

That gives DSM and WSM a clean path to switching without inventing a separate protocol stack.
