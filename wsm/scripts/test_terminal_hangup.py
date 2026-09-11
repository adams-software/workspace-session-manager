#!/usr/bin/env python3
"""Linux regression: WSM exits on terminal hangup, including paused input.

Run from the repo root after building: python3 wsm/scripts/test_terminal_hangup.py
Uses fake session sockets; no persistent sessions are created.
"""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import socket
import subprocess
import sys
import tempfile
import termios
import time


def child_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    # Exercise poll handling instead of allowing SIGHUP to kill the client.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)


def check_disconnect(binary, paused):
    with tempfile.TemporaryDirectory(prefix="wsm-hangup-") as tmp:
        with socket.socket(socket.AF_UNIX) as data, socket.socket(
            socket.AF_UNIX
        ) as control:
            data.bind(str(Path(tmp) / "demo.wsm"))
            control.bind(str(Path(tmp) / "demo.ctl"))
            data.listen(1)
            control.listen(1)
            data.settimeout(5)
            control.settimeout(5)
            master, slave = pty.openpty()
            env = dict(os.environ, WSM_ROOT=tmp, TERM="xterm-256color")
            proc = subprocess.Popen(
                [str(binary), "attach", "demo"],
                stdin=slave,
                stdout=slave,
                stderr=subprocess.PIPE,
                env=env,
                preexec_fn=child_terminal,
            )
            os.close(slave)
            try:
                with data.accept()[0] as peer, control.accept()[0]:
                    os.set_blocking(master, False)
                    # Wait for rendering, then let the client reach its poll loop.
                    assert select.select([master], [], [], 5)[0], "no initial UI output"
                    time.sleep(0.1)
                    while True:
                        try:
                            os.read(master, 65536)
                        except BlockingIOError:
                            break
                    assert proc.poll() is None, proc.stderr.read()
                    if paused:
                        # The fake session never reads input. Fill socket and WSM
                        # buffers until terminal writes remain blocked.
                        sent = 0
                        blocked_since = None
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            try:
                                sent += os.write(master, b"a" * 4096)
                                blocked_since = None
                            except BlockingIOError:
                                now = time.monotonic()
                                if blocked_since is None:
                                    blocked_since = now
                                if now - blocked_since > 0.3:
                                    break
                                time.sleep(0.01)
                        else:
                            raise AssertionError("input did not become backpressured")
                        assert sent > 256 * 1024, f"only sent {sent} bytes"
                    start = time.monotonic()
                    os.close(master)
                    master = None
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        raise AssertionError(
                            "WSM stayed alive after terminal hangup"
                        ) from None
                    assert proc.returncode == 0, proc.stderr.read().decode(
                        errors="replace"
                    )
                    label = "paused input" if paused else "idle input"
                    print(f"{label}: exited in {time.monotonic() - start:.3f}s")
            finally:
                if master is not None:
                    os.close(master)
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)
                proc.stderr.close()


if __name__ == "__main__":
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/wsm").resolve()
    for paused in (False, True):
        check_disconnect(binary, paused)
