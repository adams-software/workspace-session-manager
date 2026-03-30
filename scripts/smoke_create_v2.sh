#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SOCK="/tmp/msr-smoke-create-$$.sock"
cleanup() {
  ./zig-out/bin/msr terminate "$SOCK" KILL >/dev/null 2>&1 || true
  ./zig-out/bin/msr wait "$SOCK" >/dev/null 2>&1 || true
  rm -f "$SOCK"
}
trap cleanup EXIT

zig build >/dev/null

./zig-out/bin/msr create "$SOCK" -- /bin/sh -c 'sleep 3'

STATUS="$(./zig-out/bin/msr status "$SOCK" 2>&1 || true)"
echo "status=$STATUS"
if [[ "$STATUS" != "running" && "$STATUS" != "exited" ]]; then
  echo "unexpected status: $STATUS" >&2
  exit 1
fi

./zig-out/bin/msr terminate "$SOCK" KILL >/dev/null 2>&1 || true
WAIT_OUT="$(./zig-out/bin/msr wait "$SOCK" 2>&1 || true)"
echo "wait=$WAIT_OUT"
if [[ "$WAIT_OUT" != exit_code=* && "$WAIT_OUT" != exit_signal=* ]]; then
  echo "unexpected wait output: $WAIT_OUT" >&2
  exit 1
fi

echo "ok"
