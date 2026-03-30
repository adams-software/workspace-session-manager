SessionHost v0 Design

Purpose

SessionHost is the in-process owner of one terminal session.

It is responsible for:

allocating and owning one PTY

spawning one child process attached to that PTY

exposing PTY IO to the caller

resizing the terminal

observing child exit

caching final exit status

cleaning up host-owned resources after exit


It is not responsible for:

Unix socket listening

client connections

attach/detach/takeover semantics

multiple clients

session discovery or naming

manager/navigation UX

logging or replay


So the host is the local session primitive, not the remote server.


---

Mental model

A SessionHost is a one-shot, resource-owning object with a small explicit lifecycle:

1. constructed with fixed spawn config


2. started once


3. runs one PTY-backed child process


4. exits once


5. closed once, after exit, for final cleanup



This is intentionally not restartable.

If you want another session, create another host.


---

Responsibilities

SessionHost owns

PTY creation and lifetime

child spawn and lifetime observation

PTY input/output stream exposure

terminal resize calls

exit-status capture

final resource teardown after exit


SessionHost does not own

socket path or socket server lifecycle

remote protocol

active-client arbitration

detach/takeover logic

policy about who may read/write PTY

higher-level shutdown orchestration beyond its own cleanup


A later SessionServer layer can wrap a SessionHost and expose it over Unix socket IPC.


---

Design goals

1. Single responsibility
Host one PTY-backed process only.


2. Race-free startup
Caller can subscribe to PTY/output/exit events before process starts.


3. One-shot lifecycle
Start once, exit once, close once.


4. Explicit cleanup
Cleanup is a separate step after exit.


5. No transport assumptions
Host does not know about clients or sockets.


6. Minimal surface
Only expose what is needed for a local session primitive.




---

Core assumptions

These assumptions drive the shape of the API.

1. Startup race matters

The caller may need to bind PTY/output/exit listeners before any child output can be emitted.

That is why start() exists even though the host is one-shot.

2. Exit and cleanup are distinct

The child process exiting does not necessarily mean every host-owned resource has been explicitly finalized from the API’s perspective.

So close() remains as an explicit, final cleanup step.

3. Cleanup is simple

To keep semantics crisp:

close() is only allowed after exit

calling close() while still running is an error


This avoids ambiguous “dispose while live” behavior.

4. Host is single-use

No restart, no replacing child, no re-binding to a new PTY.


---

Lifecycle

States

type HostState =
  | { type: "idle" }
  | { type: "starting" }
  | { type: "running" }
  | { type: "exited"; exitStatus: ExitStatus }
  | { type: "closed" };

Meanings

idle

Host object exists, configured, not started yet.

no child process yet

no PTY activity yet

safe to subscribe to events


starting

Host is allocating PTY / spawning child.

This may be very brief, but it is useful conceptually and for implementation safety.

running

Child is live and PTY is active.

exited

Child has terminated and final ExitStatus is known and cached.

The host has not necessarily been explicitly closed yet.

closed

Final cleanup completed. Host is no longer usable except possibly for inspection, depending on implementation choice.


---

Types

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

interface PtyStream {
  write(data: Uint8Array): Promise<void>;
  onData(cb: (data: Uint8Array) => void): () => void;
  onClose(cb: () => void): () => void;
}

Notes

ExitStatus

Standard final process result:

code for normal exit

signal for signal-based termination


SpawnOptions

Fixed configuration for the hosted process. These belong to host construction because they define what the host is meant to run.

PtyStream

Represents the host’s PTY data plane:

write() sends bytes into the PTY

onData() receives bytes from PTY output

onClose() signals PTY stream unusable/ended



---

API

type SessionHostOptions = {
  spawn: SpawnOptions;
};

interface SessionHost {
  readonly pty: PtyStream;

  start(): Promise<void>;
  resize(cols: number, rows: number): Promise<void>;
  terminate(signal?: string): Promise<void>;
  wait(): Promise<ExitStatus>;
  close(): Promise<void>;

  getState(): HostState;
  getExitStatus(): ExitStatus | null;

  onExit(cb: (status: ExitStatus) => void): () => void;
  onError(cb: (error: Error) => void): () => void;
}

function createSessionHost(opts: SessionHostOptions): SessionHost;


---

Method semantics

createSessionHost(opts)

