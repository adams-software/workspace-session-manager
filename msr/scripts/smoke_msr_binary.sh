#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
BIN_DIR="${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}"
cd "$REPO_ROOT"

BIN="$BIN_DIR/msr"
TMPDIR="$(mktemp -d /tmp/msr-smoke-XXXXXX)"
SRC="$TMPDIR/src.sock"
DST="$TMPDIR/dst.sock"
LOG="$TMPDIR/log.txt"

cleanup() {
  set +e
  pkill -f "$SRC" >/dev/null 2>&1 || true
  pkill -f "$DST" >/dev/null 2>&1 || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "[smoke] build msr" | tee -a "$LOG"
zig build >/dev/null

if [[ ! -x "$BIN" ]]; then
  echo "[smoke] missing binary: $BIN" | tee -a "$LOG"
  exit 1
fi

echo "[smoke] create src" | tee -a "$LOG"
"$BIN" create "$SRC" -- /bin/sh -lc 'i=0; while [ $i -lt 50 ]; do printf src-ready; sleep 0.2; i=$((i+1)); done'
echo "[smoke] create dst" | tee -a "$LOG"
"$BIN" create "$DST" -- /bin/sh -lc 'i=0; while [ $i -lt 50 ]; do printf dst-ready; sleep 0.2; i=$((i+1)); done'

echo "[smoke] direct status" | tee -a "$LOG"
"$BIN" status "$SRC" | tee -a "$LOG"

python3 - <<'PY' "$BIN" "$SRC" "$DST" "$LOG"
import os, subprocess, sys, time, select
bin_path, src, dst, log = sys.argv[1:5]

def read_until(proc, needle, timeout=4.0):
    end = time.time() + timeout
    data = ''
    fd = proc.stdout.fileno()
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            continue
        chunk = os.read(fd, 1024).decode('utf-8', errors='replace')
        if not chunk:
            break
        data += chunk
        if needle in data:
            return data
    return data

def append_log(text):
    with open(log, 'a') as f:
        f.write(text)

print('[smoke] direct attach smoke')
p = subprocess.Popen([bin_path, 'attach', src], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
out = read_until(p, 'src-ready', timeout=4.0)
append_log(out)
if 'src-ready' not in out:
    print('[smoke] direct attach did not observe src-ready')
    p.kill()
    sys.exit(1)
p.terminate()
p.wait(timeout=2)

print('[smoke] nested detach via --session')
outer = subprocess.Popen([bin_path, 'attach', src], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
out = read_until(outer, 'src-ready', timeout=4.0)
append_log(out)
if 'src-ready' not in out:
    print('[smoke] outer attach did not observe src-ready before nested detach')
    outer.kill()
    sys.exit(1)
subprocess.check_call([bin_path, f'--session={src}', 'detach'])
try:
    outer.wait(timeout=3)
except subprocess.TimeoutExpired:
    print('[smoke] nested detach did not cause outer attach to exit')
    outer.kill()
    sys.exit(1)

print('[smoke] nested attach via --session')
outer = subprocess.Popen([bin_path, 'attach', src], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
out = read_until(outer, 'src-ready', timeout=4.0)
append_log(out)
if 'src-ready' not in out:
    print('[smoke] outer attach did not observe src-ready before nested attach')
    outer.kill()
    sys.exit(1)
subprocess.check_call([bin_path, f'--session={src}', 'attach', dst])
out2 = read_until(outer, 'dst-ready', timeout=4.0)
append_log(out2)
if 'dst-ready' not in out2:
    print('[smoke] nested attach via --session did not switch to dst-ready')
    outer.kill()
    sys.exit(1)
outer.terminate()
outer.wait(timeout=2)

print('[smoke] nested attach via MSR_SESSION')
outer = subprocess.Popen([bin_path, 'attach', src], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
out = read_until(outer, 'src-ready', timeout=4.0)
append_log(out)
if 'src-ready' not in out:
    print('[smoke] outer attach did not observe src-ready before env nested attach')
    outer.kill()
    sys.exit(1)
env = os.environ.copy()
env['MSR_SESSION'] = src
subprocess.check_call([bin_path, 'attach', dst], env=env)
out2 = read_until(outer, 'dst-ready', timeout=4.0)
append_log(out2)
if 'dst-ready' not in out2:
    print('[smoke] nested attach via MSR_SESSION did not switch to dst-ready')
    outer.kill()
    sys.exit(1)
outer.terminate()
outer.wait(timeout=2)
PY

echo "[smoke] OK" | tee -a "$LOG"
