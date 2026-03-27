# msr Control RPC v0 — Proposal

Status: proposed

## 1) Problem

`msr` now has core runtime primitives and a detached `_host` mode, but control commands (`exists`, `resize`, `terminate`, `wait`) are still mostly process-local calls in the invoking CLI process.

That creates a mismatch:
- session state lives in `_host`
- user commands run in short-lived CLI processes
- without a control channel, CLI cannot reliably act on host-owned runtime state

Result: `create` can start real sessions, but the rest of the CLI is not consistently operating on the same authoritative runtime.

## 2) Goals

- Keep single-binary architecture.
- Keep library semantics in `src/lib.zig` as source of truth.
- Add a minimal, local-only control protocol between CLI and `_host`.
- Avoid protocol/framework complexity (no gRPC, no heavy schemas, no extra daemon infra).
- Make layering explicit so core runtime behavior is unchanged and only composed by higher-level adapters.

## 3) Non-goals (v0)

- Networked/remote control.
- Versioned multi-client public API guarantees.
- Rich discovery/list endpoints.
- Multi-op transactions.

## 4) Recommended solution

Use a **tiny framed protocol over the existing Unix session socket path** with two logical lanes on one connection:

- **control lane**: strict serialized request/response (one in-flight request at a time)
- **data lane**: PTY byte flow messages

Optional later:
- **event frames** (unsolicited notifications like session exit)

Key point: this composes on top of the core runtime; it does not redefine core semantics.

This preserves architecture boundaries:
- library = semantics (create/attach/resize/terminate/wait)
- host = transport adapter + orchestration
- CLI/app = passthrough + UX

## 5) Wire format (v0)

### Framing
- 4-byte little-endian length prefix
- followed by UTF-8 JSON payload

### Envelope
All messages use one envelope shape:
```json
{ "type": "control_req|control_res|data|event", "id": 1, "payload": { } }
```

Rules:
- `id` is required for `control_req` and `control_res`.
- For v0 control lane, only one request may be in-flight at a time (serialized req/res).
- `data` frames carry PTY bytes (base64 in JSON for v0 simplicity).

Examples:
```json
{ "type": "control_req", "id": 1, "payload": { "op": "resize", "cols": 120, "rows": 40 } }
{ "type": "control_res", "id": 1, "payload": { "ok": true } }
{ "type": "data", "payload": { "stream": "stdin", "bytes_b64": "..." } }
{ "type": "event", "payload": { "kind": "session_exit", "code": 0 } }
```

## 6) Operations

Control operations (serialized req/res):
- `exists`
- `resize`
- `terminate`
- `wait`
- `attach` (enables data forwarding semantics for the connection)

Optional (internal/debug):
- `ping`

Data operations:
- `data` frames from client -> host map to PTY stdin writes
- `data` frames from host -> client map to PTY stdout/stderr bytes

## 7) Error mapping (protocol-level)

Map `RuntimeError` to stable string codes:
- `invalid_args`
- `session_not_found`
- `session_already_running`
- `session_running`
- `permission_denied`
- `unsupported`
- `internal`

CLI prints human-readable messages, exits non-zero.

## 8) Host behavior

For each accepted connection:
1. keep connection open
2. parse framed messages continuously
3. route by envelope type:
   - `control_req` -> execute runtime op -> emit `control_res`
   - `data` -> write bytes to PTY stdin (when attached)
4. while attached, forward PTY output as `data` frames
5. optionally emit `event` frames (e.g. session_exit)
6. close on socket hangup/error

Control lane rule:
- one in-flight control request per connection (serialized req/res)

This keeps implementation simple and nested usage viable (control + data over one socket).

## 9) CLI / application behavior

- `msr create` still spawns `_host` and waits for ready.
- `msr exists/resize/terminate/wait` send serialized control requests to `<path>`.
- `msr attach [--takeover]` sends control attach request and starts data-frame bridging.
- Nested `msr` usage is supported because control and data can coexist on one persistent connection.

## 10) Why this is the best fit now

- Minimal code and conceptual overhead.
- No second socket, no service registry.
- Matches current single-session identity model.
- Keeps future evolution open (can add op fields later without major redesign).
- Mirrors how `atch`-style local control channels work in practice.

## 11) Risks and mitigations

1. **Attach/control multiplex complexity on one socket**
   - Mitigation: strict one-request-per-connection model; `attach` explicitly upgrades mode.

2. **Protocol drift**
   - Mitigation: tiny envelope + fixed error strings + focused tests.

3. **Backward compatibility (early stage)**
   - Mitigation: mark as v0 internal protocol; no stability promise yet.

## 12) Incremental implementation plan

### Step A
Add `rpc.zig` helpers:
- frame read/write
- envelope encode/decode
- error mapping

### Step B
Implement host request loop for one-shot control ops:
- `exists`, `resize`, `terminate`, `wait`

### Step C
Switch CLI commands to RPC path.

### Step D
Implement `attach` handshake + stream upgrade and CLI attach bridge.

### Step E
Add smoke tests:
- create -> exists
- resize -> terminate -> wait
- attach connect/disconnect

## 13) Architecture contract (explicit)

- Core runtime semantics remain in library (`src/lib.zig`) and must not be reimplemented in transport/app layers.
- Host layer may orchestrate and frame I/O, but should delegate operation semantics directly to runtime primitives.
- CLI/application layer should stay thin: parse input, send protocol messages, render output.
- Any richer UX/features should be additive composition above this contract.

## 14) Acceptance criteria

- All public CLI commands act on host-owned state, not local ephemeral runtime.
- `create`, `attach`, `terminate`, `wait` work end-to-end across separate CLI invocations.
- Protocol supports persistent connection with serialized control lane + data lane.
- Tests cover happy path and one representative failure per op.
