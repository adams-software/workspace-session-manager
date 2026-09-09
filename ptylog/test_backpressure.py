#!/usr/bin/env python3
"""Linux regression: python3 ptylog/test_backpressure.py zig-out/bin/ptylog."""
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time

CHUNK = b"\x1b[0m" * 16384
TOTAL = len(CHUNK) * 128
CHILD = r"""
import hashlib, os, pathlib, sys, time, tty
mode, directory, total = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])
tty.setraw(0)
(directory / "ready").touch()
while not (directory / "go").exists(): time.sleep(0.005)
if mode == "output":
    chunk = b"\x1b[0m" * 16384
    for _ in range(total // len(chunk)):
        sys.stdout.buffer.write(chunk)
    sys.stdout.buffer.flush()
else:
    digest = hashlib.sha256()
    while total:
        data = os.read(0, min(total, 65536))
        digest.update(data)
        total -= len(data)
    print(digest.hexdigest(), flush=True)
"""


@contextmanager
def launch(binary, directory, mode):
    p = subprocess.Popen(
        [
            str(binary),
            "--log",
            str(directory / "session.log"),
            "--",
            sys.executable,
            "-c",
            CHILD,
            mode,
            str(directory),
            str(TOTAL),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 5
        while not (directory / "ready").exists():
            assert (
                p.poll() is None and time.monotonic() < deadline
            ), "child failed to start"
            time.sleep(0.01)
        yield p
    finally:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait(timeout=5)
        for stream in (p.stdin, p.stdout, p.stderr):
            stream.close()


def usage(p):
    assert p.poll() is None, "ptylog exited unexpectedly"
    fields = Path(f"/proc/{p.pid}/stat").read_text().rsplit(")", 1)[1].split()
    cpu = (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    rss = int(fields[21]) * os.sysconf("SC_PAGE_SIZE")
    return cpu, rss


def check_stalled(p, initial_rss):
    time.sleep(0.3)
    before, _ = usage(p)
    start = time.monotonic()
    time.sleep(1)
    after, rss = usage(p)
    cpu = 100 * (after - before) / (time.monotonic() - start)
    growth = rss - initial_rss
    print(f"stalled: CPU={cpu:.2f}%, RSS growth={growth / 1024:.0f} KiB", flush=True)
    assert cpu < 5, "stalled relay spins instead of waiting"
    assert growth < 4 * 1024 * 1024, "stalled relay keeps buffering"


def read_all(p):
    digest, size = hashlib.sha256(), 0
    deadline = time.monotonic() + 30
    while True:
        assert time.monotonic() < deadline, "output did not resume"
        if not select.select([p.stdout], [], [], 0.1)[0]:
            continue
        data = os.read(p.stdout.fileno(), 65536)
        if not data:
            break
        digest.update(data)
        size += len(data)
    assert p.wait(timeout=5) == 0, p.stderr.read()
    return digest.hexdigest(), size


def send_until(p, sent, deadline):
    while sent < TOTAL and time.monotonic() < deadline:
        if not select.select([], [p.stdin], [], 0.01)[1]:
            continue
        try:
            offset = sent % len(CHUNK)
            sent += os.write(
                p.stdin.fileno(),
                CHUNK[offset : offset + min(len(CHUNK) - offset, TOTAL - sent)],
            )
        except BlockingIOError:
            pass
    return sent


def check(binary, mode):
    with tempfile.TemporaryDirectory(prefix="ptylog-backpressure-") as tmp:
        directory = Path(tmp)
        with launch(binary, directory, mode) as p:
            _, initial_rss = usage(p)
            if mode == "output":
                (directory / "go").touch()
                check_stalled(p, initial_rss)
                digest, size = read_all(p)
                assert (
                    size == TOTAL and digest == hashlib.sha256(CHUNK * 128).hexdigest()
                )
            else:
                os.set_blocking(p.stdin.fileno(), False)
                sent = send_until(p, 0, time.monotonic() + 1)
                check_stalled(p, initial_rss)
                assert sent < 1024 * 1024, "input producer was not backpressured"
                (directory / "go").touch()
                assert send_until(p, sent, time.monotonic() + 30) == TOTAL
                digest, size = read_all(p)
                expected = (hashlib.sha256(CHUNK * 128).hexdigest() + "\n").encode()
                assert (
                    size == len(expected)
                    and digest == hashlib.sha256(expected).hexdigest()
                )
            print(f"{mode}: resumed with all {TOTAL} bytes intact", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_backpressure.py /path/to/ptylog")
    for mode in ("output", "input"):
        check(Path(sys.argv[1]).resolve(), mode)
