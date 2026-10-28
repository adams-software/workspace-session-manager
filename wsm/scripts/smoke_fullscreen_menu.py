#!/usr/bin/env python3
"""Exercise WSM's real terminal ownership handoff through a controlling PTY."""

import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time


PRODUCER = r'''#!/usr/bin/python3
import os, tty
tty.setraw(0)
os.write(1, b"\x1b[2J\x1b[HBASE_SCREEN\x1b[?2004h")
pending = b""
while True:
    data = os.read(0, 4096)
    if not data:
        break
    pending += data
    marker = b"\x1b[201~"
    if marker in pending:
        end = pending.index(marker) + len(marker)
        paste, pending = pending[:end], pending[end:]
        expected = b"\x1b[200~x\x07y\x1b[201~"
        os.write(1, b"\r\nPASTE_OK\r\n" if paste == expected else b"\r\nPASTE_BAD:" + paste.hex().encode() + b"\r\n")
    if pending:
        os.write(1, b"\r\nGOT:" + pending.hex().encode() + b"\r\n")
        pending = b""
'''


def read_until(fd: int, needle: bytes, timeout: float = 8) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], min(0.1, deadline - time.monotonic()))
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        data.extend(chunk)
        if needle in data:
            return bytes(data)
    raise RuntimeError(f"timed out waiting for {needle!r}; terminal tail={bytes(data[-1000:])!r}")


def main() -> None:
    repo = Path(__file__).resolve().parents[2]
    wsm = repo / "zig-out/bin/wsm"
    with tempfile.TemporaryDirectory(prefix="wsm-fullscreen-smoke-") as tmp:
        root = Path(tmp)
        producer = root / "producer.py"
        producer.write_text(PRODUCER)
        producer.chmod(0o700)

        pid, fd = pty.fork()
        if pid == 0:
            env = os.environ.copy()
            env.update(WSM_ROOT=tmp, SHELL=str(producer))
            os.execve(str(wsm), [str(wsm), "create", "probe"], env)

        try:
            read_until(fd, b"BASE_SCREEN")

            os.write(fd, b"\x1b[200~x\x07y\x1b[201~")
            pasted = read_until(fd, b"PASTE_OK")
            if b"WSM\r\n" in pasted:
                raise RuntimeError("bracketed paste opened the menu")

            os.write(fd, b"\x07")
            menu = read_until(fd, b"a  attach")
            if b"WSM" not in menu:
                raise RuntimeError("full-screen menu did not render")

            os.write(fd, b"\x07oops")
            time.sleep(0.2)
            os.write(fd, b"ok")
            child = read_until(fd, b"GOT:6f6b")
            if b"GOT:6f6f7073" in child:
                raise RuntimeError("input trailing the menu close key leaked to the child")
        finally:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                os.close(fd)
            except OSError:
                pass
            os.waitpid(pid, 0)
            env = os.environ.copy()
            env["WSM_ROOT"] = tmp
            subprocess.run(
                [wsm, "kill", "-f", "probe"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

    print("fullscreen menu smoke: ok")


if __name__ == "__main__":
    main()
