# Minimal Session Runtime Library (MSR) v0 Spec

## Status
Draft RFC for review.

## Purpose
Define a **single-session runtime primitive** library.

MSR is not a global session manager. It provides explicit APIs to start/attach/detach/control one session runtime endpoint. Higher-level indexing/discovery/navigation is intentionally out of scope.

---

## Design principles
1. **Library first**: runtime/CLI is a thin adapter.
2. **Single-session primitive**: no global discovery assumptions.
3. **Explicit over implicit**: caller passes explicit addressing/config.
4. **Safe defaults**: no accidental host-path traversal in name mode.
5. **Small surface**: lifecycle + attach transport + recursion safety.

---

## Scope (in)
- create/start one session runtime
- attach/detach one client to a known endpoint
- kill/remove known session runtime artifacts
- explicit name/path resolver hooks (optional)
- ancestry/self-attach recursion guard

## Scope (out)
- global listing/indexing/discovery requirements
- tree/workspace semantics (`next/prev/in/out`)
- logging/replay
- TUI/UX concerns
- multi-host federation

---

## Core concepts

### Session endpoint
A running session is reachable through a concrete endpoint (Unix socket path).

### Addressing modes
A call can identify a target by:
- explicit `path` (preferred in v0), or
- logical `name` + explicit resolver config (optional extension)

Resolver is caller-owned policy. Library should not assume one fixed namespace.

---

## API (v0)

```ts
type ExitStatus = {
  code: number | null;
  signal: string | null;
};

type SpawnOptions = {
  argv: string[];
  cwd?: string;
  env?: Record<string, string>;
  cols?: number;
  rows?: number;
};

interface IO {
  write(data: Uint8Array): Promise<void>;
  onData(cb: (data: Uint8Array) => void): () => void;
  onClose(cb: () => void): () => void;
}

type CloseReason =
  | { type: "detached" }
  | { type: "peer_closed" }
  | { type: "session_ended"; exitStatus: ExitStatus }
  | { type: "runtime_closed" }
  | { type: "error"; error: Error };

interface Attachment {
  detach(): Promise<void>;
  onClose(cb: (reason: CloseReason) => void): () => void;
}

type AttachMode = "exclusive" | "takeover";

interface Runtime {
  exists(path: string): Promise<boolean>;
  create(path: string, opts: SpawnOptions): Promise<void>; // throws if exists/running
  attach(path: string, io: IO, mode?: AttachMode): Promise<Attachment>; // single-attacher with optional takeover
  resize(path: string, cols: number, rows: number): Promise<void>;
  terminate(path: string, signal?: string): Promise<void>;
  wait(path: string): Promise<ExitStatus>;
}
```

### Behavioral notes
- `create(path, opts)` fails if session already exists/runs.
- Callers can probe with `exists(path)` before create.
- Runtime is single-attacher at core level.
- `attach(..., "exclusive")` (default) fails when another attacher owns the session.
- `attach(..., "takeover")` closes prior attacher and grants ownership to new attacher.

---

## Attachment close semantics
`onClose` is terminal for an attachment and must fire when attachment becomes unusable for any reason.

This includes:
- local intentional detach (`detached`)
- ownership takeover by a new attacher (`peer_closed` in v0, or dedicated `taken_over` in v0.1)
- remote peer close (`peer_closed`)
- session runtime exit (`session_ended`)
- runtime shutdown (`runtime_closed`)
- internal errors (`error`)

So `detach()` should cause `onClose` with `{ type: "detached" }`.

---

## Safety requirements
- Prevent self/ancestor recursive attach loops.
- Validate addressing conflicts if optional name+resolver mode is enabled.
- Refuse destructive operations on running sessions unless explicit termination is requested.
- Name-based mode (if enabled) must remain within resolver scope/root.

---

## Error model
Typed errors (examples):
- `ErrInvalidArgs`
- `ErrAddressConflict`
- `ErrSessionNotFound`
- `ErrSessionAlreadyRunning`
- `ErrSessionRunning`
- `ErrAttachRecursion`
- `ErrPermission`

Wrappers format human-facing messages.

---

## Thin runtime CLI (optional adapter)
A minimal runtime CLI may expose only:
- `create/open`
- `attach`
- `current` (optional helper)
- `terminate`
- `remove`

No manager/navigation features are required in this layer.

---

## Testing requirements
- lifecycle integration tests (create/attach/terminate/remove)
- `exists` correctness tests
- recursion guard tests
- close-reason conformance tests
- stale endpoint handling tests

---

## Success criteria
- Session runtime can be started, detached, and reattached using known endpoint.
- No global manager assumptions required.
- API remains minimal, explicit, and composable.

---

## Follow-on specs (separate docs)
- **Session Manager spec**: indexing/discovery/listing
- **Navigation UX spec**: sibling/tree/workspace commands
- **Logging spec**: optional log/replay behavior

---

## Open decisions
- Whether v0 should include optional `name+resolver` mode or keep `path`-only strictly.
- Exact signal name enum/string policy for `terminate`/`ExitStatus.signal`.
- Whether to introduce a dedicated close reason for takeover (`taken_over`) in v0.1.
