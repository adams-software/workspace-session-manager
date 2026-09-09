#!/usr/bin/env python3
"""Linux regression: idle host CPU with stalled output or closed control input.

Run from the repository root after `(cd host && zig build)`:
    python3 host/scripts/test_idle_cpu.py host/zig-out/bin/host
"""
from contextlib import contextmanager
from pathlib import Path
import os
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time


def wait_for(check, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.02)
    raise AssertionError("timed out waiting for workload progress")


@contextmanager
def process(argv):
    p = subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        yield p
    finally:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait(timeout=5)
        for stream in (p.stdin, p.stdout, p.stderr):
            if stream:
                stream.close()


def cpu_seconds(p):
    assert p.poll() is None, "host exited unexpectedly"
    # Field 2 (comm) may contain spaces or parentheses; fields after it start at 3.
    fields = Path(f"/proc/{p.pid}/stat").read_text().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def idle_cpu(p, case, limit):
    time.sleep(0.2)
    before = cpu_seconds(p)
    start = time.monotonic()
    time.sleep(1.2)
    cpu = 100 * (cpu_seconds(p) - before) / (time.monotonic() - start)
    print(f"{case}: {cpu:.2f}% of one core", flush=True)
    return cpu < limit


def recv_until(sock, marker, timeout=15):
    result = bytearray()
    deadline = time.monotonic() + timeout
    while marker not in result:
        assert time.monotonic() < deadline, f"missing output marker {marker!r}"
        if not select.select([sock], [], [], 0.1)[0]:
            continue
        chunk = sock.recv(65536)
        assert chunk, "unexpected EOF"
        result.extend(chunk)
        assert len(result) < 16 * 1024 * 1024, "unexpected output volume"
    return bytes(result)


def host_cases(host, tmp, cpu_limit):
    path = tmp / "host.sock"
    child = """import sys
print("ready", flush=True)
for line in sys.stdin:
    print("x" * 1048576, flush=True)
    print("DONE", flush=True)
"""
    with process(
        [
            str(host),
            str(path),
            "--headless",
            "--",
            sys.executable,
            "-u",
            "-c",
            child,
        ]
    ) as p:
        wait_for(path.exists)
        detached_ok = idle_cpu(p, "host detached with unread output", cpu_limit)
        with socket.socket(socket.AF_UNIX) as owner:
            owner.connect(str(path))
            recv_until(owner, b"ready")
            owner.sendall(b"burst\n")
            blocked_ok = idle_cpu(p, "host blocked owner", cpu_limit)
            output = recv_until(owner, b"DONE")
            assert output.count(b"x") == 1048576, "backpressure lost output"
        assert detached_ok and blocked_ok, "idle CPU exceeded 5% of one core"


def host_eof_cases(host, tmp, cpu_limit):
    child = """import os, sys
for line in sys.stdin:
    size = os.get_terminal_size(0)
    print(f"size={size.columns}x{size.lines}", flush=True)
"""
    eof_ok = True
    for headless in (False, True):
        path = tmp / f"eof-{headless}.sock"
        args = [str(host), str(path)] + (["--headless"] if headless else [])
        with process(args + ["--", sys.executable, "-u", "-c", child]) as p:
            wait_for(path.exists)
            if not headless:
                p.stdin.write(b"resize 90 30\nresize 103 37\n")
                p.stdin.flush()
            p.stdin.close()
            eof_ok = (
                idle_cpu(p, f"host stdin EOF (headless={headless})", cpu_limit)
                and eof_ok
            )
            with socket.socket(socket.AF_UNIX) as owner:
                owner.connect(str(path))
                owner.sendall(b"size\n")
                output = recv_until(owner, b"size=")
                if not headless:
                    if b"size=103x37" not in output:
                        output += recv_until(owner, b"\n")
                    assert b"size=103x37" in output, "pending resize lost at control EOF"
    assert eof_ok, "closed stdin keeps waking the host"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_idle_cpu.py /path/to/host")
    with tempfile.TemporaryDirectory(prefix="host-idle-") as tmp:
        host_cases(Path(sys.argv[1]).resolve(), Path(tmp), 5.0)
        host_eof_cases(Path(sys.argv[1]).resolve(), Path(tmp), 5.0)
