#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
zig build >/dev/null
bin=./zig-out/bin/msr
sock=/tmp/msr-smoke-takeover-output-$$.sock
out1=/tmp/msr-smoke-takeover-output-1-$$.out
err1=/tmp/msr-smoke-takeover-output-1-$$.err
out2=/tmp/msr-smoke-takeover-output-2-$$.out
err2=/tmp/msr-smoke-takeover-output-2-$$.err

cleanup() {
  "$bin" wait "$sock" >/dev/null 2>&1 || "$bin" terminate "$sock" KILL >/dev/null 2>&1 || true
  rm -f "$sock" "$out1" "$err1" "$out2" "$err2"
}
trap cleanup EXIT

"$bin" create "$sock" -- /bin/sh -c 'i=1; while [ "$i" -le 5 ]; do printf "tick%s\n" "$i"; i=$((i+1)); sleep 1; done'

{ sleep 3; } | "$bin" attach "$sock" >"$out1" 2>"$err1" &
pid1=$!
sleep 0.8

"$bin" attach "$sock" --takeover >"$out2" 2>"$err2" || true
wait "$pid1" || true

grep -q 'tick' "$out1"
grep -q 'tick' "$out2"
