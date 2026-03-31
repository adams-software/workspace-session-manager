# MSR Control RPC v0 (as implemented)

## Status

Implemented behavior spec.

This document describes the current control RPC and framing protocol actually implemented in `protocol.zig`, `server.zig`, `client.zig`, and `main.zig`.

It is primarily descriptive, not aspirational.
Where helpful, it also notes the currently recommended next protocol extensions so the implementation and design docs stay aligned.

---

## Scope

This spec covers:

- frame format on the Unix socket
- control request envelope
- control response envelope
- attachment upgrade handshake
- attached-connection control requests
- currently supported control operations
- current server-side semantics and error codes

This spec does **not** define:

- directory/workspace naming or discovery
- shell-layer DSM / WSM behavior
- terminal UX conventions beyond current attach bridging
- future multi-client/event semantics not implemented today

---

## Transport

MSR uses a Unix domain stream socket.

Each message is sent as:

1. a 4-byte little-endian unsigned frame length
2. exactly that many payload bytes

Payload bytes are UTF-8 JSON.

### Frame limits currently used by the implementation

- control request/response reads: `64 * 1024` bytes max
- attached data-frame reads: `256 * 1024` bytes max

Frames larger than the receiver's limit are rejected.

---

## Envelope types

The protocol currently uses four JSON envelope types:

- `control_req`
- `control_res`
- `data`
- `event`

Of these, the control RPC primarily uses:

- `control_req`
- `control_res`

The attached-owner stream additionally uses:

- `data`
- `control_req`
- `control_res`

`event` exists in the protocol module but is not currently emitted by the server implementation.

---

## Control request envelope

Shape:

```json
{
  "type": "control_req",
  "payload": {
    "op": "status",
    "path": null,
    "cols": null,
    "rows": null,
    "signal": null,
    "mode": null
  }
}
```

### Fields

```ts
type ControlReq = {
  op: string;
  path?: string | null;
  cols?: number | null;
  rows?: number | null;
  signal?: string | null;
  mode?: string | null;
};
```

### Notes

- `op` is required.
- `path` exists in the protocol struct but is not used by the current server-side control dispatcher.
- unknown JSON fields are ignored during parsing.
- operation-specific meaning is determined entirely by `op`.

---

## Control response envelope

Shape:

```json
{
  "type": "control_res",
  "payload": {
    "ok": true,
    "value": {
      "exists": null,
      "status": "running",
      "code": null,
      "signal": null
    },
    "err": null
  }
}
```

### Fields

```ts
type ControlValue = {
  exists?: boolean | null;
  status?: string | null;
  code?: number | null;
  signal?: string | null;
};

type ControlErr = {
  code: string;
  message?: string | null;
};

type ControlRes = {
  ok: boolean;
  value?: ControlValue | null;
  err?: ControlErr | null;
};
```

### Notes

- `ok = true` means the operation succeeded.
- `ok = false` means the operation failed.
- failures are represented by `err.code` strings.
- success payloads are operation-specific and may leave unrelated `value` fields null.
- the implementation does not currently guarantee a rich `err.message`.

---

## Data envelope

Attached PTY traffic uses:

```json
{
  "type": "data",
  "payload": {
    "stream": "stdin",
    "bytes_b64": "aGVsbG8K"
  }
}
```

### Fields

```ts
type DataMsg = {
  stream: string;
  bytes_b64: string;
};
```

### Current stream values

- client -> server: `stdin`
- server -> client: `stdout`

Raw PTY bytes are base64-encoded in `bytes_b64`.

---

## Event envelope

Protocol shape exists:

```ts
type EventMsg = {
  kind: string;
  code?: number | null;
  signal?: string | null;
};
```

But the current server implementation does not emit event messages on the wire.

---

## Connection modes

There are currently two practical connection patterns.

### 1. One-shot control connection

Client flow:

1. connect to socket
2. send one `control_req`
3. read one `control_res`
4. close connection

Used for:

- `status`
- `wait`
- `terminate`
- initial attach handshake

### 2. Attached owner connection

Client flow:

1. connect to socket
2. send `control_req { op: "attach", mode }`
3. read `control_res`
4. if success, keep the same socket open as the attached-owner connection
5. exchange:
   - `data` frames for PTY input/output
   - attached-scope `control_req` / `control_res` for owner-only operations

Used for:

- PTY streaming
- `detach`
- `resize`

---

## Supported control operations

## `status`

### Request

```json
{
  "type": "control_req",
  "payload": { "op": "status" }
}
```

