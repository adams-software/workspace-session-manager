#!/usr/bin/env python3
"""Run after `zig build`: python3 ptylog/test_retention.py zig-out/bin/ptylog."""
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def check(binary, indices, budget, survivors, existing_base=b""):
    with tempfile.TemporaryDirectory(prefix="ptylog-retention-") as tmp:
        base = Path(tmp) / "session.log"
        base.write_bytes(existing_base)
        contents = {}
        # Deliberately create files in reverse order; cleanup must sort numerically.
        for index in reversed(indices):
            path = Path(f"{base}.{index:06d}")
            contents[path] = bytes([index % 256]) * 700
            path.write_bytes(contents[path])
        unrelated = [
            Path(f"{base}.notes"),
            Path(f"{base}.000001.bak"),
            Path(f"{base}x.000001"),
        ]
        for path in unrelated:
            path.write_bytes(b"leave me alone")
        directory = Path(f"{base}.000000")
        directory.mkdir()
        start = time.monotonic()
        result = subprocess.run(
            [
                str(binary),
                "--log",
                str(base),
                "--log-budget-bytes",
                str(budget),
                "--log-segment-bytes",
                "1024",
                "--",
                "/bin/true",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert not result.stderr, result.stderr.decode(errors="replace")
        expected = {Path(f"{base}.{index:06d}") for index in survivors}
        if existing_base:
            rolled = Path(f"{base}.{max(indices) + 1:06d}")
            expected.add(rolled)
            contents[rolled] = existing_base
        actual = {
            p
            for p in base.parent.glob(base.name + ".*")
            if p.is_file() and p.name[len(base.name) + 1 :].isdigit()
        }
        assert actual == expected, (actual, expected)
        for path in expected:
            assert path.read_bytes() == contents[path], f"changed contents: {path}"
        assert base.read_bytes() == b""
        assert sum(p.stat().st_size for p in actual) <= budget
        assert directory.is_dir()
        for path in unrelated:
            assert path.read_bytes() == b"leave me alone"
        print(
            f"indices={indices}: passed in {time.monotonic() - start:.3f}s", flush=True
        )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_retention.py /path/to/ptylog")
    binary = Path(sys.argv[1]).resolve()
    check(binary, [10, 11, 12], 1024, [12])
    check(binary, [999999, 1000000, 1000001], 1024, [1000001])
    check(binary, [100000000, 100000010, 100000020], 1024, [100000020])
    check(binary, [100000000, 100000020], 4096, [100000000, 100000020])
    check(binary, [100000000, 100000020], 1024, [100000020], b"previous run\n")
