#!/usr/bin/env python3
"""Linux real-binary regression for ptylog memory growth and post-workload CPU."""
import argparse
import ctypes
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

GROWTH_LIMIT_KIB = 12 * 1024
CPU_LIMIT = 5
WARMUP_BATCHES = 4
MIN_BATCHES = 32
CHILD = r"""
import os, pathlib, sys, tty
tty.setraw(0)
ready = pathlib.Path(sys.argv[1])
ready.with_suffix(".tmp").write_text(str(os.getpid()))
ready.with_suffix(".tmp").replace(ready)
for batch, command in enumerate(sys.stdin):
    if command.strip() == "quit":
        break
    if batch % 2:
        text = "".join("\x1b]8;;https://example/%d/%d\x1b\\link\x1b]8;;\x1b\\\r\n"
                       % (batch, line) for line in range(4000))
    else:
        text = "scrolling line\r\n" * 4000
    sys.stdout.write(text + "DONE%d\r\nWAIT\r\n" % batch)
    sys.stdout.flush()
"""


def report(**values):
    print(json.dumps(values, sort_keys=True), flush=True)


def usage(process):
    if process.poll() is not None:
        raise RuntimeError(f"ptylog exited unexpectedly: {process.returncode}")
    fields = Path(f"/proc/{process.pid}/stat").read_text().rsplit(")", 1)[1].split()
    return {
        "rss_kib": int(fields[21]) * (os.sysconf("SC_PAGE_SIZE") // 1024),
        "cpu_seconds": (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK"),
    }


def log_tail(path):
    # Numeric order still works after six-digit segment numbers roll over.
    segments = sorted(
        (
            part
            for part in path.parent.glob(path.name + ".*")
            if part.suffix[1:].isdigit()
        ),
        key=lambda part: int(part.suffix[1:]),
    )
    data = b""
    try:
        for part in segments[-1:] + [path]:
            with part.open("rb") as stream:
                stream.seek(max(0, os.fstat(stream.fileno()).st_size - 4096))
                data += stream.read(4096)
    except FileNotFoundError:
        return b""  # Rotation may race the read; retry.
    return data


def wait_for(process, check):
    deadline = time.monotonic() + 30
    while not check():
        usage(process)
        if time.monotonic() >= deadline:
            raise RuntimeError("timed out waiting for workload progress")
        time.sleep(0.01)


def check(binary, soak_seconds):
    # Reap the PTY child ourselves if a failing helper leaves it orphaned.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "cannot enable child subreaper")
    with tempfile.TemporaryDirectory(prefix="ptylog-resources-") as tmp:
        directory = Path(tmp)
        log = directory / "session.log"
        ready = directory / "child.pid"
        with (directory / "stderr").open("w+b") as errors:
            process = subprocess.Popen(
                [
                    str(binary),
                    "--log",
                    str(log),
                    "--segment",
                    "65536",
                    "--keep",
                    "4",
                    "--",
                    sys.executable,
                    "-u",
                    "-c",
                    CHILD,
                    str(ready),
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=errors,
            )
            child_pid = None
            child_fd = None
            try:
                wait_for(process, ready.exists)
                child_pid = int(ready.read_text())
                child_fd = os.pidfd_open(child_pid)
                start = time.monotonic()
                baseline = None
                peak_growth = 0
                batch = 0
                while batch < MIN_BATCHES or time.monotonic() - start < soak_seconds:
                    process.stdin.write(b"batch\n")
                    process.stdin.flush()
                    marker = f"DONE{batch}".encode()
                    wait_for(process, lambda: marker in log_tail(log))
                    current = usage(process)["rss_kib"]
                    if batch == WARMUP_BATCHES - 1:
                        baseline = current
                    growth = None if baseline is None else current - baseline
                    if growth is not None:
                        peak_growth = max(peak_growth, growth)
                    report(
                        type="batch",
                        batch=batch,
                        rss_kib=current,
                        growth_kib=growth,
                        elapsed_seconds=round(time.monotonic() - start, 3),
                    )
                    if peak_growth > GROWTH_LIMIT_KIB:
                        raise RuntimeError(
                            f"RSS grew {peak_growth} KiB after warm-up; limit {GROWTH_LIMIT_KIB}"
                        )
                    batch += 1
                time.sleep(0.2)
                before = usage(process)["cpu_seconds"]
                idle_start = time.monotonic()
                time.sleep(1.5)
                cpu = (
                    100
                    * (usage(process)["cpu_seconds"] - before)
                    / (time.monotonic() - idle_start)
                )
                report(type="idle", cpu_percent=round(cpu, 2), limit_percent=CPU_LIMIT)
                if cpu > CPU_LIMIT:
                    raise RuntimeError(
                        f"idle CPU {cpu:.2f}% exceeds {CPU_LIMIT}% of one core"
                    )
                process.stdin.write(b"quit\n")
                process.stdin.flush()
                if process.wait(timeout=5) != 0:
                    raise RuntimeError(
                        f"ptylog exited with status {process.returncode}"
                    )
                report(
                    type="result",
                    passed=True,
                    batches=batch,
                    peak_growth_kib=peak_growth,
                )
            finally:
                # A pidfd targets the original child even if its numeric PID is reused.
                if child_fd is not None:
                    try:
                        signal.pidfd_send_signal(child_fd, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    finally:
                        os.close(child_fd)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                process.stdin.close()
                if child_pid is not None:
                    try:
                        os.waitpid(child_pid, 0)
                    except ChildProcessError:
                        pass  # The helper already reaped it.
                errors.seek(0)
                diagnostic = errors.read(8192).decode(errors="replace")
                if diagnostic:
                    print(diagnostic, file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument(
        "--soak-seconds",
        type=float,
        default=0,
        help="keep repeating for this duration (at least 32 batches)",
    )
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("requires Linux /proc")
    if not math.isfinite(args.soak_seconds) or not 0 <= args.soak_seconds <= 86400:
        parser.error("soak duration must be finite and between 0 and 86400 seconds")
    try:
        check(args.binary.resolve(), args.soak_seconds)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        report(type="result", passed=False, error=str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
