# Routed Owner Control v0

## Status

Working v0 design and implementation note.

This note reflects the simplified routed owner-control path that now passes focused integration tests for both routed `detach` and routed `attach(target)`.

## Protocol shape

Requester sends a normal short-lived control RPC:

- `control_req { op: "owner_forward", request_id, action }`

Server forwards a dedicated owner-stream message to the attached owner:

- `owner_control_req`

Owner bridge replies on the owner stream:

- `owner_control_res`

Server relays final completion back to the original requester as a normal short-lived control response:

- `control_res`

## Supported v0 actions

For v0, routed owner control supports only:

- `detach`
- `attach(target)`

## Roles

### Requester (`SessionClient`)

Uses a one-shot RPC call:

- `ownerForward(action)`
- or narrower helpers such as `requestOwnerDetach()`

### Owner attachment (`SessionAttachment`)

Long-lived owner stream that can now carry:

- PTY `data`
- `owner_control_req`
- owner replies via `owner_control_res`

### Server

Tracks explicit owner state:

- no owner
- owner attached
- owner attached + one pending forwarded owner request

## Switch semantics

Routed attach is a real owner switch:

1. requester asks current server to forward `attach(target)`
2. current server sends `owner_control_req(attach(target))` to current owner
3. owner bridge opens a new top-level attachment to `target` using takeover mode
4. owner bridge reports success with `owner_control_res`
5. owner bridge replaces its active attachment with the new target attachment
6. old/source server observes owner disconnect and clears owner state

## Shutdown rule after switch

The switched-to destination server must not keep an attached owner alive after the session/PTY is gone.

Important rule:

> if an owner is still attached but `session_host.getMasterFd()` is gone, treat that as `pty_closed` and drop the owner.

Without this rule, the switched owner socket can remain open forever after target shutdown, causing the outer owner bridge to wait indefinitely.

## Testing note

For routed attach integration tests, the runtime must be the exclusive owner of the attachment socket.
Tests should observe bridged output through a separate pipe instead of reading the attachment fd directly from another thread.
