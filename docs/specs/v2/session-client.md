# SessionClient v0 Spec

Status

Draft RFC for review.

Purpose

Define the client-side library for interacting with one SessionServer over a Unix socket.

A SessionClient is responsible for:

- connecting to one server endpoint
- issuing short-lived control requests
- upgrading a connection into attached mode
- exposing PTY streaming and owner-only controls through an attachment handle
- mapping protocol responses/events into a usable local API

A SessionClient is not responsible for:

- session discovery or naming policy
- current-session environment semantics
- workspace/session navigation
- global orchestration
- retries/backoff policy beyond basic transport behavior
- multi-session coordination

---

Layering

SessionClient -> SessionServer -> SessionHost

---

Design principles

1. Thin client
2. One endpoint at a time
3. Short-lived control by default
4. Attachment is explicit
5. Connected is not attached
6. Hide wire details where practical
7. Surface ownership in the API shape

---

API shape

```ts
type ExitStatus = {
  code: number | null;
  signal: string | null;
};

type RemoteStatus = {
  host:
    | { type: "idle" }
    | { type: "starting" }
    | { type: "running" }
    | { type: "exited"; exitStatus: ExitStatus }
    | { type: "closed" };
  attached: boolean;
};

type AttachMode = "exclusive" | "takeover";

type AttachmentCloseReason =
  | { type: "detached" }
  | { type: "taken_over" }
  | { type: "session_ended"; exitStatus: ExitStatus }
  | { type: "server_closed" }
  | { type: "error"; error: Error };
```

```ts
interface SessionClient {
  status(): Promise<RemoteStatus>;
  wait(): Promise<ExitStatus>;
  terminate(signal?: string): Promise<void>;
  attach(mode?: AttachMode): Promise<SessionAttachment>;
}

CLI note:
- the public `msr` CLI may expose a convenience `detach <path>` command implemented by opening an owner-scoped attachment and issuing `detach()` on that attachment.
- this is a user-facing primitive for leaving a live session without terminating it; it does not by itself define multi-session switching semantics.

interface SessionAttachment {
  write(data: Uint8Array): Promise<void>;
  resize(cols: number, rows: number): Promise<void>;
  detach(): Promise<void>;

  onData(cb: (data: Uint8Array) => void): () => void;
  onClose(cb: (reason: AttachmentCloseReason) => void): () => void;
}

Protocol note:
The upgraded attachment connection is not data-only. The attachment handle is responsible for sending both:
- `data` frames for PTY stdin/write traffic
- owner-only `control_req` frames for attached-scoped controls like `resize()` and `detach()`
```

---

status(): Promise<RemoteStatus>

Performs a one-shot control request.

Notes:
- purely observational
- valid whether session is attached or not

Protocol note:

Client code should expect successful control responses to carry operation-specific data inside a success payload object (for example `payload.value.status`), rather than assuming one flat response struct shared by all operations.

---

wait(): Promise<ExitStatus>

Performs a one-shot control request that may block until session exit.

---

terminate(signal?): Promise<void>

Performs a one-shot control request.

---

attach(mode?): Promise<SessionAttachment>

Performs attach handshake and upgrades the connection into attached mode.

---

Acceptance criteria

- client can perform status, wait, and terminate over short-lived control connections
- attach upgrades a connection and returns a long-lived handle
- attached handle can send PTY input and receive PTY output
- owner-only controls live on the attachment handle
- attachment close reasons are surfaced cleanly
- protocol details are hidden behind the client library surface
