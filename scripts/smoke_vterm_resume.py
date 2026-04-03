#!/usr/bin/env python3
import os
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
BIN = os.path.join(ROOT, 'zig-out', 'bin', 'msr')
TMPDIR = tempfile.mkdtemp(prefix='msr-vterm-smoke-')
SOCK = os.path.join(TMPDIR, 'vterm.sock')
LOG = os.path.join(TMPDIR, 'log.txt')


def log(msg: str):
    print(msg)
    with open(LOG, 'a') as f:
        f.write(msg + '\n')


def cleanup():
    subprocess.call(['pkill', '-f', SOCK], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(TMPDIR, ignore_errors=True)


def read_until(fd: int, needles: list[bytes], timeout: float) -> bytes:
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
        if any(n in data for n in needles):
            return data
    return data


def spawn_attach(path: str):
    master, slave = pty.openpty()
    proc = subprocess.Popen([BIN, 'attach', path], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)
    return proc, master


def write_line(fd: int, text: str):
    os.write(fd, text.encode('utf-8'))


def graceful_detach(proc: subprocess.Popen, master: int):
    try:
        proc.terminate()
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=2)
    os.close(master)


try:
    log('[vterm] build msr')
    subprocess.check_call(['zig', 'build'], cwd=ROOT, stdout=subprocess.DEVNULL)

    shell_cmd = 'PS1=; export PS1; stty -echo; while read line; do eval "$line"; done'

    log('[vterm] create --vterm session')
    subprocess.check_call([BIN, 'create', '--vterm', SOCK, '--', '/bin/sh', '-lc', shell_cmd])

    log('[vterm] first attach')
    proc1, master1 = spawn_attach(SOCK)
    write_line(master1, "printf 'PRE-MARK\\n'\n")
    out1 = read_until(master1, [b'PRE-MARK'], 4.0)
    if b'PRE-MARK' not in out1:
        log('[vterm] missing PRE-MARK on first attach')
        log(out1.decode('utf-8', 'replace'))
        raise SystemExit(1)
    graceful_detach(proc1, master1)

    log('[vterm] second attach')
    proc2, master2 = spawn_attach(SOCK)
    write_line(master2, "printf 'POST-MARK\\n'\n")
    out2 = read_until(master2, [b'POST-MARK'], 4.0)
    if b'POST-MARK' not in out2:
        log('[vterm] missing POST-MARK during second attach')
        log(out2.decode('utf-8', 'replace'))
        raise SystemExit(1)
    time.sleep(0.2)
    graceful_detach(proc2, master2)

    log('[vterm] reattach')
    proc3, master3 = spawn_attach(SOCK)
    out3 = read_until(master3, [b'POST-MARK'], 4.0)
    out3 += read_until(master3, [], 1.0)
    text3 = out3.decode('utf-8', 'replace')
    if 'POST-MARK' not in text3:
        log('[vterm] missing POST-MARK on reattach')
        log(text3)
        raise SystemExit(1)
    graceful_detach(proc3, master3)

    log('[vterm] OK')
finally:
    cleanup()
