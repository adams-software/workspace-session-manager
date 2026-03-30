Below is a high-level technical README you can use as the front door before the detailed specs.

---

# MSR / DSM / WSM Technical Overview

## Purpose

This project defines a layered terminal-session system with a deliberately small core and higher-level shell composition on top.

The stack is:

* **MSR** — Minimal Session Runtime
  Low-level library/CLI for managing a **single session**
* **DSM** — Directory Session Manager
  Shell-level UX for managing sessions within a **single directory**
* **WSM** — Workspace Session Manager
  Shell-level UX for managing sessions across **nested directories under one workspace root**

The design goal is to keep the low-level runtime sharp, explicit, and composable, then build richer navigation and ergonomics outside it with simple shell tooling.

This README is meant to orient an implementation agent before reading the more detailed specs:

* `session-host.md`
* `session-server.md`
* `session-client.md`
* `directory-session-manager.md`
* `workspace-session-manager.md`

---

## Core philosophy

### 1. Separate primitives from UX

The low-level runtime should not absorb high-level navigation policy.

That means:

* **MSR** knows how to host and expose one session
* **DSM** adds naming and local-directory navigation
* **WSM** adds recursive discovery and global jump

Do not collapse these layers.

### 2. Filesystem is the registry

There is no required global daemon or metadata database.

Session identity is rooted in:

* Unix socket paths
* directory structure
* conventions like `.msr` filenames

This keeps the system inspectable and shell-friendly.

### 3. Attached session identity beats shell cwd

Once inside a session, the workspace context should come from session identity, not from whatever cwd the user later changes into inside the shell.

This is why env like `MSR_SESSION` and `WSM_ROOT` matter.

### 4. Keep state minimal

The default model is intentionally low-state:

* no global manager process
* no mandatory history stack
* no complex retained state
* no hidden multi-process orchestration unless clearly justified

### 5. Prefer explicit, computable behavior

Commands should be:

* deterministic
* scriptable
* explainable
* not dependent on opaque heuristics

Optional UX niceness like completion or interactive selection is good, but it must not become the source of truth.

---

## High-level architecture

There are three important low-level concepts:

### SessionHost

Defined in `session-host.md`.

This is the in-process owner of one session:

* one PTY
* one child process attached to that PTY
* session lifecycle
* PTY IO
* resize / terminate / wait / close

It does **not** know about sockets, clients, or multi-client arbitration.

### SessionServer

Defined in `session-server.md`.

This exposes one `SessionHost` over a Unix socket:

* listener/socket ownership
* request/response control protocol
* attached-mode upgrade
* one attached owner connection at a time
* PTY forwarding
* cleanup on host exit

It does **not** define discovery, workspaces, directory navigation, etc.

### SessionClient

Defined in `session-client.md`.

This is the remote adapter for one session server:

* one-shot control requests
* attach handshake
* long-lived attachment handle
* PTY data callbacks
* close reason mapping

It should remain thin and not become a manager.

---

## Layering summary

### Low-level runtime

Implemented in the compiled `msr` binary and libraries.

Authority over:

* session creation
* attachment
* PTY streaming
* termination
* waiting
* session cleanup

### Shell UX layers

Implemented as sourced shell tooling or scripts.

Authority over:

* naming conventions
* workspace resolution
* lexical navigation
* global jump/search
* completion
* quality-of-life shell integration

The shell layers must delegate actual session behavior to `msr`.

---

## The intended product split

### MSR

“Single session primitive.”

Use when you already know the exact socket path and want to:

* create
* attach
* status
* terminate
* wait

### DSM

“Single directory workspace.”

Use when you want a directory to act as a local session workspace:

* `shell.msr`
* `build.msr`
* `api.msr`

with commands like:

* create by name
* attach by name
* next/prev/first/last within that directory

### WSM

“Hierarchical workspace.”

Use when sessions are spread across nested directories under one workspace root:

