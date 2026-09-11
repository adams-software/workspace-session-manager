#!/usr/bin/env python3
"""Linux regression for final PTY control output and bounded exit draining.

Run after building: python3 vpty/scripts/test_final_output.py [path/to/vpty]
"""
import ctypes
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def wait_for(check):
    deadline = time.monotonic() + 5
    while not check():
        assert time.monotonic() < deadline, "workload did not reach expected state"
        time.sleep(0.01)


def final_control(binary, length, flags):
    with tempfile.TemporaryDirectory(prefix="vpty-final-output-") as tmp:
        root = Path(tmp)
        code = """import os,pathlib,time,sys
r=pathlib.Path(sys.argv[1]); (r/"ready").write_text(str(os.getpid()))
while not (r/"go").exists(): time.sleep(.01)
data=b"\\x1b]52;c;"+b"A"*(int(sys.argv[2])-8)+b"\\x07"
while data:
 n=os.write(1,data); data=data[n:]
"""
        proc = subprocess.Popen(
            [str(binary), *flags, "--", sys.executable, "-c", code, tmp, str(length)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            wait_for((root / "ready").exists)
            pid = int((root / "ready").read_text())
            os.kill(proc.pid, signal.SIGSTOP)
            (root / "go").touch()
            # Child is a zombie until the stopped vpty can observe its exit.
            wait_for(
                lambda: Path(f"/proc/{pid}/stat")
                .read_text()
                .rsplit(")", 1)[1]
                .split()[0]
                == "Z"
            )
            os.kill(proc.pid, signal.SIGCONT)
            output, errors = proc.communicate(timeout=3)
            assert proc.returncode == 0, errors.decode(errors="replace")
            expected = b"\x1b]52;c;" + b"A" * (length - 8) + b"\x07"
            assert expected in output, f"lost final {length}-byte OSC sequence"
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            proc.stdout.close()
            proc.stderr.close()


def bounded_exit(binary, flags):
    with tempfile.TemporaryDirectory(prefix="vpty-inherited-pty-") as tmp:
        pidfile = Path(tmp) / "pid"
        code = """import os,signal,time,sys,pathlib
signal.signal(signal.SIGHUP,signal.SIG_IGN)
pid=os.fork()
if pid:
 pathlib.Path(sys.argv[1]).write_text(str(pid)); os._exit(0)
signal.signal(signal.SIGHUP,signal.SIG_IGN)
os.write(1,b"\\x1b]52;c;"+b"A"*65536+b"\\x07")
time.sleep(30)
"""
        start = time.monotonic()
        proc = subprocess.Popen(
            [str(binary), *flags, "--", sys.executable, "-c", code, str(pidfile)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            # Keep stdout unread and let the descendant retain the PTY.
            assert proc.wait(timeout=2) == 0, proc.stderr.read()
            assert time.monotonic() - start < 1.5
            pid = int(pidfile.read_text())
            assert (
                Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
                != "Z"
            ), "descendant exited before drain deadline"
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            proc.stdout.close()
            proc.stderr.close()
            if pidfile.exists():
                pid = int(pidfile.read_text())
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)


if __name__ == "__main__":
    # Reap the intentional orphan used to exercise inherited PTY descriptors.
    assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0  # PR_SET_CHILD_SUBREAPER
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/vpty").resolve()
    for flags in ([], ["--rows", "24", "--cols", "80"]):
        for length in (4096, 8192):
            final_control(binary, length, flags)
        bounded_exit(binary, flags)
        print(
            f"{'bounded' if flags else 'fullscreen'}: final controls preserved; inherited PTY and stalled stdout exit bounded"
        )