### Success response

```json
{
  "type": "control_res",
  "payload": {
    "ok": true,
    "value": { "status": "running" }
  }
}
```

### Status values currently returned

Derived from `SessionHost.getState()`:

- `idle`
- `starting`
- `running`
- `exited`
- `closed`

### Notes

- current client CLI treats `running`, `starting`, and `exited` as successful status-command outcomes
- other statuses currently cause nonzero CLI exit status

---

## `terminate`

### Request

```json
{
  "type": "control_req",
  "payload": {
    "op": "terminate",
    "signal": "KILL"
  }
}
```

`signal` is optional.

### Success response

```json
{
  "type": "control_res",
  "payload": {
    "ok": true,
    "value": {}
  }
}
```

### Failure response

```json
{
  "type": "control_res",
  "payload": {
    "ok": false,
    "err": { "code": "SomeHostError" }
  }
}
```

### Notes

- server delegates directly to `SessionHost.terminate(signal)`
- exact accepted signal strings are governed by host implementation / CLI conventions
- current CLI exposes `TERM`, `INT`, `KILL`

---

## `wait`

### Request

```json
{
  "type": "control_req",
  "payload": { "op": "wait" }
}
```

### Success response

Exited with code:

```json
{
  "type": "control_res",
  "payload": {
    "ok": true,
    "value": { "code": 0, "signal": null }
  }
}
```

Exited by signal:

```json
{
  "type": "control_res",
  "payload": {
    "ok": true,
    "value": { "code": null, "signal": "TERM" }
  }
}
```

### Notes

- wait is currently a control RPC that may block until the host exits
- it is host-lifetime only in v0; there is no durable retrieval after cleanup

---

## `attach`

### Request

```json
{
  "type": "control_req",
  "payload": {
    "op": "attach",
    "mode": "exclusive"
  }
}
```

### Supported modes

- `exclusive`
- `takeover`

If `mode` is omitted, server defaults it to `exclusive`.

### Success response

```json
{
  "type": "control_res",
  "payload": {
    "ok": true,
    "value": {}
  }
}
```

On success, the connection remains open and becomes the owner attachment stream.

### Failure responses

Exclusive attach while an owner exists:

```json
{
  "type": "control_res",
  "payload": {
    "ok": false,
    "err": { "code": "attach_conflict" }
  }
}
```

### Current semantics

- only one attached owner exists at a time
- `exclusive` fails if an owner already exists
- `takeover` shuts down the previous owner connection and installs the new connection as owner
- after successful attach, the socket is no longer a one-shot control connection; it becomes the long-lived attached-owner channel

---

## `detach`

`detach` is currently valid only on an attached-owner connection.

### Request

```json
{
  "type": "control_req",
  "payload": { "op": "detach" }
}
```

### Success response

```json
{
  "type": "control_res",
  "payload": {
    "ok": true,
    "value": {}
  }
}
```

### Failure response

```json
{
  "type": "control_res",
  "payload": {
    "ok": false,
    "err": { "code": "permission_denied" }
  }
}
```

### Current semantics

- only the current owner may detach
- on successful detach, the server clears `owner_fd`
- in the current implementation, after replying success on the attached connection, the server closes that owner connection
- detach leaves the underlying session running

---

## `resize`

`resize` is currently valid only on an attached-owner connection, or through a helper that first acquires owner access.

### Request

```json
{
  "type": "control_req",
  "payload": {
    "op": "resize",
    "cols": 120,
    "rows": 40
  }
}
```

### Success response

```json
{
  "type": "control_res",
  "payload": {
    "ok": true,
    "value": {}
  }
}
```

### Failure response

```json
{
  "type": "control_res",
  "payload": {
    "ok": false,
    "err": { "code": "permission_denied" }
  }
}
```

or a host-originated error code.

### Current semantics

- only current owner may resize
- non-owner resize is rejected with `permission_denied`
- server delegates to `SessionHost.resize(cols, rows)`

---

## Unsupported operations

Unknown / unsupported `op` values currently return:

```json
{
  "type": "control_res",
  "payload": {
    "ok": false,
    "err": { "code": "unsupported" }
  }
}
```

---

## Ownership model

Current server coordinator state tracks only one attached owner:

```ts
type CoordinatorState = {
  owner_fd: number | null;
  shutting_down: boolean;
};
```

### Consequences

