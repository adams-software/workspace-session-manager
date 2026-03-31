# Recommended overall shape

## Deliverable

One binary: `msr`

## Internal library boundaries

Keep these as modules, not necessarily separate repos/packages.

* `protocol` — frame encode/decode, envelopes, error mapping
* `host` — PTY + child + lifecycle
* `server` — socket listener, connection handling, attachment arbitration
* `client` — short-lived control requests + attach upgrade
* `cli` — command parsing, stdio bridging, human-facing output
* `app` or `runtime` — glue for `_serve` mode

Then later you can add:

* `resolver`
* `manager`
* `current-session`
* `logging`

That’s enough separation to stay sane without over-fragmenting the codebase.

---

# Binary modes

I would keep exactly two categories of execution mode.

## 1. Public user commands

These are the “real” CLI surface.

Examples:

* `msr create`
* `msr attach`
* `msr status`
* `msr terminate`
* `msr wait`

These should stay thin and mostly call `client`.

## 2. Internal long-lived mode

Something like:

* `msr _serve`

This is the actual session authority process.

It owns:

* one `SessionHost`
* one `SessionServer`
* one socket path
* one session lifecycle

This mode is what `create` spawns.

That gives you a very clean process model:

* every session is one background `msr _serve` process
* no global daemon
* no central registry required

---

# Recommended source layout

Something along these lines:

```text
src/
  main.zig

  lib/
    protocol/
      frame.zig
      envelope.zig
      errors.zig

    host/
      SessionHost.zig
      Pty.zig
      Child.zig

    server/
      SessionServer.zig
      Connection.zig
      AttachState.zig

    client/
      SessionClient.zig
      SessionAttachment.zig

    cli/
      commands/
        create.zig
        attach.zig
        status.zig
        terminate.zig
        wait.zig
      io_bridge.zig
      output.zig

    app/
      serve.zig
      spawn_child.zig
      ready_signal.zig
```

Not magical, just enough separation that each layer has one job.

---

# Recommended ownership model

This is the most important thing to keep clean.

## `SessionHost`

Owns:

* PTY handle
* child process
* exit status
* host-local subscriptions
* final host cleanup

## `SessionServer`

Owns:

* Unix socket listener
* accepted connections
* attached owner connection
* mapping host events to protocol output
* socket cleanup
* shutdown after host exit

## `SessionClient`

Owns:

* one-shot control connection creation
* attach handshake
* attached connection handle
* client-side event/close normalization

## CLI layer

Owns:

* command parsing
* converting stdio to/from attachment stream
* printing status/errors
* exit codes

That ownership split is the biggest thing that will keep the implementation understandable.

---

# Strong recommendation on concurrency/threading

## Prefer a single event loop / serialized coordinator for the server process

If possible, avoid a design where:

* PTY read thread
* socket accept thread
* per-client threads
* control thread
* shutdown thread

all mutate shared state directly.

That is where you get races around:

* who is attached
* takeover timing
* exit vs detach
* connection close ordering
* socket cleanup

Instead, I’d strongly recommend:

## One authority loop owns all mutable server state

That loop is responsible for:

* current attachment owner
* connection registry
* shutdown state
* reacting to host exit
* routing PTY output to owner
* applying control ops

Then other async sources just feed events into it.

Sources of events:

* accepted client connection
* received protocol frame
* PTY output
* host exit
* socket/connection errors

But **state transitions happen in one place**.

That will save you a lot of pain.

---

# Practical concurrency model

Conceptually, use this pattern:

## Server core state

Single mutable struct, owned by one coordinator context:

* listener state
* map/list of accepted connections
* attached owner connection or null
* shutting_down flag
* host reference
* final exit status maybe cached from host

## External inputs become messages/events

Examples:

* `IncomingConnection(conn)`
* `ControlRequest(conn, req)`
* `PtyOutput(bytes)`
* `HostExited(status)`
* `ConnectionClosed(conn)`
* `ConnectionWriteFailed(conn)`
* `ShutdownRequested`

Then the coordinator handles them sequentially.

This is basically actor-ish without needing to overformalize it.

---

# Why this matters

Because the hardest bugs in this project are likely not protocol encoding.
They’re lifecycle interleavings like:

* host exits while takeover is happening
* attached client disconnects while resize arrives
* terminate returns success but host has already exited
* session_exit event races with socket close
* server shutdown removes socket while a control request is in flight

A serialized coordinator makes these manageable.

---

# Threading guidance by layer

## Host

Can be internally async/evented, but expose simple serialized semantics.

Likely sources of async:

* PTY readable
* child exit callback

That is fine, but make host’s outward-facing callbacks disciplined.

## Server

Should centralize mutation. This is the key layer to keep mostly single-threaded logically.

## Client

Can stay simple. Most operations are one-shot. Attachment has one live read loop plus writes.

## CLI

Should mostly be plumbing and shouldn’t own complex state.

---

# Good implementation discipline for shutdown

I’d explicitly define a shutdown sequence in code, not just in docs.

Something like:

1. mark server shutting down
2. stop accepting new connections
3. emit best-effort terminal event to owner
4. close owner connection
5. close all remaining accepted connections
6. remove socket path
7. detach host subscriptions
8. close host
9. mark stopped

Have one function own this path.
Do not spread it around in many callbacks.

That will help enormously.

---

# Recommended public CLI surface

Keep it very small.

## Essential commands

* `msr create <socket> -- <argv...>`
* `msr attach <socket>`
* `msr detach <socket>`
* `msr status <socket>`
* `msr terminate <socket> [--signal SIGTERM]`
* `msr wait <socket>`