* `pathdb/api/shell.msr`
* `pathdb/build.msr`
* `frontend/dev/shell.msr`

with commands like:

* global jump
* tree listing
* current node/session context
* local navigation within current node

---

## Important naming / scope assumptions

Final names:

* **MSR** — Minimal Session Runtime
* **DSM** — Directory Session Manager
* **WSM** — Workspace Session Manager

Recommended conceptual split in code/package layout:

* `msr/` — runtime libs + CLI
* `dsm/` — shell UX for single-directory workspaces
* `wsm/` — shell UX for hierarchical workspaces

These can live in one monorepo initially, but must preserve clear boundaries.

---

## What the implementation should optimize for

### 1. One binary, simple distribution

The low-level runtime should ship as one binary:

* `msr`

That binary may contain:

* public CLI commands
* one internal long-lived mode like `_serve`

### 2. Thin shell composition

DSM and WSM should depend on the `msr` binary as an external contract:

* do not reach into runtime internals from shell tooling
* do not duplicate runtime semantics in shell

### 3. Serialized coordination in the server

The hardest bugs will be lifecycle and ordering bugs, not raw protocol parsing.

Prefer a server design where:

* mutable server state is coordinated in one place
* attachment transitions are serialized
* shutdown is owned by the server
* host exit triggers server cleanup deterministically

### 4. Clear ownership

Keep these boundaries clean:

* **Host** owns PTY + child + host lifecycle
* **Server** owns socket + connections + attachment arbitration + shutdown
* **Client** owns remote request/attach mechanics
* **DSM/WSM** own naming/navigation UX only

---

## Important behavioral assumptions

### A session is not necessarily a shell

A session may host:

* a shell
* a REPL
* a TUI
* a long-running non-interactive process

This is okay.

Control must always remain available through the out-of-band control plane:

* status
* wait
* terminate

Attach is for the PTY/data plane:

* interactive if the process supports it
* observational if it does not

### Attach is not the only management path

Do not design the system so that management requires attach.

Non-interactive sessions must still be manageable via short-lived control requests.

### One attached owner at a time

The default runtime model is:

* many possible short-lived control connections
* at most one attached owner connection

This is a core simplifying rule.

### Default cleanup should be automatic

The normal lifecycle should feel like a normal session manager:

* process exits
* host observes exit
* server sends best-effort final event to attached owner
* server closes connections
* socket is removed
* resources are cleaned up

Do not require some third-party global orchestrator for the ordinary end-of-session path.

---

## Protocol and transport stance

The system uses one Unix socket endpoint per session server.

There are two connection patterns to that same endpoint:

### Control connections

Short-lived:

* one request
* one response
* close

Used for:

* status
* wait
* terminate

### Attached connection

Long-lived upgraded connection:

* starts with `attach`
* on success becomes PTY data + event stream
* remains open until detach, takeover, exit, or error

Do not confuse:

* one socket path
  with
* one single connection for everything

---

## Environment conventions

These conventions are central to DSM/WSM.

### `MSR_SESSION`

Absolute socket path of the current hosted session.

This must be injected when the session is created so the shell inside the PTY knows what session it is in.

### `WSM_ROOT`

Absolute workspace root for WSM-managed sessions.

This enables hierarchical navigation even when the shell’s live cwd drifts.

These env vars are not just convenience; they are core context carriers for the higher-level shell UX.

---

## DSM guidance in one paragraph

DSM treats one directory as a session workspace.

Conventions:

* session sockets use `.msr` suffix
* a session name maps to `<dir>/<name>.msr`
* current workspace while attached comes from `dirname "$MSR_SESSION"`
* `next` / `prev` / `first` / `last` operate over lexical siblings in that directory

DSM is intentionally small and should be thought of as a shell convenience layer over explicit socket-path `msr` operations.

---

## WSM guidance in one paragraph

WSM recursively scans `.msr` sockets under one workspace root and assigns canonical ids like:

* `pathdb/api/shell`
* `frontend/dev/shell`

