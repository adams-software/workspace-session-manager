#!/usr/bin/env python3
"""Stress WSM presentation transitions and check bounded hidden behavior."""

import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time


TOGGLES = 20
HIDDEN_SECONDS = 1.0
RSS_GROWTH_LIMIT_KIB = 24 * 1024
FD_GROWTH_LIMIT = 4
HIDDEN_CPU_LIMIT_SECONDS = 0.75
PROCESS_GROWTH_LIMIT = 0

PRODUCER = r'''#!/usr/bin/python3
import fcntl, os, select, signal, struct, termios, time, tty

tty.setraw(0)
progress_path = os.environ["WSM_STRESS_PROGRESS"]
exit_path = os.environ["WSM_STRESS_EXIT"]
progress = os.open(progress_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
resized = True
size_label = b""

def on_resize(_signum, _frame):
    global resized
    resized = True

signal.signal(signal.SIGWINCH, on_resize)
tick = 0
try:
    while True:
        if os.path.exists(exit_path):
            break
        if resized:
            rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
            size_label = f" SIZE:{cols}x{rows}".encode()
            resized = False
        tick += 1
        os.write(1, b"\x1b[2J\x1b[HSTRESS_SCREEN " + str(tick).encode() + size_label + b"\x1b[?2004h")
        if tick % 10 == 0:
            os.write(progress, b".")
        ready, _, _ = select.select([0], [], [], 0.005)
        if ready and not os.read(0, 4096):
            break
finally:
    os.close(progress)
'''


def read_until(fd: int, needle: bytes, timeout: float = 8) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], min(0.1, deadline - time.monotonic()))
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        data.extend(chunk)
        if needle in data:
            return bytes(data)
    raise RuntimeError(f"timed out waiting for {needle!r}; terminal tail={bytes(data[-1000:])!r}")


def collect(fd: int, seconds: float) -> bytes:
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
    return bytes(data)


def matching_processes(root: str, wsm_pid: int) -> dict[int, bytes]:
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
        if pid == wsm_pid or root_bytes in command:
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
            rss_pages = int((proc / "statm").read_text().split()[1])
            stat = (proc / "stat").read_text().split()
            descriptors = sum(1 for _ in (proc / "fd").iterdir())
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        rss_kib += rss_pages * page_kib
        fd_count += descriptors
        if b"/vpty " in command or b"/wsm " in command:
            cpu_ticks += int(stat[13]) + int(stat[14])
    return rss_kib, fd_count, cpu_ticks


def wait_for_processes(root: str, wsm_pid: int, timeout: float = 5) -> dict[int, bytes]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        processes = matching_processes(root, wsm_pid)
        if any(b"/vpty " in command for command in processes.values()):
            return processes
        time.sleep(0.05)
    raise RuntimeError("vpty process was not discoverable for resource checks")


def wait_for_exit(pid: int, timeout: float = 8) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        finished, _ = os.waitpid(pid, os.WNOHANG)
        if finished == pid:
            return True
        time.sleep(0.05)
    return False


def main() -> None:
    repo = Path(__file__).resolve().parents[2]
    wsm = repo / "zig-out/bin/wsm"
    with tempfile.TemporaryDirectory(prefix="wsm-fullscreen-stress-") as tmp:
        root = Path(tmp)
        producer = root / "producer.py"
        progress = root / "progress"
        exit_request = root / "exit"
        producer.write_text(PRODUCER)
        producer.chmod(0o700)

        pid, fd = pty.fork()
        if pid == 0:
            env = os.environ.copy()
            env.update(
                WSM_ROOT=tmp,
                SHELL=str(producer),
                WSM_STRESS_PROGRESS=str(progress),
                WSM_STRESS_EXIT=str(exit_request),
            )
            os.execve(str(wsm), [str(wsm), "create", "stress"], env)

        reaped = False
        try:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            read_until(fd, b"STRESS_SCREEN")
            processes = wait_for_processes(tmp, pid)
            baseline_rss, baseline_fds, _ = process_stats(processes)

            os.write(fd, b"\x07")
            read_until(fd, b"a  attach")
            before_progress = progress.stat().st_size
            before_hidden = process_stats(matching_processes(tmp, pid))
            hidden_bytes = collect(fd, HIDDEN_SECONDS)
            after_hidden = process_stats(matching_processes(tmp, pid))
            after_progress = progress.stat().st_size

            if after_progress <= before_progress:
                raise RuntimeError("child made no independent progress while presentation was hidden")
            if len(hidden_bytes) > 1024:
                raise RuntimeError(f"hidden child output leaked to the terminal ({len(hidden_bytes)} bytes)")
            if after_hidden[0] - before_hidden[0] > RSS_GROWTH_LIMIT_KIB:
                raise RuntimeError("RSS grew beyond the hidden-output bound")
            clock_ticks = os.sysconf("SC_CLK_TCK")
            hidden_cpu_seconds = max(0, after_hidden[2] - before_hidden[2]) / clock_ticks
            if hidden_cpu_seconds > HIDDEN_CPU_LIMIT_SECONDS:
                raise RuntimeError(
                    f"WSM/vpty used {hidden_cpu_seconds:.3f}s CPU during a {HIDDEN_SECONDS:.1f}s hidden interval"
                )

            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 50, 0, 0))
            read_until(fd, b"WSM")
            os.write(fd, b"\x07")
            read_until(fd, b"SIZE:50x12")

            for _ in range(TOGGLES):
                os.write(fd, b"\x07")
                read_until(fd, b"a  attach")
                os.write(fd, b"\x07")
                read_until(fd, b"STRESS_SCREEN")

            final_processes = matching_processes(tmp, pid)
            final_rss, final_fds, _ = process_stats(final_processes)
            if final_rss - baseline_rss > RSS_GROWTH_LIMIT_KIB:
                raise RuntimeError("RSS grew across repeated presentation transitions")
            if final_fds - baseline_fds > FD_GROWTH_LIMIT:
                raise RuntimeError("file descriptors leaked across presentation transitions")
            process_growth = len(final_processes) - len(processes)
            if process_growth > PROCESS_GROWTH_LIMIT:
                raise RuntimeError("processes leaked across presentation transitions")

            os.write(fd, b"\x07")
            read_until(fd, b"a  attach")
            exit_request.touch()
            reaped = wait_for_exit(pid)
            if not reaped:
                raise RuntimeError("WSM did not exit after the hidden child exited")

            print(
                "fullscreen transition stress: ok "
                f"(toggles={TOGGLES}, hidden_progress={after_progress - before_progress}, "
                f"hidden_cpu={hidden_cpu_seconds:.3f}s, rss_growth={final_rss - baseline_rss} KiB, "
                f"fd_growth={final_fds - baseline_fds}, process_growth={process_growth})"
            )
        finally:
            if not reaped:
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
            env = os.environ.copy()
            env["WSM_ROOT"] = tmp
            subprocess.run(
                [wsm, "kill", "-f", "stress"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )


if __name__ == "__main__":
    main()
