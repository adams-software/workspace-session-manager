#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
BIN_DIR="${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}"
cd "$REPO_ROOT"

BIN="$BIN_DIR/host"
TMPDIR="$(mktemp -d /tmp/host-smoke-XXXXXX)"
SOCK="$TMPDIR/demo.sock"
LOG="$TMPDIR/host.log"

cleanup() {
  set +e
  if [[ -n "${HOST_PID:-}" ]]; then
    kill "$HOST_PID" >/dev/null 2>&1 || true
    wait "$HOST_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "[smoke] build host" | tee -a "$LOG"
zig build >/dev/null

if [[ ! -x "$BIN" ]]; then
  echo "[smoke] missing binary: $BIN" | tee -a "$LOG"
  exit 1
fi

echo "[smoke] launch host" | tee -a "$LOG"
"$BIN" "$SOCK" -- /bin/sh -lc 'sleep 0.5' >"$LOG" 2>&1 &
HOST_PID=$!

for _ in $(seq 1 50); do
  if [[ -S "$SOCK" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -S "$SOCK" ]]; then
  echo "[smoke] socket path never appeared: $SOCK" >&2
  cat "$LOG" >&2 || true
  exit 1
fi

wait "$HOST_PID"
HOST_PID=

if [[ -e "$SOCK" ]]; then
  echo "[smoke] socket path still exists after exit: $SOCK" >&2
  exit 1
fi

echo "[smoke] OK"
