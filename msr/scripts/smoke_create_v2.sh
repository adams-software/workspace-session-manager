#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
BIN_DIR="${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}"
BIN="$BIN_DIR/msr"
cd "$REPO_ROOT"

SOCK="/tmp/msr-smoke-create-$$.sock"
cleanup() {
  "$BIN" terminate "$SOCK" KILL >/dev/null 2>&1 || true
  "$BIN" wait "$SOCK" >/dev/null 2>&1 || true
  rm -f "$SOCK"
}
trap cleanup EXIT

zig build >/dev/null

"$BIN" create "$SOCK" -- /bin/sh -c 'sleep 3'

STATUS="$("$BIN" status "$SOCK" 2>&1 || true)"
echo "status=$STATUS"
if [[ "$STATUS" != "running" && "$STATUS" != "exited" ]]; then
  echo "unexpected status: $STATUS" >&2
  exit 1
fi

"$BIN" terminate "$SOCK" KILL >/dev/null 2>&1 || true
WAIT_OUT="$("$BIN" wait "$SOCK" 2>&1 || true)"
echo "wait=$WAIT_OUT"
if [[ "$WAIT_OUT" != exit_code=* && "$WAIT_OUT" != exit_signal=* ]]; then
  echo "unexpected wait output: $WAIT_OUT" >&2
  exit 1
fi

echo "ok"
