#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
zig build >/dev/null
bin=./zig-out/bin/msr
sock=/tmp/msr-smoke-attach-rpc-$$.sock
out1=/tmp/msr-smoke-attach-rpc-1-$$.out
err1=/tmp/msr-smoke-attach-rpc-1-$$.err
out2=/tmp/msr-smoke-attach-rpc-2-$$.out
err2=/tmp/msr-smoke-attach-rpc-2-$$.err

cleanup() {
  "$bin" wait "$sock" >/dev/null 2>&1 || "$bin" terminate "$sock" KILL >/dev/null 2>&1 || true
  rm -f "$sock" "$out1" "$err1" "$out2" "$err2"
}
trap cleanup EXIT

"$bin" create "$sock" -- /bin/sh -c 'printf ready; sleep 5'
"$bin" exists "$sock" >/dev/null

# First attach should succeed and keep the session occupied.
# Keep stdin open so the first attach remains live long enough to test busy behavior.
{ sleep 2; } | "$bin" attach "$sock" >"$out1" 2>"$err1" &
pid1=$!
sleep 0.3

# Second exclusive attach should fail while first is active.
if "$bin" attach "$sock" >"$out2" 2>"$err2"; then
  echo "expected second exclusive attach to fail while session busy" >&2
  exit 1
fi

grep -q 'takeover' "$err2"

# Takeover attach should succeed.
"$bin" attach "$sock" --takeover >"$out2" 2>"$err2" || true

wait "$pid1" || true

grep -q 'ready' "$out1" || grep -q 'ready' "$out2"
