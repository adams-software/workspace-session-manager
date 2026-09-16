#!/usr/bin/env python3
"""PTY regression: explicit redraw restores child modes in fullscreen and portals.

Run after building: python3 vpty/scripts/test_mode_redraw.py [path/to/vpty]
"""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

CHILD = r'''
import os, signal, tty
signal.alarm(20)
tty.setraw(0)
pending = b""
os.write(1, b"\x1b[?2004h\x1b[?1000h\x1b[2J\x1b[HENABLED")
while True:
    pending += os.read(0, 1024)
    while b"\n" in pending:
        command, pending = pending.split(b"\n", 1)
        if command == b"off":
            os.write(1, b"\x1b[?2004l\x1b[?1000l\x1b[2J\x1b[HDISABLED")
        elif command == b"quit":
            raise SystemExit(0)
'''


def collect_until(fd, expected):
    output = bytearray()
    deadline = time.monotonic() + 5
    # After the expected output, drain until quiet to separate redraw requests.
    while True:
        complete = all(value in output for value in expected)
        timeout = min(0.1 if complete else 0.5, max(0, deadline - time.monotonic()))
        if select.select([fd], [], [], timeout)[0]:
            output.extend(os.read(fd, 65536))
            assert len(output) < 1024 * 1024, "unexpected output flood"
        elif complete:
            return
        assert time.monotonic() < deadline, f"missing redraw output: {expected!r}; received {bytes(output)!r}"


def check(binary, flags):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

    def setup():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    proc = subprocess.Popen(
        [str(binary), *flags, "--", sys.executable, "-c", CHILD],
        stdin=slave, stdout=slave, stderr=slave, preexec_fn=setup,
    )
    os.close(slave)
    try:
        for phase, suffix in ((b"ENABLED", b"h"), (b"DISABLED", b"l")):
            if suffix == b"l":
                os.write(master, b"off\n")
            expected = [phase, b"\x1b[?2004" + suffix, b"\x1b[?1000" + suffix]
            collect_until(master, expected)
            # The child emits nothing in response to SIGWINCH: restoration must
            # come from vpty. Repeat at the same size, then change outer geometry.
            for rows, cols in ((24, 80), (24, 80), (30, 100)):
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
                os.kill(proc.pid, signal.SIGWINCH)
                collect_until(master, expected)
        os.write(master, b"quit\n")
        assert proc.wait(timeout=5) == 0
    finally:
        os.close(master)
        if proc.poll() is None:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/vpty").resolve()
    for flags in ([], ["--origin-row", "2", "--rows", "10", "--cols", "40"]):
        check(binary, flags)
        print(f"{'portal' if flags else 'fullscreen'}: resize restores enabled and disabled modes")
