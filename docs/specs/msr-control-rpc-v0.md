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

Use a **tiny framed protocol over the existing Unix session socket path** with a simple v0 model:

- short-lived **control connections** for request/response ops
- one long-lived **attached connection** for PTY data stream after explicit attach handshake
- optional `event` frames from host for notifications

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
{ "type": "control_req|control_res|data|event", "payload": { } }
```

Rules:
- No request IDs in v0 (strict serialized req/res on control connections).
- `data` frames carry PTY bytes (base64 in JSON for v0 simplicity).
- `event` frames are host->client notifications only (no response required).

Examples:
```json
{ "type": "control_req", "payload": { "op": "resize", "cols": 120, "rows": 40 } }
{ "type": "control_res", "payload": { "ok": true, "value": {} } }
{ "type": "control_res", "payload": { "ok": false, "err": { "code": "session_not_found" } } }
{ "type": "data", "payload": { "stream": "stdin", "bytes_b64": "..." } }
{ "type": "event", "payload": { "kind": "session_exit", "code": 0 } }
```

## 6) Operations

Control operations (serialized req/res, mirrored to runtime API):
- `exists(path)`
- `create(path, opts)` *(host/admin lane)*
- `attach(path, mode)`
- `resize(path, cols, rows)`
- `terminate(path, signal?)`
- `wait(path)`

Optional (internal/debug):
- `ping()`

Data operations:
- `data` frames from client -> host map to PTY stdin writes
- `data` frames from host -> client map to PTY stdout/stderr bytes

Response shape:
- success: `control_res { ok: true, value: <function return> }`
- error: `control_res { ok: false, err: { code, message? } }`

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

### 8.1 Control connection (default)
For normal command handling:
1. accept connection
2. read one `control_req`
3. execute runtime op
4. write one `control_res`
5. close connection

### 8.2 Attached connection (special upgraded mode)
Attach handshake:
1. client connects
2. client sends `control_req { op: "attach", ... }`
3. host sends `control_res { ok: true|false, ... }`
4. if success: connection enters **attached mode**

In attached mode:
- `data` frames are allowed both directions
- host may emit `event` frames
- control ops are intentionally narrow/minimal; non-attach control commands should use fresh control connections
- connection closes on detach/session-end/socket error

This keeps attached behavior explicit and avoids turning attached clients into generic long-lived RPC peers in v0.

## 9) CLI / application behavior

- `msr create` still spawns `_host` and waits for ready.
- `msr exists/resize/terminate/wait` open short-lived control connections and do one req/res.
- `msr attach [--takeover]` sends attach request and, on success, enters attached mode for data frames.
- Nested `msr` usage remains viable via explicit attached-mode behavior plus optional event notifications.

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
- v0 protocol supports:
  - short-lived strict req/res control connections
  - explicit attach mode transition
  - data frames in attached mode
  - optional host->client event frames
- Tests cover happy path and one representative failure per op.
