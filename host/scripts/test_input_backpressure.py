#!/usr/bin/env python3
"""Linux regression: python3 host/scripts/test_input_backpressure.py zig-out/bin/host."""
import hashlib
import os
from pathlib import Path
import select
import socket
import sys
import tempfile
import time

from test_idle_cpu import idle_cpu, process, recv_until, wait_for

CHUNK = bytes(range(256)) * 256
TOTAL = len(CHUNK) * 128
CHILD = r"""
import hashlib, os, pathlib, sys, time, tty
directory, total = pathlib.Path(sys.argv[1]), int(sys.argv[2])
tty.setraw(0)
print("READY", flush=True)
while not (directory / "probe").exists(): time.sleep(0.005)
print("ALIVE", flush=True)
while not (directory / "go").exists(): time.sleep(0.005)
digest = hashlib.sha256()
while total:
    data = os.read(0, min(total, 65536))
    digest.update(data)
    total -= len(data)
print(digest.hexdigest(), flush=True)
# Keep the child alive until the owner has received the response.
while True: time.sleep(1)
"""


def rss(p):
    fields = Path(f"/proc/{p.pid}/stat").read_text().rsplit(")", 1)[1].split()
    return int(fields[21]) * os.sysconf("SC_PAGE_SIZE")


def send_until(owner, sent, deadline):
    while sent < TOTAL and time.monotonic() < deadline:
        if not select.select([], [owner], [], 0.01)[1]:
            continue
        offset = sent % len(CHUNK)
        try:
            sent += owner.send(
                CHUNK[offset : offset + min(len(CHUNK) - offset, TOTAL - sent)]
            )
        except BlockingIOError:
            pass
    return sent


def check(host, directory, disconnect=False):
    path = directory / "host.sock"
    with process(
        [
            str(host),
            str(path),
            "--headless",
            "--",
            sys.executable,
            "-c",
            CHILD,
            str(directory),
            str(TOTAL),
        ]
    ) as p:
        wait_for(path.exists)
        with socket.socket(socket.AF_UNIX) as owner:
            owner.connect(str(path))
            recv_until(owner, b"READY\n")
            owner.setblocking(False)
            initial_rss = rss(p)
            sent = send_until(owner, 0, time.monotonic() + 1)
            if disconnect:
                owner.close()
                assert idle_cpu(p, "host with disconnected stalled writer", 5)
                with socket.socket(socket.AF_UNIX) as replacement:
                    replacement.connect(str(path))
                    (directory / "probe").touch()
                    recv_until(replacement, b"ALIVE\n")
                return
            assert idle_cpu(p, "host with stalled child input", 5)
            growth = rss(p) - initial_rss
            print(
                f"accepted {sent} bytes before pausing; RSS growth={growth // 1024} KiB",
                flush=True,
            )
            assert growth < 4 * 1024 * 1024, "host input queue keeps growing"
            assert sent < 1024 * 1024, "writer was not backpressured"
            # Output must still pass through while input is paused.
            (directory / "probe").touch()
            recv_until(owner, b"ALIVE\n")
            (directory / "go").touch()
            assert send_until(owner, sent, time.monotonic() + 15) == TOTAL
            expected = hashlib.sha256(CHUNK * 128).hexdigest().encode() + b"\n"
            assert recv_until(owner, b"\n") == expected, "input bytes lost or reordered"
            print(f"resumed with all {TOTAL} bytes intact", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_input_backpressure.py /path/to/host")
    for disconnect in (False, True):
        with tempfile.TemporaryDirectory(prefix="host-input-") as tmp:
            check(Path(sys.argv[1]).resolve(), Path(tmp), disconnect)
