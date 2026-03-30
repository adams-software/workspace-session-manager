# SessionServer v0 Spec

Status

Draft RFC for review.

Purpose

Define the socket-facing server layer that exposes one SessionHost to transient local clients over a Unix socket.

A SessionServer is responsible for:

- binding and owning one Unix socket endpoint
- accepting client connections
- speaking the MSR control/data protocol
- arbitrating one active attached owner connection
- forwarding PTY data between the host and the attached owner
- exposing a small remote control surface
- notifying clients of terminal session events
- cleaning up the socket endpoint on shutdown

A SessionServer is not responsible for:

- creating session names or registries
- global discovery/listing/navigation
- multi-session coordination
- logging/replay
- terminal state reconstruction
- host spawn policy beyond wrapping a provided SessionHost

---

Layering

SessionHost

Owns:
- PTY
- child process
- local session lifecycle
- exit status
- final host cleanup

SessionServer

Owns:
- Unix socket listener
- client connections
- remote protocol
- attachment arbitration
- PTY bridging
- server-side lifecycle around a single host

SessionClient

Owns:
- connecting to one server endpoint
- issuing control ops
- attaching for PTY streaming
- surfacing remote events and data to CLI/app code

Dependency direction:

SessionClient -> SessionServer -> SessionHost

Never the reverse.

---

Design principles

1. One host, one endpoint
2. Connected is not attached
3. At most one attached owner
4. Short-lived control by default
5. Explicit attach upgrade
6. Minimal pushed events
7. Simple post-exit behavior
8. Protocol reflects server semantics, not raw host mirroring

---

Scope (in)

- bind/listen on a Unix socket
- accept many transient client connections
- support short-lived control request/response connections
- support one upgraded attached connection
- enforce exclusive vs takeover attach semantics
- forward PTY bytes between host and attached owner
- expose session status/wait/terminate/resize/attach/detach semantics
- notify attached owner of terminal session events
- keep server available after host exit until explicit cleanup
- remove socket on final shutdown

Scope (out)

- global registry or manager
- named resolution policy
- next/prev/tree/workspace navigation
- screen replay/history
- multi-owner collaborative terminals
- observer/follower clients in v0
- remote networking beyond local Unix socket assumptions

---

Wire protocol v0

Transport

Unix domain socket.

Framing

4-byte little-endian length prefix followed by UTF-8 JSON payload.

Envelope

{ "type": "control_req|control_res|data|event", "payload": {} }

Rules

- control connections are strictly serialized one request / one response
- no request ids in v0
- data frames are only valid in attached mode
- event frames are host->client only
- attached mode begins only after successful attach
- base64-encoded PTY bytes are used in JSON payload for v0 simplicity

control_res

Server response.

Success:

{ "type": "control_res", "payload": { "ok": true, "value": {} } }

Error:

{ "type": "control_res", "payload": { "ok": false, "err": { "code": "attach_conflict" } } }

Important protocol note:

Do not model successful responses as one flat struct with many optional top-level fields. That becomes awkward immediately for mixed operations like:
- `status` returning lifecycle/attachment state
- `wait` returning exit status
- `exists` returning a boolean

Recommended v0 shape:
- `control_res.payload.ok`
- `control_res.payload.value` for operation-specific success data
- `control_res.payload.err` for failure data

This keeps success/failure structurally distinct and avoids abusing error fields to carry successful status-like values.

---

Remote status model

Suggested conceptual status:

```ts
type RemoteStatus = {
  host:
    | { type: "idle" }
    | { type: "starting" }
    | { type: "running" }
    | { type: "exited"; exitStatus: ExitStatus }
    | { type: "closed" };
  attached: boolean;
};
```

status

Returns current server-visible session state.

Success value:

```ts
type StatusValue = RemoteStatus;
```

Example successful response shape:

```json
{ "type": "control_res", "payload": { "ok": true, "value": { "status": { "host": { "type": "running" }, "attached": false } } } }
```

Available to any connected client.

---

Control operations

status
- observational
- available to any connected client

wait
- blocks until host exit and returns final exit status
- if host already exited: returns immediately

terminate
- requests host termination by signaling the child process
- available to any connected client in v0

attach
- requests ownership of the PTY data plane
- successful attach upgrades the connection into attached mode

resize
- owner-only control
- allowed on the attached upgraded connection in v0

detach
- owner-only control
- allowed on the attached upgraded connection in v0
- releases current attachment ownership while host keeps running

---

Attached mode semantics

In attached mode:
- `data` frames are allowed both directions
- host may emit `event` frames
- owner-only `control_req` frames are also allowed on the upgraded connection for attached-scoped controls such as `detach` and `resize`
- non-owner or general control ops should still prefer fresh short-lived control connections
- connection closes on detach/session-end/socket error
- host tracks one active **owner connection** for attached mode
- exclusive attach fails if an owner connection already exists
- takeover attach closes/replaces the prior owner connection before installing the new one
- owner state is tied to the tracked accepted connection, not just a boolean flag

Important protocol note:
Attached mode is not purely a data tunnel. It is a narrow upgraded channel carrying:
- PTY stream traffic (`data`)
- host notifications (`event`)
- a small owner-only control lane (`control_req` for attached-scoped ops)

---

Acceptance criteria

- a server can expose one host on one Unix socket
- short-lived control commands work across separate CLI invocations
- attach succeeds when unattached
- exclusive attach fails on conflict
- takeover revokes old owner and installs new owner
- PTY input/output flows correctly over attached connection
- owner-only control ops work on the upgraded connection
- attached client does not detach on stdin EOF alone
- host exit notifies attached owner
- server remains available for post-exit status/wait
- final server shutdown removes socket artifact
