# host integration guide

This guide explains how to integrate with the current host-runtime split:

- the **host control client** over stdin/stdout
- the **child PTY attach client** over the Unix socket byte stream

These are separate surfaces with different jobs.

## Mental model

The current host runtime has two integration paths:

1. **host control path**
   - transport: host process `stdin` / `stdout`
   - purpose: query and control the host
   - examples: `state`, `resize`, `signal`, `exit`

2. **child PTY attach path**
   - transport: Unix domain socket
   - purpose: attach to the child terminal byte stream
   - examples: interactive terminal UI, raw input/output forwarding

The important design rule is:

- use **stdin/stdout** for host control
- use the **socket** for child terminal traffic
- do not treat the socket as a general control plane

## When to use which surface

### Use the host control client when you need

- host lifecycle/status checks
- current child/host state
- terminal size control owned by the host
- signals to the child
- a parseable command/response API for other libraries

### Use the PTY attach client when you need

- raw interactive terminal bytes
- a local terminal UI
- forwarding user keystrokes to the child
- rendering child stdout/stderr as a terminal session

## Surface summary

### Host control surface

Current command grammar is line-based and parseable:

- `ok ...`
- `err ...`
- `event ...`

Requests are sent one-per-line on stdin.

Important contract:

- one request in flight at a time
- `event ...` lines may interleave before the terminal response
- each request ends in exactly one terminal response:
  - `ok ...`
  - or `err ...`

See also:
- `../src/host_client.zig`

### Child PTY attach surface

The socket path is intentionally minimal:

- connect to the Unix socket
- read/write raw bytes
- treat it as terminal traffic, not framed messages
- last connector wins

This path is for terminal attachment only.

See also:
- `../../attach/src/main.zig`
- `../../wsm/src/session_link.zig`
- `../src/server.zig`

## Host control integration

## The current client layers

### Low-level line client

`host/src/host_client.zig` provides the transport-agnostic line protocol layer.

Responsibilities:

- format commands
- parse `ok` / `err` / `event` lines
- wait for one terminal response
- dispatch interleaved async events

This layer should work with any transport that can:

- write command lines
- read reply/event lines

That makes it easy to test with fake readers/writers before plugging in PTYs or child process pipes.

### Thin typed convenience layer

`host_client.zig` now also provides small typed helpers on top of the generic round-trip layer:

- `state(...) -> StateView`
- `resize(...)`
- `signal(...)`
- `exit(...)`

This is the intended shape for other libraries:

- keep wire parsing generic
- add small typed helpers above it
- keep transport concerns outside the parser/client core

## Typical host control setup

A library integrating with host control usually needs:

1. launch or otherwise obtain the `host` process
2. keep handles to its stdin/stdout
3. create a line-oriented reader/writer wrapper
4. call the generic or typed `host_client` helpers
5. optionally consume `event ...` lines through an event sink

### Example flow

1. start `host <socket-path> [--size <cols>x<rows>] [--] <cmd...>`
2. wait for startup output such as:
   - `event socket_listening path=...`
   - `event ready`
3. issue `state`
4. parse the `ok ...` response
5. later call `resize`, `signal`, or `exit` as needed

## Event handling guidance

If you use host control programmatically, assume events can arrive while you are waiting for a command result.

Good pattern:

- maintain exactly one in-flight command
- treat `event ...` as asynchronous notifications
- keep reading until you receive a terminal `ok` or `err` for the current request

Do not assume a clean request/response stream with no interruptions.

## PTY attach integration

## What the attach client is for

`attach/src/main.zig` is the minimal standalone raw attach debug harness.
`wsm/src/session_link.zig` is the live raw attach path used by the session
client.

This path is appropriate when you want a real terminal-facing client that:

- switches the local tty into raw mode
- forwards local input bytes to the socket
- forwards socket bytes back to the terminal
- restores local terminal state on exit

## Socket behavior assumptions

Integrators should assume:

- the socket is a raw byte stream
- only zero or one active connector matters at a time
- if a new client connects, the new client takes over
- older connector state may be shut down immediately

So attach clients should be resilient to disconnect/replacement.

## Typical PTY attach setup

1. wait until the host socket exists and `host` is ready
2. connect to the Unix socket
3. start duplex copy:
   - local input -> socket
   - socket -> local output
4. if using a real terminal, set raw mode locally
5. restore local tty settings on shutdown

## Host control + PTY attach together

A richer integration will often use both surfaces at once.

Typical split:

- **host control client** manages state, resize, lifecycle, and signals
- **PTY attach client** handles the user-visible terminal session

### Recommended architecture

- one component owns the host stdin/stdout control channel
- one component owns the socket byte stream
- keep these paths separate even if the same higher-level app coordinates them

For example:

- terminal frontend attaches over the socket
- controller process polls `state()` and issues `resize(...)`
- signal/exit operations go through the control channel, not through terminal escape hacks

## Suggested library boundaries

If you are building reusable integration code, the clean boundary is:

### `host_client`

Purpose:
- parseable host API over stdin/stdout

Should own:
- command formatting
- line parsing
- typed host helpers
- event dispatch callbacks

Should not own:
- PTY socket traffic
- terminal rendering
- local raw mode policy

### `attach client`

Purpose:
- raw terminal transport over the socket

Should own:
- socket connection
- duplex byte forwarding
- optional local raw mode
- terminal restoration

Should not own:
- structured host control commands
- host lifecycle semantics beyond reconnect/disconnect handling

## Practical advice

### For testability

Prefer testing the host control layer without a real PTY first.

Use fake readers/writers to test:

- `ok` parsing
- `err` parsing
- `event` interleaving
- typed `state` parsing
- malformed line rejection

Then add a smaller number of end-to-end tests with the real process.

### For robustness

- keep control commands serialized
- expect async events
- treat the attach socket as disposable
- expect takeover/disconnect behavior
- keep terminal-state cleanup reliable in attach clients

## What not to do

Avoid these patterns:

- sending structured control over the attach socket
- mixing host control semantics into terminal byte parsing
- assuming multiple concurrent control requests
- assuming events cannot appear mid-response
- exposing low-level OS resources in the client API just because the host has them internally

## Current recommended starting point

If you are integrating the host runtime into another library or app:

1. start with `host_client.zig` for control
2. start with `attach/src/main.zig` for a minimal standalone debug harness, or
   `wsm/src/session_link.zig` for the live integrated client path
3. keep transports separate
4. only add higher-level wrappers after the split feels correct in real use

That preserves the current architecture:

- `host_runtime` is the authoritative host core
- `host_control` owns typed control commands/results
- `host_repl` is the stdin/stdout adapter
- `host_client` is the transport-agnostic client-side control layer
- `attach` is the minimal raw child-terminal attach debug harness
- `wsm/session_link` is the live integrated attach model