`detach` is the explicit "leave session without terminating it" primitive. It is distinct from future higher-level switching/navigation UX.

This is enough to become a composable binary.

Then bash scripts can build:

* session naming
* switching
* discovery
* “current session”
* sibling navigation
* project-specific wrappers

Exactly what you want.

---

# Recommended hidden/internal CLI surface

## `_serve`

Used only by `create` or advanced debugging.

Maybe:

* `msr _serve --socket <path> -- <argv...>`

This command:

* constructs host
* constructs server
* starts host
* starts server
* emits readiness signal
* blocks until automatic shutdown completes

I would keep `_serve` intentionally narrow.

---

# Recommended `create` flow

`create` should be a thin orchestration command.

## Suggested flow

1. validate args/socket path
2. spawn `msr _serve ...`
3. wait until ready
4. return success, or optionally attach depending on UX

For readiness, a few workable options:

### Best option

Inherited pipe FD from parent to child.
Child writes “ready” only after:

* host started
* server listening

This is the cleanest.

### Simpler option

Parent polls connection attempts until server is reachable.

This is easier but a bit sloppier.

I’d slightly prefer explicit ready pipe if it’s not painful in Zig.

---

# Recommended `attach` flow

This is where CLI meets client attachment.

`attach` should:

1. create `SessionClient`
2. call `attach(mode)`
3. bridge local stdin -> attachment.write
4. bridge attachment.onData -> local stdout
5. watch for close reason
6. restore terminal state and exit appropriately

This is probably the trickiest public command because it touches terminal UX.

---

# Terminal/stdio integration guidance

Keep attach bridge separate from client library.

## Client library should not know about:

* local stdin FD
* raw mode
* terminal restoration
* signal handling for local terminal

That belongs in `cli/io_bridge`.

So the library stays transport/protocol clean, and CLI handles user terminal behavior.

---

# Recommended attach-mode CLI responsibilities

`msr attach` should probably own:

* putting local terminal in raw mode when appropriate
* reading stdin and forwarding bytes
* handling local window resize and calling `attachment.resize(...)`
* restoring terminal mode on exit
* choosing exit code based on close reason

That is definitely app/CLI territory, not client library territory.

---

# Resize integration

This one is important and easy to miss.

When attached from a real terminal:

* initial local terminal size should be sent after attach
* local SIGWINCH / resize notifications should trigger `attachment.resize(...)`

This makes the remote PTY feel correct.

Again, keep that in CLI layer, not client layer.

---

# Bash composition philosophy

You said you want a binary that can then be composed via bash scripts.

That means the binary should be:

* explicit
* stable
* low-level
* script-friendly

So I’d recommend:

## Human mode

Pretty output by default for interactive use.

## Script mode

Add simple machine-readable options later if useful:

* `--json` for `status`
* exit codes with well-defined meanings

But even before that, the primitive commands are already composable.

Examples of later shell composition:

* name -> socket mapping
* current session env vars
* switch helpers
* tree navigation
* auto-create-if-missing wrappers

That should all live outside the core binary logic at first.

---

# Good boundaries to preserve

## Keep out of core binary for now

* global registry
* automatic discovery
* workspace semantics
* policy-heavy name resolution
* nested-session UX

Those are composition-layer concerns.

Your binary should be the stable primitive they compose on top of.

That is the right move.

---

# Suggested implementation sequence

I’d build in this order:

## 1. Protocol module

* length-prefixed framing
* JSON envelope
* encode/decode helpers
* error code mapping

## 2. Host

* PTY spawn
* output callbacks
* terminate/wait/close lifecycle
* tests

## 3. Server

* listen on socket
* one-shot control req/res
* attachment arbitration
* PTY bridging
* automatic shutdown on host exit

## 4. Client

* one-shot control ops
* attach upgrade
* attachment close reasons

## 5. `_serve`

* glue host + server
* readiness signaling

## 6. CLI commands

* create
* status
* terminate
* wait
* attach

## 7. Shell composition layer

* scripts/wrappers for higher-level navigation and naming

This order will give you a working vertical slice quickly.

---

# Recommended testing strategy

Keep tests close to each layer.

## Host tests

* start/exit/wait
* PTY IO
* resize
* close after exit

## Server tests

* status over socket
* attach exclusive conflict
* takeover
* attached PTY data flow
* automatic shutdown on host exit
* socket removal

## Client tests

* control request success/failure
* attach returns long-lived handle
* close reason mapping

## CLI smoke tests

* create -> attach -> exit
* create -> terminate -> wait
* attach takeover behavior

This layering will make failures much easier to localize.

---

# On naming and docs

For implementation docs, I would describe the system in these terms:

* **Host** = local PTY-backed session owner
* **Server** = Unix-socket exposure of one host
* **Client** = remote handle to one server
* **CLI** = user-facing composition of client APIs
* **_serve** = internal long-lived session process

That vocabulary feels stable and matches the architecture well.

---

# One thing I would explicitly document for engineering

A short rule like this:

> The server is the sole coordinator of session endpoint lifecycle. The host owns process lifecycle. The client never owns final cleanup.

That single sentence will probably prevent a bunch of messy implementation decisions.

---

# My bottom-line integration proposal

Build `msr` as:

## One binary

with public commands and one hidden `_serve` mode.

## Internally modular

* `protocol`
* `host`
* `server`
* `client`
* `cli`
* `app`

## Concurrency model

Use one serialized coordinator for server state to avoid threading/race bugs.

## Default lifecycle

Host exit triggers server-owned shutdown and cleanup automatically.

## Product goal

A stable low-level binary that higher-level shell scripts can compose into naming, switching, and manager UX.


