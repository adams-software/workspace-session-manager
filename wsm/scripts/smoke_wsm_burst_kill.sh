#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${HOST_REPO_ROOT:-${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}}"
BIN_DIR="${HOST_BIN_DIR:-${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}}"
WSM_BIN="${WSM_BIN:-$BIN_DIR/wsm}"
TMP="$(mktemp -d)"

cleanup() {
  tmux kill-session -t wsm_burst_log 2>/dev/null || true
  WSM_ROOT="$TMP" "$WSM_BIN" kill burst >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

assert_contains() {
  local needle="$1"
  local path="$2"
  grep -Fq -- "$needle" "$path"
}

assert_matches() {
  local pattern="$1"
  local path="$2"
  grep -Eq -- "$pattern" "$path"
}

printf '=== build outputs present ===\n'
[[ -x "$WSM_BIN" ]]

printf '=== detached burst output leaves readable log after force kill ===\n'
WSM_ROOT="$TMP" "$WSM_BIN" create -d burst
sleep 1
tmux kill-session -t wsm_burst_log 2>/dev/null || true
tmux new-session -d -s wsm_burst_log "cd '$REPO_ROOT' && WSM_ROOT='$TMP' '$WSM_BIN' attach burst"
sleep 1
tmux send-keys -t wsm_burst_log:0.0 'for i in $(seq 0 499); do echo line-$i; done; sleep 1000' Enter
sleep 0.1
tmux kill-session -t wsm_burst_log 2>/dev/null || true
WSM_ROOT="$TMP" "$WSM_BIN" kill -f burst >/dev/null
# Force-kill logging is best-effort. The important contract is that the log
# survives, remains readable, and retains later durable output without whole-log
# corruption.
[[ -s "$TMP/burst.log" ]]
assert_matches 'line-4[0-9]{2}' "$TMP/burst.log"
[[ ! -e "$TMP/burst.typescript" ]]

printf 'smoke wsm burst kill ok\n'
