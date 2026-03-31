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
TMPDIR = tempfile.mkdtemp(prefix='msr-smoke-')
SRC = os.path.join(TMPDIR, 'src.sock')
DST = os.path.join(TMPDIR, 'dst.sock')
LOG = os.path.join(TMPDIR, 'log.txt')


def log(msg: str):
    print(msg)
    with open(LOG, 'a') as f:
        f.write(msg + '\n')


def cleanup():
    subprocess.call(['pkill', '-f', SRC], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.call(['pkill', '-f', DST], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(TMPDIR, ignore_errors=True)


def read_until_fd(fd: int, needle: bytes, timeout: float) -> bytes:
    end = time.time() + timeout
    data = b''
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        data += chunk
        if needle in data:
            return data
    return data


def spawn_attach_pty(path: str):
    master, slave = pty.openpty()
    proc = subprocess.Popen([BIN, 'attach', path], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)
    return proc, master


def write_line(fd: int, text: str):
    os.write(fd, text.encode('utf-8'))


def assert_probe(master: int, command: str, needle: str, label: str, timeout: float = 4.0):
    write_line(master, command + "\n")
    out = read_until_fd(master, needle.encode('utf-8'), timeout)
    if needle.encode('utf-8') not in out:
        log(f'[smoke] missing probe output for {label}: expected {needle!r}')
        log(out.decode('utf-8', 'replace'))
        raise SystemExit(1)


try:
    log('[smoke] build msr')
    subprocess.check_call(['zig', 'build'], cwd=ROOT, stdout=subprocess.DEVNULL)
    if not os.path.exists(BIN):
        log(f'[smoke] missing binary: {BIN}')
        sys.exit(1)

    shell_cmd = 'PS1=; export PS1; while read line; do eval "$line"; done'

    log('[smoke] create src')
    subprocess.check_call([BIN, 'create', SRC, '--', '/bin/sh', '-lc', shell_cmd])
    log('[smoke] create dst')
    subprocess.check_call([BIN, 'create', DST, '--', '/bin/sh', '-lc', shell_cmd])

    log('[smoke] direct status')
    out = subprocess.check_output([BIN, 'status', SRC], text=True).strip()
    log(out)

    log('[smoke] direct attach smoke')
    proc, master = spawn_attach_pty(SRC)
    assert_probe(master, "printf 'SRC1\\n'", 'SRC1', 'direct attach src probe')
    proc.terminate()
    proc.wait(timeout=2)
    os.close(master)

    log('[smoke] nested detach via --session')
    proc, master = spawn_attach_pty(SRC)
    assert_probe(master, "printf 'SRC2\\n'", 'SRC2', 'pre-detach src probe')
    subprocess.check_call([BIN, f'--session={SRC}', 'detach'])
    proc.wait(timeout=3)
    os.close(master)

    log('[smoke] nested attach via --session')
    proc, master = spawn_attach_pty(SRC)
    assert_probe(master, "printf 'SRC3\\n'", 'SRC3', 'pre-switch src probe')
    subprocess.check_call([BIN, f'--session={SRC}', 'attach', DST])
    assert_probe(master, "printf 'DST1\\n'", 'DST1', 'post-switch dst probe')
    proc.terminate()
    proc.wait(timeout=2)
    os.close(master)

    log('[smoke] nested attach via MSR_SESSION')
    proc, master = spawn_attach_pty(SRC)
    assert_probe(master, "printf 'SRC4\\n'", 'SRC4', 'pre-switch env src probe')
    env = os.environ.copy()
    env['MSR_SESSION'] = SRC
    subprocess.check_call([BIN, 'attach', DST], env=env)
    assert_probe(master, "printf 'DST2\\n'", 'DST2', 'post-switch env dst probe')
    proc.terminate()
    proc.wait(timeout=2)
    os.close(master)

    log('[smoke] OK')
finally:
    cleanup()
