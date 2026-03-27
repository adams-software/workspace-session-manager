Reality is not pure passthrough.

The happy path is simple, but terminals are one of those things where **90% is easy and the last 10% is all the weirdness**. A minimal design can still work well, but you do need to be deliberate about a few edge cases.

The main categories are:

* PTY/process lifecycle
* attach/detach races
* terminal state and resize
* I/O behavior and buffering
* stale sockets / stale ownership
* signals and job control
* crash cleanup

## The good news

If you keep the design very small:

* Linux only
* one PTY-backed child
* one attached client at a time
* no replay
* no built-in rendering
* no multi-client support

then a lot of complexity disappears.

You do **not** need to solve:

* collaborative input
* screen restore
* pane state
* scrollback modeling
* per-client fanout policy

That is a huge win.

But even then, there are still real edge cases.

---

## 1. Child exits while nobody is attached

This is normal.

Example:

* user detaches
* shell exits later
* daemon is still alive holding session state

Questions:

* does daemon exit immediately?
* does socket stay around briefly?
* what does `open(path)` do after exit?

You need explicit semantics.

Best minimal behavior:

* daemon records exit status
* future attach/open returns “session exited”
* daemon cleans up socket and exits
* maybe keep status around only while parent process is alive, but simplest is just clean up and make open fail

The key is: do not leave a dead socket that looks alive.

---

## 2. Client disappears uncleanly

This is very common.

Examples:

* ssh drops
* laptop sleeps
* terminal crashes
* network path hangs weirdly

If the client dies cleanly, you see socket close and detach is easy.

If not, you may get:

* delayed close detection
* stuck writes
* session still thinks client is attached

This is one of the most important real-world cases.

Minimal strategy:

* treat socket close/error as detach
* make attach ownership based on actual live connection
* consider allowing force-attach / steal if an old client appears stuck

This is exactly where tools like shpool need explicit detach recovery.

---

## 3. Stale socket path

If daemon crashes, the Unix socket file may remain on disk.

Then startup fails because bind says the path already exists.

You need startup cleanup logic like:

* if socket path exists, try connecting
* if connect fails, remove stale socket and bind
* if connect succeeds, session already exists

This is a classic Unix daemon edge case.

---

## 4. PTY child needs controlling terminal setup done correctly

This is less an edge case and more a correctness requirement.

If you mess up:

* `setsid()`
* controlling terminal acquisition
* stdio dup setup

then shells and TUI apps behave strangely.

Symptoms:

* no job control
* Ctrl-C weirdness
* background/foreground issues
* shell warnings like “no job control in this shell”

So the PTY spawn path has to be correct.

Using `forkpty()` avoids a lot of this pain.

---

## 5. Resize behavior

Even with one client, resize is not trivial.

Cases:

* client attaches with one size
* later attaches with another size
* client resizes rapidly
* no client attached for a while, then new client size is very different

You need a rule:

* on attach, always apply attached client’s current size
* on resize, forward new size to PTY
* when detached, PTY just keeps last known size

Without this, TUIs look broken or blank longer than expected.

Also, some apps redraw only after resize or input, so applying size on attach is important.

---

## 6. Blank screen on reattach

As you already noticed, with no replay/screen model:

* reattach may show nothing until app redraws

This is not a bug, but users may think it is.

So you should treat it as a spec-level behavior, not an accidental one.

Practical mitigation:

* immediately send current size on attach
* maybe user presses Enter and shell redraws
* document that no screen restore exists

---

## 7. Backpressure still exists even if you “do nothing”

Even single-client passthrough is not infinitely simple.

If PTY is producing output faster than the client/socket can consume it, you have to decide what happens.

Possible bad outcomes:

* blocking entire loop on write
* unbounded buffering in your process
* memory growth
* delayed close detection

Minimal safe approach:

* use blocking I/O with a simple copy loop and accept that slow clients slow delivery
* or use nonblocking/event loop and bounded buffers

For v1, blocking with one client is okay if you are honest about the model. But the daemon still needs to survive slow clients without accidentally exploding memory.

---

## 8. Partial reads/writes

Streams are not message-oriented.

You do not get:

* one terminal write in
* one terminal write out

You get arbitrary chunks.

So your bridge code must correctly handle:

* partial reads
* partial writes
* retrying writes
* EINTR / interrupted syscalls

This is basic stream hygiene, but absolutely required.

---

## 9. Signals from terminal input

Ctrl-C, Ctrl-Z, Ctrl-D, and friends are not “special cases” in your daemon if you are doing PTY correctly — they should mostly work naturally through terminal line discipline.

But there are still things to understand.

### Ctrl-C / Ctrl-Z

These should go through the PTY and hit the foreground process group inside the slave terminal.

Good PTY setup makes this mostly work.

### Ctrl-D

This is EOF behavior in the terminal driver, not just a literal “detach” key.

You should not reinterpret shell control characters unless you explicitly add your own detach escape.

That means:

* if you want a detach key, it needs to be clearly outside normal terminal behavior, or handled at the client side before bytes go into the PTY

