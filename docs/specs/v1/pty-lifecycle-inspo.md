Here’s the **minimal Linux PTY lifecycle** for your daemon.

I’ll show it in three layers:

1. what the daemon is trying to do
2. the actual syscall/libc sequence
3. how that maps to your minimal session API

---

## 1. What the daemon is doing

Your daemon wants to create this shape:

```text
client terminal <-> unix socket <-> daemon <-> PTY master <-> PTY slave <-> shell
```

The important part is:

* the **shell** thinks it is attached to a real terminal
* the daemon talks to the **master**
* the shell talks to the **slave**

The PTY gives you the illusion of a real terminal.

---

## 2. Minimal lifecycle

## Step A: create a PTY pair

You either use:

* `forkpty()` for convenience

or do it manually with:

* `posix_openpt()`
* `grantpt()`
* `unlockpt()`
* `ptsname()`
* `open()`

### Manual version

```c
int master = posix_openpt(O_RDWR | O_NOCTTY);
grantpt(master);
unlockpt(master);
char *slave_name = ptsname(master);
int slave = open(slave_name, O_RDWR | O_NOCTTY);
```

Now you have:

* `master` fd
* `slave` fd

---

## Step B: fork

```c
pid_t pid = fork();
```

Now there are two processes:

* parent = your daemon
* child = future shell/command

---

## Step C: child becomes a session leader

In the child:

```c
setsid();
```

This is important.

Why:

* child becomes leader of a new session
* child can now acquire a controlling terminal
* the slave PTY can become that controlling terminal

Without this, terminal behavior gets weird.

---

## Step D: child makes slave PTY its stdio

In child:

```c
ioctl(slave, TIOCSCTTY, 0);   // acquire controlling terminal
dup2(slave, STDIN_FILENO);
dup2(slave, STDOUT_FILENO);
dup2(slave, STDERR_FILENO);
```

Then close unneeded fds:

```c
close(master);
close(slave);
```

Now the child’s stdin/stdout/stderr all point at the PTY slave.

So from the child’s point of view, it is sitting inside a normal terminal.

---

## Step E: exec the shell or command

Still in child:

```c
execve("/bin/bash", argv, envp);
```

or whatever command you want.

If this succeeds, child becomes the shell.

---

## Step F: parent keeps only the master

In parent:

```c
close(slave);
```

The daemon keeps:

* `master`
* `pid`

That is the core session state.

The parent now:

* reads shell output from `master`
* writes user input into `master`
* can resize via `master`
* can signal/kill via `pid`

---

# 3. What the daemon does after spawn

Once the shell is running, the daemon usually does three things.

## A. listen on a unix socket

Example:

```text
/tmp/work.sock
```

Client connects there to attach.

So the daemon owns:

* the PTY master
* the child pid
* the socket path

---

## B. bridge bytes between socket and PTY

When a client attaches:

### client -> PTY

Anything client types gets written to `master`.

### PTY -> client

Anything shell prints gets read from `master` and forwarded to client.

This is the basic attach loop.

---

## C. keep session alive when client disconnects

If client disconnects:

* close that client socket
* do **not** kill the child
* do **not** close the master unless session is ending

That is detach.

Later another client connects and the daemon resumes forwarding.

---

# 4. Resize handling

If attached client changes terminal size, daemon sends size to PTY:

```c
struct winsize ws = {
  .ws_col = cols,
  .ws_row = rows,
};
ioctl(master, TIOCSWINSZ, &ws);
```

This causes apps inside the PTY to get terminal-size updates.

Often the kernel also causes `SIGWINCH` behavior appropriately for the foreground app.

---

# 5. Wait / exit handling

Daemon also needs to monitor child exit:

```c
waitpid(pid, &status, 0);
```

When child exits:

* session is over
* future attach should fail, or report exited state
* daemon can clean up socket path and exit

---

# 6. Minimal daemon loop

Conceptually:

```text
spawn PTY + child shell
bind unix socket path
loop:
  accept client attach
  while client attached:
    forward client bytes -> PTY master
    forward PTY output -> client
  on disconnect:
    keep PTY + child alive
repeat
```

That is basically the whole minimal design.

---

# 7. Mapping to your API

For your API:

```ts
interface Runtime {
  create(path: string, opts: SpawnOptions): Promise<Session>;
  open(path: string): Promise<Session>;
}
```

## `create(path, opts)`

Does:

* allocate PTY
* fork
* child `setsid()`
* child hooks slave to stdio
* child `exec()`
* parent keeps master + pid
* parent binds unix socket at `path`
* return `Session`

## `open(path)`

Does:

* connect to existing daemon/session socket
* return a handle/proxy to that session

## `attach(io)`

Does:

* create one live bridge
* client input -> PTY master
* PTY output -> client output
* on disconnect, tear down bridge only

## `resize(cols, rows)`

Does:

* `ioctl(TIOCSWINSZ)` on the PTY

## `terminate(signal?)`

Does:

* `kill(pid, sig)`

## `wait()`

Does:

* wait for child exit, or query daemon for exit state

---

# 8. Even shorter mental picture

The PTY setup is basically:

```text
daemon owns master
child shell owns slave
```

Then attach is just:

```text
client socket <-> daemon <-> master
```

That is why the daemon is the natural authority. It sits between all clients and the one PTY.

---

# 9. Smallest practical implementation choices

If you want the absolute simplest implementation, I’d use:

* `forkpty()` instead of manual PTY setup
* unix domain socket for attach path
* single client only
* no replay
* no multi-client support
* no buffering beyond kernel/socket buffers

That gets you a real minimal core quickly.

Then later you can replace `forkpty()` with lower-level setup if you want more control.

---

# 10. Pseudocode shape

Here is the whole thing in rough pseudocode:

```text
create_session(path, argv):
    master, pid = fork_pty(argv)
    server = bind_unix_socket(path)

    while true:
        client = accept(server)

        while client connected and child alive:
            if client has input:
                write(master, client_input)

            if master has output:
                write(client, pty_output)

        close(client)

        if child exited:
            break

    cleanup(path)
```

That is the essence.

