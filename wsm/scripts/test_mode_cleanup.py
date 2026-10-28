#!/usr/bin/env python3
"""Real-PTY regression: detaching WSM leaves interaction modes neutral."""

import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

MODE_RESETS = [
    b"\x1b[?1000l", b"\x1b[?1002l", b"\x1b[?1003l",
    b"\x1b[?1005l", b"\x1b[?1006l", b"\x1b[?1015l",
    b"\x1b[?1004l", b"\x1b[?2004l", b"\x1b[?2005l",
    b"\x1b[?2006l", b"\x1b[?1l",
]

CHILD = """#!/usr/bin/python3
import os, tty
tty.setraw(0)
os.write(1, b"\\x1b[?1000hREADY")
while os.read(0, 1024):
    pass
"""


def collect_until(fd, output, complete):
    deadline = time.monotonic() + 8
    while not complete():
        assert time.monotonic() < deadline, f"timed out; received {bytes(output)!r}"
        if not select.select([fd], [], [], 0.2)[0]:
            continue
        try:
            output.extend(os.read(fd, 65536))
        except OSError:
            if complete():
                return
            raise
        assert len(output) < 1024 * 1024, "unexpected output flood"


def check(binary):
    with tempfile.TemporaryDirectory(prefix="wsm-mode-cleanup-") as tmp:
        child = Path(tmp) / "child"
        child.write_text(CHILD)
        child.chmod(0o700)
        env = os.environ.copy()
        env.update(WSM_ROOT=tmp, SHELL=str(child))

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

        def setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        proc = subprocess.Popen(
            [str(binary), "create", "mode-cleanup"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            preexec_fn=setup,
        )
        os.close(slave)
        output = bytearray()
        try:
            collect_until(master, output, lambda: b"READY" in output)
            assert b"\x1b[?1000h" in output, "child did not enable mouse reporting"
            # Let WSM finish the first attachment repaint before opening its
            # full-screen menu.
            time.sleep(0.25)
            os.write(master, b"\x07")  # Ctrl+G opens the WSM menu.
            time.sleep(0.1)
            os.write(master, b"d")
            collect_until(master, output, lambda: proc.poll() is not None and all(item in output for item in MODE_RESETS))
            assert proc.wait(timeout=2) == 0
            for sequence in MODE_RESETS:
                assert sequence in output, f"missing terminal cleanup {sequence!r}"
        finally:
            os.close(master)
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            subprocess.run(
                [str(binary), "kill", "-f", "mode-cleanup"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )


if __name__ == "__main__":
    executable = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/wsm").resolve()
    check(executable)
    print("wsm detach: child interaction modes returned to neutral baseline")