Its primary global UX is **jump**, not path walking. Users should be able to:

* jump by deterministic token query
* optionally build canonical-id prefixes with tab completion
* then use local node navigation once attached

WSM should feel like:

* global jump
* local cycle

not like a heavy tree browser.

---

## Recommended implementation order

A good implementation sequence is:

### 1. SessionHost

Get PTY + child + lifecycle right first.

### 2. SessionServer

Add socket exposure, control requests, attachment, and automatic shutdown.

### 3. SessionClient

Add one-shot control ops and attach handle.

### 4. `msr` CLI

Expose the low-level binary surface.

### 5. DSM shell layer

Prove local directory workspace semantics.

### 6. WSM shell layer

Add recursive discovery, canonical ids, global jump, and completion.

This ordering matters. It keeps the higher-level UX from outrunning the low-level runtime reality.

---

## Suggested repo/package posture

Recommended default:

* one monorepo
* separate packages/projects for `msr`, `dsm`, and `wsm`

Reason:

* APIs are still evolving
* cross-layer iteration is easier
* docs/specs can evolve together

But preserve the boundary as if they were separate external projects:

* DSM/WSM depend on `msr`’s CLI contract
* not on unpublished internals

---

## Suggested implementation tools

These are not requirements, but good defaults.

### For `msr`

Use the language/runtime’s own socket/process/pty primitives as appropriate.

### For DSM/WSM shell tooling

Leverage standard Linux tools where useful:

* `find`
* `sort`
* `awk`
* `sed`
* `cut`
* standard Bash completion
* optionally `fzf` / `sk` for interactive selection

Important rule:

* interactive selector tools are optional UX helpers
* deterministic matching logic remains owned by DSM/WSM themselves

---

## WSM jump guidance

This is one of the most important design points.

Every discovered session should have a canonical id:

* `pathdb/api/shell`

`wsm j` should resolve queries deterministically.

Two important user modes should coexist:

### Path mode

Slash-style canonical-id prefixes:

* `pathdb/api/`
* `pathdb/a`
* completion-friendly

### Token mode

Space-separated search tokens:

* `pathdb shell`
* `api sh`

Completion should operate mainly over path-mode canonical prefixes.
Matching/ranking should remain deterministic and explainable.

If incomplete or ambiguous:

* list candidates
* do not guess

This is central to WSM’s identity.

---

## What not to do

A few anti-goals for implementation:

### Do not make DSM/WSM second runtimes

They are shell UX layers, not alternate authorities.

### Do not let shell cwd define workspace context once attached

Always derive from `MSR_SESSION` / `WSM_ROOT`.

### Do not overcomplicate history/state too early

Back/forward and similar features are not needed for v0 unless there is a very clean minimal mechanism.

### Do not make completion semantics different from command semantics

Completion should help construct canonical ids, not invent different matching rules.

### Do not treat attach as the only management interface

Short-lived control plane must remain first-class.

---

## Reading order for the detailed specs

Recommended order for an implementation agent:

### 1. `session-host.md`

Understand the local process/PTY primitive first.

### 2. `session-server.md`

Understand socket exposure, attach model, and cleanup.

### 3. `session-client.md`

Understand the low-level consumer surface and command semantics.

### 4. `directory-session-manager.md`

Understand single-directory shell composition.

### 5. `workspace-session-manager.md`

Understand recursive discovery, canonical ids, jump, and local-vs-global UX.

This order mirrors the intended implementation order.

---

## Final summary

This system is best understood as:

* **MSR**: a single-session runtime primitive
* **DSM**: a local directory workspace UX over many MSR sessions
* **WSM**: a hierarchical workspace UX over many DSM-style nodes

The architecture is intentionally layered so that:

* the runtime remains small and explicit
* higher-level behavior is composed outside it
* the filesystem provides discoverability
* session identity is stable and inspectable
* shell tooling can add strong ergonomics without owning core semantics

The rest of the docs should be read with that framing in mind.

