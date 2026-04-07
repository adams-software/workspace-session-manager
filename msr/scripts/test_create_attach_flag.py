#!/usr/bin/env python3
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
BIN = os.path.join(ROOT, 'zig-out', 'bin', 'msr')
TMPDIR = tempfile.mkdtemp(prefix='msr-create-a-')
SOCK = os.path.join(TMPDIR, 'test.sock')


def cleanup():
    subprocess.call([BIN, 'terminate', SOCK, 'KILL'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.call(['pkill', '-f', SOCK], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(TMPDIR, ignore_errors=True)


def read_some(fd: int, timeout: float = 3.0) -> bytes:
    end = time.time() + timeout
    data = b''
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            continue
        try:
            chunk = os.read(fd, 1024)
        except OSError:
            break
        if not chunk:
            break
        data += chunk
        if b'msr v0 (draft)' in data or b'$' in data or b'#' in data or b'sh' in data:
            return data
    return data


try:
    subprocess.check_call(['zig', 'build'], cwd=ROOT, stdout=subprocess.DEVNULL)
    master, slave = pty.openpty()
    proc = subprocess.Popen([BIN, 'create', '-a', SOCK], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)
    out = read_some(master, 3.0)
    text = out.decode('utf-8', errors='replace')
    print(text)
    if 'msr v0 (draft)' in text and 'Usage:' in text:
        print('FAIL: create -a still fell through to help output')
        proc.kill()
        sys.exit(1)
    if proc.poll() is not None and proc.returncode not in (0, None):
        print(f'FAIL: create -a process exited early with code {proc.returncode}')
        sys.exit(1)
    print('PASS: create -a did not fall through to help')
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    os.close(master)
finally:
    cleanup()
