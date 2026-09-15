#!/usr/bin/env python3
"""Spike: can dropping hidden viewer bytes + same-size resize restore a session?

Runs only temporary sessions; does not implement the proposed menu. Linux only.
Usage: python3 experiments/fullscreen-menu/probe_handoff.py zig-out/bin/wsm
"""
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import time

PRODUCER = r'''#!/usr/bin/python3
import os, tty
tty.setraw(0)
os.write(1, b"\x1b[2J\x1b[HBASE_SCREEN")
pending = b""
while True:
    chunk = os.read(0, 1024)
    if not chunk:
        break
    pending += chunk
    while b"\n" in pending:
        command, pending = pending.split(b"\n", 1)
        if command == b"hidden":
            os.write(1, b"\x1b[?2004h\x1b[?1000h\x1b[2J\x1b[HHIDDEN_SCREEN")
'''


def collect(sock, seconds=0.6):
    data = bytearray()
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not select.select([sock], [], [], max(0, deadline - time.monotonic()))[0]:
            break
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("session connection closed")
        data.extend(chunk)
        if len(data) > 1024 * 1024:
            raise RuntimeError("unexpected output volume")
    return bytes(data)


def connect(path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(str(path))
    except BaseException:
        sock.close()
        raise
    return sock


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="wsm-menu-probe-") as tmp:
        root = Path(tmp)
        producer = root / "producer"
        producer.write_text(PRODUCER)
        producer.chmod(0o700)
        env = os.environ.copy()
        env.update(WSM_ROOT=tmp, SHELL=str(producer))
        try:
            subprocess.run([binary, "create", "-d", "probe"], env=env, check=True, stdout=subprocess.DEVNULL)
            with connect(root / "probe.wsm") as data, connect(root / "probe.ctl") as control:
                control.sendall(b"resize 80 24\n")
                collect(control)
                initial = collect(data)
                assert b"BASE_SCREEN" in initial, "initial screen missing"
                data.sendall(b"hidden\n")
                hidden = collect(data)  # Simulate a menu discarding session output.
                assert b"HIDDEN_SCREEN" in hidden, "hidden update missing"
                assert b"\x1b[?2004h" in hidden and b"\x1b[?1000h" in hidden
                control.sendall(b"resize 80 24\n")
                collect(control)
                restored = collect(data)
                result = {
                    "same_size_resize_repaints_screen": b"HIDDEN_SCREEN" in restored,
                    "replays_bracketed_paste_mode": b"\x1b[?2004h" in restored,
                    "replays_mouse_tracking_mode": b"\x1b[?1000h" in restored,
                    "hidden_bytes": len(hidden),
                    "restored_bytes": len(restored),
                }
                print(json.dumps(result, indent=2))
        finally:
            subprocess.run([binary, "kill", "-f", "probe"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
