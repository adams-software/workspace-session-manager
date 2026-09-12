#!/usr/bin/env python3
"""Sample a Linux process tree without attaching to its terminal or sockets."""
import argparse
import json
import math
import os
from pathlib import Path
import sys
import time

MAX_PROCESSES = 512
MAX_OUTPUT_BYTES = 20 * 1024 * 1024
HZ = os.sysconf("SC_CLK_TCK")
PAGE_KIB = os.sysconf("SC_PAGE_SIZE") // 1024


def parse_stat(text):
    # comm can itself contain spaces and parentheses; field 3 follows the last ).
    fields = text.rsplit(")", 1)[1].split()
    return {
        "state": fields[0],
        "ppid": int(fields[1]),
        "cpu_seconds": (int(fields[11]) + int(fields[12])) / HZ,
        "threads": int(fields[17]),
        "start_ticks": int(fields[19]),
        "rss_kib": int(fields[21]) * PAGE_KIB,
    }


def processes():
    table = {}
    for entry in Path("/proc").iterdir():
        if entry.name.isdecimal():
            try:
                table[int(entry.name)] = parse_stat((entry / "stat").read_text())
            except (OSError, ValueError, IndexError):
                pass  # Processes can exit while /proc is being read.
    return table


def descendants(table, identities):
    selected = {
        pid
        for pid, start in identities.items()
        if pid in table and table[pid]["start_ticks"] == start
    }
    children = {}
    for pid, row in table.items():
        children.setdefault(row["ppid"], []).append(pid)
    pending = list(selected)
    while pending:
        if len(selected) > MAX_PROCESSES:
            raise ValueError(f"capture limited to {MAX_PROCESSES} processes")
        for pid in children.get(pending.pop(), []):
            if pid not in selected:
                selected.add(pid)
                pending.append(pid)
    return selected


def capture(pid, row, previous, elapsed):
    result = {"pid": pid, **row}
    old = previous.get(pid)
    result["cpu_percent"] = (
        round(100 * (row["cpu_seconds"] - old["cpu_seconds"]) / elapsed, 2)
        if old and old["start_ticks"] == row["start_ticks"] and elapsed > 0
        else None
    )
    root = Path(f"/proc/{pid}")
    try:
        executable = Path(os.readlink(root / "exe")).name
        fd_count = sum(1 for _ in (root / "fd").iterdir())
        # Avoid attaching metadata from a process that reused this PID.
        if parse_stat((root / "stat").read_text())["start_ticks"] == row["start_ticks"]:
            result.update(executable=executable, fd_count=fd_count)
    except (OSError, ValueError, IndexError):
        pass
    return result


class Writer:
    def __init__(self, stream):
        self.stream = stream
        self.written = 0

    def emit(self, value):
        line = json.dumps(value, sort_keys=True) + "\n"
        size = len(line.encode("utf-8"))
        if self.written + size > MAX_OUTPUT_BYTES:
            raise ValueError("capture reached its 20 MiB output limit")
        self.stream.write(line)
        self.stream.flush()
        self.written += size


def collect(pid, duration, interval, stream):
    table = processes()
    if pid not in table:
        raise ValueError("no readable process found for the requested PID")
    identities = {pid: table[pid]["start_ticks"]}
    previous = {}
    writer = Writer(stream)
    start = last = time.monotonic()
    writer.emit(
        {
            "type": "header",
            "schema": 1,
            "root_pid": pid,
            "cpu_units": "percent of one core",
            "memory_units": "KiB RSS",
            "interval_seconds": interval,
            "duration_seconds": duration,
        }
    )
    while True:
        now = time.monotonic()
        selected = descendants(table, identities)
        # Keep observed orphans, but prune exited identities on every sample.
        identities = {pid: table[pid]["start_ticks"] for pid in selected}
        writer.emit(
            {
                "type": "sample",
                "elapsed_seconds": round(now - start, 3),
                "processes": [
                    capture(pid, table[pid], previous, now - last)
                    for pid in sorted(selected)
                ],
            }
        )
        if not selected or now - start >= duration:
            return
        previous = {pid: table[pid] for pid in selected}
        last = now
        time.sleep(min(interval, max(0, duration - (time.monotonic() - start))))
        table = processes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", required=True, type=int, help="root helper PID")
    parser.add_argument(
        "--duration", type=float, default=60, help="seconds, up to 86400"
    )
    parser.add_argument(
        "--interval", type=float, default=1, help="seconds, from 0.25 to 60"
    )
    parser.add_argument(
        "--output", type=Path, help="new JSONL file; defaults to stdout"
    )
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("this collector requires Linux /proc")
    if args.pid <= 0 or not (
        math.isfinite(args.duration) and 0 < args.duration <= 86400
    ):
        parser.error("PID must be positive; duration must be finite and in (0, 86400]")
    if not 0.25 <= args.interval <= 60:
        parser.error("interval must be in [0.25, 60] seconds")
    try:
        if args.output:
            with args.output.open("x", encoding="utf-8") as stream:
                collect(args.pid, args.duration, args.interval, stream)
        else:
            collect(args.pid, args.duration, args.interval, sys.stdout)
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