- there is at most one live attached owner connection
- attached-owner control is per-connection, not token-based
- owner-only operations are authenticated by connection identity (`client_fd == owner_fd`)
- ownership is lost when the owner connection closes or is taken over

---

## Attached stream behavior

After successful attach:

### Client -> server

- `data` frames with `stream = "stdin"` write bytes into the PTY
- `control_req` frames may be used for owner-scoped control operations such as:
  - `detach`
  - `resize`

### Server -> client

- PTY output is sent as `data` frames with `stream = "stdout"`
- responses to owner-scoped control operations are sent as `control_res`

### Current implementation detail

The server inspects the top-level JSON `type` field on frames received from the owner connection and accepts only:

- `data`
- `control_req`

Other types are treated as protocol errors.

---

## Error codes currently observed in implementation

The wire-level `err.code` is a string.

Currently used codes include:

- `attach_conflict`
- `permission_denied`
- `unsupported`
- host error names surfaced via `@errorName(...)`

Client-side code may also collapse some failures into transport/protocol-level local errors such as:

- `ConnectFailed`
- `AttachRejected`
- `IoError`
- `ProtocolError`
- `UnexpectedEof`

These are client-library errors, not necessarily wire error codes.

---

## CLI mapping in current implementation

The public `msr` CLI currently maps onto the control RPC roughly as follows:

- `msr status <path>` -> one-shot `status`
- `msr terminate <path> [signal]` -> one-shot `terminate`
- `msr wait <path>` -> one-shot `wait`
- `msr attach <path> [--takeover]` -> attach handshake, then long-lived attached bridge
- `msr detach <path>` -> convenience command that opens an owner-scoped attachment and issues `detach`
- `msr resize <path> <cols> <rows> [--takeover]` -> helper opens owner attachment then issues `resize`
- `msr exists <path>` -> raw socket connect probe, not a control RPC op

### Important note on `exists`

`exists` is **not** implemented as a server RPC operation.
It is a client-side socket connectivity probe:

- connect succeeds -> prints `true`
- connect fails -> prints `false`

So `exists` is part of the CLI surface, but not part of the control dispatcher in `server.zig`.

---

## Recommended next protocol extensions

The currently recommended next extension is **minimal lane messaging for routed bidirectional control**, while keeping the existing transport/framing, PTY `data` messages, and one-shot `control_req` / `control_res` RPC intact.

### Why lanes are now recommended

Nested passthrough and server->owner initiated control exposed a real limitation in the current ad hoc control model:

- PTY stream traffic is free-running
- direct control RPC is simple request/response
- routed owner control needs correlation, directionality, and server-initiated sub-conversations

A minimal lane layer solves that without requiring a full protocol replacement.

### Recommended scope of the lane pivot

Keep unchanged for now:

- current transport
- current framing
- one-shot `control_req` / `control_res`
- PTY `data` frames
- existing attach handshake

Add narrowly:

- explicit lane message envelopes for routed/bidirectional control
- first lane kind: `owner_control`

### Recommended first lane use case

Nested passthrough should move to a lane-based control flow:

- nested client opens an `owner_control` lane to current session server
- server opens a corresponding `owner_control` lane to the current outer attached client
- server routes turn-based lane traffic between them
- outer client performs attach/detach and responds on the lane

### Architectural note

This is still an evolution of the existing protocol, not a second protocol stack:

- current transport stays
- current framing stays
- `data` stays the PTY stream carrier
- `control_req` / `control_res` remain valid for simple one-shot RPC
- lanes are added only where the old control model stops being sufficient

See also:
- `lane-messaging-protocol.md`
- `session-nested-client.md`

## Non-goals / not yet implemented

The current control RPC does not yet define or implement:

- multi-owner attachment
- read-only observers
- emitted event messages such as exit notifications
- durable post-exit state retrieval after socket cleanup
- control op for `exists`
- token/session-id based ownership independent of connection fd
- global discovery, switching, or workspace semantics
- minimal explicit lane messaging for routed control (recommended next, but not yet implemented)
- lane-based nested passthrough over an `owner_control` lane kind (recommended next, but not yet implemented)

---

## Summary

The current implemented control RPC is a small Unix-socket framed JSON protocol with:

- one-shot control requests for `status`, `wait`, and `terminate`
- explicit `attach` upgrade into a long-lived owner channel
- owner-scoped `detach` and `resize`
- base64-wrapped PTY byte transport via `data` frames
- single-owner arbitration with optional takeover

That is the protocol surface higher-level shell layers should treat as authoritative for the current v0 implementation.