Creates a configured, not-yet-started host.

Behavior:

stores fixed spawn configuration

initializes host in idle

exposes stable pty handle and event registration surface before startup


Does not:

allocate PTY yet

spawn child yet

emit PTY data yet


This enables race-free subscription before start().


---

start(): Promise<void>

Starts the host exactly once.

Behavior:

valid only in idle

transitions idle -> starting

allocates PTY

applies initial terminal size if provided

spawns child attached to PTY

begins PTY output forwarding

transitions to running on success


Errors:

if called when not idle

if PTY allocation fails

if child spawn fails

if startup partially succeeds but cannot be completed


Important:

start() resolves when host is successfully running

start() does not wait for child exit


Implementation note:

partial startup failure must clean up any resources already allocated before rejecting



---

pty: PtyStream

Stable PTY stream interface owned by the host.

pty.write(data)

Writes bytes to PTY input.

Behavior:

valid only while PTY is active

typically used once host is running


Errors:

reject if host is not yet started

reject if PTY is closed

reject after exit/close


pty.onData(cb)

Registers callback for PTY output bytes.

Behavior:

caller may subscribe before start()

callbacks begin receiving output once PTY is active

returns unsubscribe function


This is a key reason start() exists.

pty.onClose(cb)

Registers callback fired when the PTY stream becomes unusable.

Behavior:

should fire once

may happen on child exit, PTY teardown, or final close

returns unsubscribe function



---

resize(cols, rows): Promise<void>

Resizes the PTY terminal.

Behavior:

valid only while running

applies new terminal dimensions to PTY


Errors:

if not running

if dimensions are invalid

if PTY resize fails



---

terminate(signal?): Promise<void>

Requests child termination by sending a signal.

Behavior:

valid while child is still live

default signal is implementation-defined, typically SIGTERM

resolves when signal delivery request has been issued, not when exit completes


Errors:

if host has not started

if host is already closed

may no-op or reject if already exited; I recommend no-op if already exited


Important:

terminate() is a request

wait() / onExit() observe actual final exit



---

wait(): Promise<ExitStatus>

Waits for child exit and resolves with final cached status.

Behavior:

if running: waits until exit

if already exited: resolves immediately with cached status

if closed after exit: should still resolve immediately with cached status


Errors:

if called before start()

if startup never completed successfully


Important:

exit status must remain available after exit and after close


That keeps post-mortem inspection simple.


---

getExitStatus(): ExitStatus | null

Returns cached final exit status if available, else null.

Behavior:

null before exit

final immutable status after exit


This is the synchronous inspection API.


---

onExit(cb)

Registers callback fired exactly once when child exits.

Behavior:

callback receives final ExitStatus

returns unsubscribe function

if host already exited, callback should fire on next tick / microtask


That replay-like behavior makes it easier for late subscribers.


---

onError(cb)

Registers callback for host-level errors that are not simply ordinary child exit.

Examples:

PTY read error

internal forwarding error

cleanup error

unexpected host failure


Behavior:

returns unsubscribe function


Important:

ordinary child exit is not an error

it is reported through onExit / wait



---

close(): Promise<void>

Performs final explicit cleanup of host-owned resources.

Behavior:

valid only after child exit

valid in exited

transitions exited -> closed

idempotent if already closed


Errors:

if called before exit

if called before start


Important:

close() does not terminate the child

close() is final cleanup only

caller must use terminate() and/or wait() first if child is still running


This is the rule you chose to keep semantics simple.


---

Invariants

These are the most important correctness rules.

1. One host owns exactly one PTY and one child

Never more than one child. Never reused for a second child.

2. Host is one-shot

Valid lifecycle is:

idle -> starting -> running -> exited -> closed


You may also have:

idle -> starting then startup failure back to an error/failed construction path internally


But never:

exited -> running

closed -> running


3. Exit status is immutable

Once exit occurs, the final ExitStatus is cached and never changes.

4. onExit fires at most once

Exit is terminal and singular.

5. close() only after exit

No live disposal semantics in v0.

6. PTY stream is invalid after exit/close

No further writes should succeed once PTY is ended.

7. Late wait/read is allowed

After exit:

wait() resolves immediately

getExitStatus() returns final cached result


This is important for composability.


---

Division of responsibility

This is where a lot of implementation confusion usually comes from.

