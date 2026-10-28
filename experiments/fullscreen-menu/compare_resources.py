#!/usr/bin/env python3
"""Compare main and epic WSM stacks under identical attached workloads."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import statistics
import struct
import subprocess
import tempfile
import termios
import time


SAMPLE_SECONDS = 1.0
RUNS = 3

CHILD = r'''#!/usr/bin/python3
import os, select, time, tty
tty.setraw(0)
mode = os.environ["WSM_COMPARE_MODE"]
os.write(1, b"\x1b[2J\x1b[HCOMPARE_READY")
tick = 0
while True:
    timeout = 0.01 if mode == "output" else 1.0
    ready, _, _ = select.select([0], [], [], timeout)
    if ready:
        if not os.read(0, 4096):
            break
    elif mode == "output":
        tick += 1
        os.write(1, b"\x1b[2J\x1b[HCOMPARE_OUTPUT " + str(tick).encode())
'''


def collect(fd: int, seconds: float, needle: bytes | None = None) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], min(0.05, deadline - time.monotonic()))
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        data.extend(chunk)
        if needle is not None and needle in data:
            return bytes(data)
    if needle is not None:
        raise RuntimeError(f"timed out waiting for {needle!r}; tail={bytes(data[-500:])!r}")
    return bytes(data)


def matching_processes(root: str, viewer_pid: int) -> dict[int, bytes]:
    matches = {}
    root_bytes = root.encode()
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        try:
            command = (entry / "cmdline").read_bytes().replace(b"\0", b" ")
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if pid == viewer_pid or root_bytes in command:
            matches[pid] = command
    return matches


def process_stats(processes: dict[int, bytes]) -> tuple[int, int, int]:
    page_kib = os.sysconf("SC_PAGE_SIZE") // 1024
    rss_kib = 0
    fd_count = 0
    cpu_ticks = 0
    for pid, command in processes.items():
        proc = Path("/proc") / str(pid)
        try:
            executable = (proc / "exe").resolve().name
            rss_pages = int((proc / "statm").read_text().split()[1])
            stat = (proc / "stat").read_text().split()
            descriptors = sum(1 for _ in (proc / "fd").iterdir())
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if executable.startswith("python") and b"compare-child.py" in command:
            continue
        rss_kib += rss_pages * page_kib
        fd_count += descriptors
        cpu_ticks += int(stat[13]) + int(stat[14])
    return rss_kib, fd_count, cpu_ticks


def one_run(wsm: Path, mode: str) -> dict[str, float | int]:
    with tempfile.TemporaryDirectory(prefix="wsm-resource-compare-") as tmp:
        root = Path(tmp)
        child = root / "compare-child.py"
        child.write_text(CHILD)
        child.chmod(0o700)
        env = os.environ.copy()
        env.update(WSM_ROOT=tmp, SHELL=str(child), WSM_COMPARE_MODE=mode)

        started = time.monotonic()
        pid, fd = pty.fork()
        if pid == 0:
            os.execve(str(wsm), [str(wsm), "create", "compare"], env)
        try:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            collect(fd, 8, b"COMPARE_READY")
            startup_ms = (time.monotonic() - started) * 1000
            collect(fd, 1.0)

            before_processes = matching_processes(tmp, pid)
            before = process_stats(before_processes)
            collect(fd, SAMPLE_SECONDS)
            after_processes = matching_processes(tmp, pid)
            after = process_stats(after_processes)
            cpu_seconds = max(0, after[2] - before[2]) / os.sysconf("SC_CLK_TCK")
            return {
                "startup_ms": round(startup_ms, 1),
                "rss_kib": after[0],
                "fds": after[1],
                "processes": len(after_processes),
                "cpu_seconds": round(cpu_seconds, 3),
            }
        finally:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            try:
                os.close(fd)
            except OSError:
                pass
            subprocess.run(
                [wsm, "kill", "-f", "compare"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )


def summarize(runs: list[dict[str, float | int]]) -> dict[str, float | int]:
    return {
        key: round(statistics.median(run[key] for run in runs), 3)
        for key in runs[0]
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--main", type=Path, required=True)
    parser.add_argument("--epic", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=RUNS)
    args = parser.parse_args()

    result = {}
    for mode in ("idle", "output"):
        result[mode] = {}
        for name, binary in (("main", args.main), ("epic", args.epic)):
            runs = [one_run(binary.resolve(), mode) for _ in range(args.runs)]
            result[mode][name] = {"median": summarize(runs), "runs": runs}
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
