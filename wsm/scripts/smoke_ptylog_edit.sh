#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${HOST_REPO_ROOT:-${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}}"
BIN_DIR="${HOST_BIN_DIR:-${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}}"
PTYLOG_BIN="${PTYLOG_BIN:-$BIN_DIR/ptylog}"
TMP="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

assert_contains() {
  local needle="$1"
  local path="$2"
  grep -Fq -- "$needle" "$path"
}

assert_ordered() {
  local path="$1"
  shift

  python3 - "$path" "$@" <<'PY'
import sys
path = sys.argv[1]
needles = sys.argv[2:]
with open(path, "rb") as f:
    data = f.read().decode("utf-8", errors="replace")
cursor = 0
for needle in needles:
    idx = data.find(needle, cursor)
    if idx == -1:
        raise SystemExit(f"missing ordered substring: {needle!r}")
    cursor = idx + len(needle)
PY
}

assert_not_contains() {
  local needle="$1"
  local path="$2"
  if grep -Fq -- "$needle" "$path"; then
    echo "unexpected content in $path: $needle" >&2
    return 1
  fi
}

printf '=== build outputs present ===\n'
[[ -x "$PTYLOG_BIN" ]]

LOG="$TMP/repro.log"

printf '=== direct ptylog detached edit transcript ordering ===\n'
coproc PTYLOG_PROC { "$PTYLOG_BIN" --log "$LOG" -- /bin/bash -i; }
sleep 1
printf 'lsx\x7f\r' >&"${PTYLOG_PROC[1]}"
sleep 0.5
printf '%s\r' "printf 'file.txt\\n'" >&"${PTYLOG_PROC[1]}"
sleep 0.5
printf 'exit\r' >&"${PTYLOG_PROC[1]}"
exec {PTYLOG_PROC[1]}>&-
wait "$PTYLOG_PROC_PID"

assert_contains '$ ls' "$LOG"
assert_contains "printf 'file.txt" "$LOG"
assert_contains 'file.txt' "$LOG"
assert_not_contains 'lsx' "$LOG"
assert_ordered "$LOG" '$ ls' "printf 'file.txt" 'file.txt'

printf 'smoke ptylog edit ok\n'