Otherwise you break normal shell behavior.

This is a subtle but important design point.

---

## 10. Detach key design is tricky

If you want something like tmux/dtach detach behavior, you need to decide:

* is detach initiated by the client wrapper?
* or by the daemon interpreting an escape sequence?

Client-side detach is cleaner for a minimal design.

Why:

* the daemon stays a byte bridge
* shell input semantics are preserved
* no ambiguity about whether a byte sequence belongs to the application or the session layer

If the daemon eats bytes looking for a detach prefix, it is no longer pure passthrough.

That may be fine, but it is a real design choice.

---

## 11. Session daemon crash

If daemon crashes while child is alive, what happens?

This depends on process ownership choices.

Possible outcomes:

* child dies too
* child survives but becomes orphaned and inaccessible
* socket disappears but shell still exists
* leaked shell process remains

You need to decide whether daemon crash should implicitly kill the child.

For a minimal practical tool, I would lean toward:

* daemon owns session lifetime
* if daemon dies, session is lost and child should die too if possible

That is simpler than trying to build daemon crash recovery around a still-live PTY child.

You can get fancier later.

---

## 12. Child process forks or changes state

Shells spawn subprocesses all the time. That is normal.

The daemon should care only about the PTY session leader / main child it created.

But you need correct waiting semantics:

* reap the child you own
* do not accidentally interfere with unrelated descendants
* track exit correctly

Usually this is fine if the shell is the one you wait on.

---

## 13. Double attach race

If two clients try to attach at nearly the same time, even in a single-client design, you need a rule.

For example:

* first accepted connection wins
* second gets explicit busy error
* or second steals control if a force flag is set

Do not leave this accidental.

Otherwise both may partially think they attached.

This is a tiny state machine issue, but worth handling from day one.

---

## 14. Open-versus-create race

If two callers both try to create the same session path:

* one should win bind/create
* the other should discover session already exists

This is another place where the socket path being the session identity helps. The filesystem/socket bind becomes part of your coordination.

---

## 15. Cleanup on normal termination

When session ends, clean up:

* socket path
* pid/state file if any
* open fds
* event loop registrations
* client connection

This sounds obvious, but a lot of “weirdness” in these tools is really just imperfect cleanup.

---

## 16. Terminal mode restoration on client side

If your client wrapper changes local terminal mode, like entering raw mode, it must restore it on exit, detach, crash, and error.

This is a very common footgun.

If you forget:

* user’s terminal is left broken
* no echo
* weird line handling
* “my shell is frozen”

So client-side hardening matters too, not just daemon hardening.

---

## 17. EOF semantics between client and PTY

You need to be careful not to confuse:

* client disconnected
* client sent EOF-like terminal input
* PTY child exited
* socket half-closed

These are different.

For the minimal model:

* socket close means attachment ended
* PTY child exit means session ended
* terminal control bytes inside PTY are application data, not session control

Keeping those separate avoids a lot of confusion.

---

## 18. Security / permissions

Even for a local-only minimal tool, think about:

* socket file permissions
* who can attach
* whether path lives in `/tmp` vs `/run/user/...`

If you put sockets in a global writable place carelessly, someone else might interfere.

A sane minimal default is something under the user’s runtime dir.

---

## 19. Logging and debugging visibility

Even if core has no logging feature, you will want internal debug logs during development:

* attach
* detach
* child exited
* resize
* socket close
* cleanup

Because terminal bugs are annoying to debug blind.

This is development hardening, not product logging.

---

## 20. Non-shell programs behave differently

A shell is forgiving:

* press Enter, prompt redraws
* Ctrl-C behavior is familiar

A curses app or REPL may be much more sensitive.

So test with:

* `/bin/bash`
* `vim`
* `top`
* `python`
* `less`

If those work, your PTY lifecycle is probably sane.

---

# What is actually required for v1 hardening

For a truly minimal but real implementation, I would treat these as mandatory:

* correct PTY spawn (`forkpty()` is fine)
* proper socket stale-file cleanup
* explicit single-client attach policy
* attach/detach race protection
* resize on attach + resize updates
* exact close semantics
* child exit handling and cleanup
* client terminal-mode restore
* no daemon-side interpretation of ordinary terminal input

That gets you something robust enough to use.

# What can wait

These can wait until later:

* multi-client support
* replay / redraw buffer
* force-takeover UX polish
* session registry
* logging sidecars
* crash recovery of live child after daemon death

# My overall take

Your intuition is right: “pure passthrough” gets you a lot, but not everything. The main lie in “it’s just a stream” is that a PTY session is not only a stream — it is also a process lifecycle, a controlling terminal, a socket endpoint, and a bit of attachment state.

The good news is you do not need to solve every weird terminal problem. You just need to define a few boundaries clearly and make the lifecycle boring.

The most important special cases to design explicitly are:

* stale attach/disconnect
* resize
* close/detach semantics
* child exit
* stale socket cleanup
* client terminal restoration

That is the real hardening surface.