Host layer responsibilities

The host decides how to:

create PTY

spawn child

forward PTY bytes

observe exit

clean up internal resources


Caller responsibilities

The caller decides when to:

subscribe to PTY/output events

start the host

resize

signal termination

wait for exit

perform final close


So the host owns mechanics, while the caller owns orchestration policy.

That is the boundary.


---

Why start() and close() both exist

Since you explicitly wanted the rationale captured:

Why start() exists

Even though the host is one-shot, start() exists to provide a pre-live subscription window.

Without it, you either:

risk losing early PTY output / exit events, or

need implicit buffering/replay policy


start() avoids that ambiguity.

Why close() exists

Even though exit ends the child lifecycle, close() exists to provide explicit final resource teardown at the host boundary.

And to keep it simple:

it is only legal after exit

it does not imply termination



---

Implementation assumptions and notes

These are not all API rules, but they matter for a correct implementation.

PTY allocation timing

PTY should generally be allocated in start(), not construction.

Reason:

keeps idle lightweight

avoids acquiring resources before caller is ready

matches the pre-start subscription model


Spawn configuration is fixed at construction

SpawnOptions are part of host identity and should not be passed to start().

Reason:

simplifies state

avoids reconfiguration ambiguity

makes host an object representing one intended session


Partial startup failure must be cleaned up internally

If PTY creation succeeds but child spawn fails, start() must clean up partial resources before rejecting.

The caller should not need to manually unwind partial internals.

PTY forwarding should be owned by host

The host should own the internal PTY read loop / callbacks and expose results through pty.onData.

That gives later layers a stable interface.

wait() should rely on cached final state

Once exit is observed, wait() should always resolve from cached status, not re-query underlying OS state.

close() should be idempotent

This makes callers simpler and reduces teardown hazards.


---

Error model

You can keep this typed but small.

Suggested categories:

ErrInvalidArgs

ErrInvalidState

ErrNotStarted

ErrAlreadyStarted

ErrClosed

ErrSpawnFailed

ErrPtyFailed

ErrPermission


Practical guidance:

use ErrInvalidState for lifecycle violations

use ErrNotStarted for operations before start()

use ErrAlreadyStarted for duplicate start()

use ErrClosed for calls after close()

use concrete startup/PTY errors where useful for debugging



---

Recommended usage flow

Normal lifecycle:

const host = createSessionHost({ spawn });

host.pty.onData(...);
host.onExit(...);

await host.start();

// interact with host

await host.terminate();
const status = await host.wait();
await host.close();

If child exits naturally:

const status = await host.wait();
await host.close();


---

Testing expectations

At minimum, implementation should verify:

subscriptions can be installed before start()

no PTY output is emitted before start()

start() spawns PTY + child correctly

PTY output reaches pty.onData

pty.write() reaches child input

resize() changes terminal size

terminate() sends signal request

wait() resolves with final status

getExitStatus() returns null before exit and final status after exit

onExit fires exactly once

close() fails before exit

close() succeeds after exit and is idempotent

duplicate start() fails

partial startup failure cleans up correctly



---

Final surface

This is the final API shape as discussed:

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

type HostState =
  | { type: "idle" }
  | { type: "starting" }
  | { type: "running" }
  | { type: "exited"; exitStatus: ExitStatus }
  | { type: "closed" };

interface PtyStream {
  write(data: Uint8Array): Promise<void>;
  onData(cb: (data: Uint8Array) => void): () => void;
  onClose(cb: () => void): () => void;
}

type SessionHostOptions = {
  spawn: SpawnOptions;
};

interface SessionHost {
  readonly pty: PtyStream;

  start(): Promise<void>;
  resize(cols: number, rows: number): Promise<void>;
  terminate(signal?: string): Promise<void>;
  wait(): Promise<ExitStatus>;
  close(): Promise<void>;

  getState(): HostState;
  getExitStatus(): ExitStatus | null;

  onExit(cb: (status: ExitStatus) => void): () => void;
  onError(cb: (error: Error) => void): () => void;
}

function createSessionHost(opts: SessionHostOptions): SessionHost;

This is a good, crisp boundary.

The next layer after this is naturally a SessionServer that wraps one SessionHost and adds:

Unix socket listening

client protocol

attachment arbitration

detach/takeover rules

