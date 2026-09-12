"""Regression checks for the Linux resource collector (standard library only)."""
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import diagnose_resources as collector


class CollectorTests(unittest.TestCase):
    def test_stat_handles_parentheses_and_field_offsets(self):
        fields = ["0"] * 22
        for index, value in {
            0: "S",
            1: "42",
            11: "200",
            12: "50",
            17: "3",
            19: "999",
            21: "123",
        }.items():
            fields[index] = value
        row = collector.parse_stat("7 (name with ) parentheses) " + " ".join(fields))
        self.assertEqual(
            row,
            {
                "state": "S",
                "ppid": 42,
                "cpu_seconds": 250 / collector.HZ,
                "threads": 3,
                "start_ticks": 999,
                "rss_kib": 123 * collector.PAGE_KIB,
            },
        )

    def test_tracks_observed_orphans_and_rejects_reused_pids(self):
        table = {
            10: {"ppid": 1, "start_ticks": 100},
            20: {"ppid": 10, "start_ticks": 200},
            30: {"ppid": 20, "start_ticks": 300},
        }
        selected = collector.descendants(table, {10: 100})
        self.assertEqual(selected, {10, 20, 30})
        identities = {pid: table[pid]["start_ticks"] for pid in selected}
        table[10] = {"ppid": 1, "start_ticks": 999}
        table[20]["ppid"] = 1
        table[40] = {"ppid": 10, "start_ticks": 1000}
        self.assertEqual(collector.descendants(table, identities), {20, 30})

    def test_process_and_output_limits(self):
        table = {pid: {"ppid": pid - 1, "start_ticks": pid} for pid in range(1, 5)}
        with patch.object(collector, "MAX_PROCESSES", 3):
            with self.assertRaises(ValueError):
                collector.descendants(table, {1: 1})
        stream = io.StringIO()
        writer = collector.Writer(stream)
        with patch.object(collector, "MAX_OUTPUT_BYTES", 4):
            writer.emit({})
            with self.assertRaises(ValueError):
                writer.emit({})
        self.assertEqual(stream.getvalue(), "{}\n")

    def test_cpu_delta_requires_same_identity(self):
        row = {"start_ticks": 100, "cpu_seconds": 3}
        with patch.object(collector.os, "readlink", side_effect=FileNotFoundError):
            self.assertIsNone(collector.capture(1, row, {}, 2)["cpu_percent"])
            self.assertEqual(
                collector.capture(
                    1, row, {1: {"start_ticks": 100, "cpu_seconds": 2}}, 2
                )["cpu_percent"],
                50,
            )
            self.assertIsNone(
                collector.capture(
                    1, row, {1: {"start_ticks": 99, "cpu_seconds": 2}}, 2
                )["cpu_percent"]
            )

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires /proc")
    def test_live_tree_and_exclusive_output(self):
        script = Path(collector.__file__).resolve()
        # The parent stays idle while its child consumes CPU; both must be sampled.
        program = """import subprocess, sys
child = subprocess.Popen([sys.executable, "-c", "while True: pass"])
print(child.pid, flush=True)
try:
    sys.stdin.read()
finally:
    child.terminate()
    child.wait()
"""
        with subprocess.Popen(
            [sys.executable, "-c", program],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        ) as parent:
            try:
                child_pid = int(parent.stdout.readline())
                with tempfile.TemporaryDirectory() as tmp:
                    output = Path(tmp) / "capture.jsonl"
                    command = [
                        sys.executable,
                        str(script),
                        "--pid",
                        str(parent.pid),
                        "--duration",
                        "0.6",
                        "--interval",
                        "0.25",
                        "--output",
                        str(output),
                    ]
                    subprocess.run(command, check=True, timeout=10)
                    original = output.read_bytes()
                    records = [json.loads(line) for line in original.splitlines()]
                    self.assertEqual(records[0]["type"], "header")
                    samples = records[1:]
                    self.assertGreaterEqual(len(samples), 2)
                    for sample in samples:
                        self.assertEqual(
                            {row["pid"] for row in sample["processes"]},
                            {parent.pid, child_pid},
                        )
                        for row in sample["processes"]:
                            self.assertGreater(row["rss_kib"], 0)
                            self.assertGreater(row["fd_count"], 0)
                            self.assertNotIn("cmdline", row)
                            self.assertNotIn("environ", row)
                    self.assertTrue(
                        any(
                            row["cpu_percent"] > 0
                            for sample in samples[1:]
                            for row in sample["processes"]
                            if row["pid"] == child_pid
                        )
                    )
                    result = subprocess.run(command, capture_output=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(output.read_bytes(), original)
                    for value in ("nan", "inf", "0"):
                        result = subprocess.run(
                            command + ["--duration", value],
                            capture_output=True,
                            timeout=10,
                        )
                        self.assertEqual(result.returncode, 2)
            finally:
                parent.stdin.close()
                parent.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
