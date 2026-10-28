#!/usr/bin/env python3
"""Exercise full-screen menu actions across real persistent sessions."""

import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time


PRODUCER = r'''#!/usr/bin/python3
import os, tty
tty.setraw(0)
session = os.environ["WSM_SESSION_ID"].encode()
os.write(1, b"\x1b[2J\x1b[HSESSION:" + session + b"\x1b[?2004h")
while True:
    data = os.read(0, 4096)
    if not data:
        break
    os.write(1, b"\x1b[2J\x1b[HSESSION:" + session + b" INPUT:" + data.hex().encode() + b"\x1b[?2004h")
'''

LOG_VIEWER = r'''#!/bin/sh
printf '\033[2J\033[HLOG_VIEWER_RETURNED\n'
exit 0
'''


class Terminal:
    def __init__(self, fd: int):
        self.fd = fd
        self.buffer = bytearray()

    def expect(self, needle: bytes, timeout: float = 8) -> bytes:
        deadline = time.monotonic() + timeout
        while needle not in self.buffer and time.monotonic() < deadline:
            ready, _, _ = select.select([self.fd], [], [], min(0.1, deadline - time.monotonic()))
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            self.buffer.extend(chunk)
        index = self.buffer.find(needle)
        if index < 0:
            raise RuntimeError(f"timed out waiting for {needle!r}; terminal tail={bytes(self.buffer[-1200:])!r}")
        end = index + len(needle)
        matched = bytes(self.buffer[:end])
        del self.buffer[:end]
        return matched

    def send(self, data: bytes) -> None:
        os.write(self.fd, data)

    def drain(self, seconds: float = 0.2) -> bytes:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.fd], [], [], min(0.05, deadline - time.monotonic()))
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            self.buffer.extend(chunk)
        data = bytes(self.buffer)
        self.buffer.clear()
        return data


def run_cli(wsm: Path, env: dict[str, str], *args: str) -> None:
    subprocess.run(
        [wsm, *args],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )


def spawn_viewer(wsm: Path, env: dict[str, str], session: str) -> tuple[int, Terminal]:
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(str(wsm), [str(wsm), "attach", session], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    return pid, Terminal(fd)


def stop_viewer(pid: int, terminal: Terminal, force: bool = False) -> None:
    try:
        os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    try:
        os.close(terminal.fd)
    except OSError:
        pass


def main() -> None:
    repo = Path(__file__).resolve().parents[2]
    wsm = repo / "zig-out/bin/wsm"
    with tempfile.TemporaryDirectory(prefix="wsm-fullscreen-actions-") as tmp:
        root = Path(tmp)
        producer = root / "producer.py"
        log_viewer = root / "log-viewer.sh"
        producer.write_text(PRODUCER)
        producer.chmod(0o700)
        log_viewer.write_text(LOG_VIEWER)
        log_viewer.chmod(0o700)

        env = os.environ.copy()
        env.update(WSM_ROOT=tmp, SHELL=str(producer), WSM_LOGS_VIEWER_BIN=str(log_viewer))
        sessions = ["alpha", "beta", "legacy", "gamma"]
        for session in sessions[:3]:
            run_cli(wsm, env, "create", "-d", session)

        pid, terminal = spawn_viewer(wsm, env, "alpha")
        try:
            terminal.expect(b"SESSION:alpha")

            # Navigation keeps the menu open and yields the newly attached vpty.
            terminal.send(b"\x07")
            terminal.expect(b"a  attach")
            terminal.send(b"\x1b")
            time.sleep(0.01)
            terminal.send(b"[")
            time.sleep(0.01)
            terminal.send(b"C")
            terminal.expect(b" / beta")
            terminal.send(b"\x07")
            terminal.expect(b"SESSION:beta")

            # Explicit attach closes the menu into the selected child.
            terminal.send(b"\x07a")
            terminal.expect(b"attach> ")
            terminal.expect(b"\x1b[4;9H\x1b[?25h")
            terminal.send(b"alpha\r")
            terminal.expect(b"SESSION:alpha")

            # Create closes the menu into the newly created session.
            terminal.send(b"\x07c")
            terminal.expect(b"create> ")
            terminal.send(b"gamma\r")
            terminal.expect(b"SESSION:gamma")

            # UTF-8 prompt input survives one-byte terminal reads, and editing
            # treats combining and emoji sequences as whole graphemes.
            terminal.send(b"\x07c")
            terminal.expect(b"create> ")
            unicode_input = "e\u0301👍🏽x".encode()
            for byte in unicode_input:
                terminal.send(bytes([byte]))
                time.sleep(0.002)
            terminal.expect(b"create> " + unicode_input)
            for byte in b"\x1b[D":
                terminal.send(bytes([byte]))
                time.sleep(0.002)
            terminal.send(b"\x7f")
            terminal.expect("create> e\u0301x".encode())
            terminal.send(b"\x7f")
            terminal.expect(b"create> x")
            terminal.send(b"\x1b")
            terminal.expect(b"a  attach")
            terminal.send(b"\x07")
            terminal.expect(b"SESSION:gamma")

            # Prompt cancellation returns to the menu; the close-key suffix is
            # discarded rather than becoming input in gamma.
            terminal.send(b"\x07a")
            terminal.expect(b"attach> ")
            terminal.send(b"beta\x1b")
            terminal.expect(b"a  attach")
            terminal.send(b"\x07LEAK")
            terminal.expect(b"SESSION:gamma")
            terminal.send(b"ok")
            child_input = terminal.expect(b"INPUT:6f6b")
            if b"INPUT:4c45414b" in child_input:
                raise RuntimeError("input trailing menu cancellation leaked to the child")

            # The log viewer temporarily owns the real terminal while gamma's
            # vpty remains yielded, then WSM restores the same menu.
            terminal.send(b"\x07g")
            terminal.expect(b"LOG_VIEWER_RETURNED")
            terminal.expect(b" / gamma")

            # A crashed viewer drops the presentation client. Vpty must recover
            # visibility so a new WSM attachment can repaint the child.
            stop_viewer(pid, terminal, force=True)
            pid, terminal = spawn_viewer(wsm, env, "gamma")
            terminal.expect(b"SESSION:gamma")

            # Removing the capability path simulates an older persistent
            # session. WSM must leave Ctrl+G with that child.
            (root / "legacy.present").unlink()
            terminal.send(b"\x07a")
            terminal.expect(b"attach> ")
            terminal.send(b"legacy\r")
            terminal.expect(b"SESSION:legacy")
            terminal.drain()
            terminal.send(b"\x07")
            legacy_input = terminal.expect(b"INPUT:07")
            if b"a  attach" in legacy_input:
                raise RuntimeError("legacy session unexpectedly opened the WSM menu")

            print("fullscreen action transitions: ok")
        finally:
            stop_viewer(pid, terminal)
            for session in sessions:
                subprocess.run(
                    [wsm, "kill", "-f", session],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )


if __name__ == "__main__":
    main()
